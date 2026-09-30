#include <hxcpp.h>
#include "NativeLibuvPoll.h"

#include <algorithm>
#include <cmath>
#include <new>
#include <string.h>
#include <vector>
#include <uv.h>

#if defined(_WIN32)
#include <unordered_map>
#else
#include <poll.h>
#endif

#if defined(_WIN32)
#define CROSSBYTE_INVALID_SOCKET INVALID_SOCKET
#else
#define CROSSBYTE_INVALID_SOCKET (-1)
#endif

namespace {

// The kind that marks a poll object. A function-local static, so two
// runtimes starting on two threads cannot each allocate one.
static int libuvPollType() {
	static int type = hxcpp_alloc_kind();
	return type;
}

// hxcpp's socket handle (src/hx/libs/std/Socket.cpp), which hxcpp does not
// export: an hx::Object whose one field is the descriptor. Closing the socket
// sets it to INVALID_SOCKET, and the handle is never reused for another one,
// so the pair (handle, descriptor) names one open socket.
struct HxcppSocket : public hx::Object {
	uv_os_sock_t socket;
};

static inline uv_os_sock_t descriptorOf(hx::Object* handle) {
	return reinterpret_cast<HxcppSocket*>(handle)->socket;
}

// The hxcpp handle behind a sys.net.Socket (or the handle itself), or null
// for anything that is not a socket.
static hx::Object* socketHandleOf(hx::Object* value) {
	if (value == 0) {
		return 0;
	}

	if (value->__GetType() == vtClass) {
		Dynamic inner = value->__Field(HX_CSTRING("__s"), hx::paccNever);
		value = inner.mPtr;
		if (value == 0) {
			return 0;
		}
	}

	return value->_hx_isInstanceOf(hx::clsIdSocket) ? value : 0;
}

struct PollState;

// One loop and its wait timer. A purge swaps in a fresh pair, so they live
// apart from the state that outlasts them.
struct LoopHolder {
	uv_loop_t loop;
	uv_timer_t timer;
};

// One uv_poll_t per socket, kept from one prepare to the next. It used to be
// torn down and made again for every socket whenever any one socket joined or
// left: seven kernel calls a socket, 75 ms a change at 10,000 sockets.
struct Watcher {
	uv_poll_t handle;
	PollState* state;
	// The socket's hxcpp handle: who this watcher is for. Kept alive by the
	// poll object's __Mark, so an address is never a different socket's.
	hx::Object* socketHandle;
	// The descriptor the handle held when the watcher was made. When the two
	// stop agreeing, the socket was closed under the watcher.
	uv_os_sock_t socket;
	// Where a purge moved this watcher's bookkeeping, for the snapshot arrays.
	struct Watcher* replacement;
	// Positions in the last prepare's read and write lists, or -1.
	int readIndex;
	int writeIndex;
	// What uv_poll_start was last given: 0 until then, and again once libuv
	// has stopped the handle itself (it does on POLLERR).
	int events;
	int listIndex;
	// The prepare that last found the socket in a list.
	unsigned int seen;
	// The events() call that last reported it readable, or writable. libuv
	// polls again, without blocking, while a batch of 1,024 comes back full,
	// and a level-triggered socket comes back in every one of them.
	unsigned int reportedRead;
	unsigned int reportedWrite;
	// The events() call that started it polling, so it is known whether a
	// loop pass has registered it with the kernel yet.
	unsigned int armedCall;
	// Consecutive events() calls that reported it, for the stale check.
	unsigned int lastReport;
	unsigned int streak;
	// Left in the loop after its descriptor was closed under it: see
	// closedUnder().
	bool tombstone;
	bool retired;
};

struct WatcherTable {
#if defined(_WIN32)
	// A SOCKET is a handle value, not a small index.
	std::unordered_map<uv_os_sock_t, Watcher*> map;

	Watcher* find(uv_os_sock_t socket) const {
		std::unordered_map<uv_os_sock_t, Watcher*>::const_iterator it = map.find(socket);
		return it == map.end() ? 0 : it->second;
	}

	void set(uv_os_sock_t socket, Watcher* watcher) {
		map[socket] = watcher;
	}

	void erase(uv_os_sock_t socket, Watcher* watcher) {
		std::unordered_map<uv_os_sock_t, Watcher*>::iterator it = map.find(socket);
		if (it != map.end() && it->second == watcher) {
			map.erase(it);
		}
	}

	void clear() {
		map.clear();
	}
#else
	// Indexed by descriptor: they are small and dense.
	std::vector<Watcher*> slots;

	Watcher* find(int socket) const {
		return socket >= 0 && socket < (int)slots.size() ? slots[socket] : 0;
	}

	void set(int socket, Watcher* watcher) {
		if (socket >= (int)slots.size()) {
			slots.resize(socket + 1, 0);
		}
		slots[socket] = watcher;
	}

	void erase(int socket, Watcher* watcher) {
		if (socket >= 0 && socket < (int)slots.size() && slots[socket] == watcher) {
			slots[socket] = 0;
		}
	}

	void clear() {
		slots.clear();
	}
#endif
};

struct PollState {
	LoopHolder* holder;
	WatcherTable table;
	// Every watcher the loop holds, live or buried.
	std::vector<Watcher*> list;
	// The last prepare's lists, compared by identity, and the watcher each
	// position resolved to. An unchanged position costs a pointer compare.
	std::vector<hx::Object*> readSockets;
	std::vector<Watcher*> readWatchers;
	std::vector<hx::Object*> writeSockets;
	std::vector<Watcher*> writeWatchers;
	std::vector<int> readReady;
	std::vector<int> writeReady;
	std::vector<Watcher*> suspects;
	// Sockets reported for the first time in this events() call, this pass.
	int fresh;
	unsigned int prepareGeneration;
	unsigned int callGeneration;
	bool stale;
	int buried;
	int created;
	int retiredCount;
	int purges;
	int dropped;
};

static void onWatcherClosed(uv_handle_t* handle) {
	delete static_cast<Watcher*>(handle->data);
}

static void closeHandle(uv_handle_t* handle, void*) {
	if (!uv_is_closing(handle)) {
		uv_close(handle, handle->type == UV_POLL ? onWatcherClosed : 0);
	}
}

static void onTimer(uv_timer_t* timer) {
	uv_stop(timer->loop);
}

static LoopHolder* openLoop() {
	LoopHolder* holder = new (std::nothrow) LoopHolder();
	if (holder == 0) {
		return 0;
	}
	memset(holder, 0, sizeof(LoopHolder));

	if (uv_loop_init(&holder->loop) != 0) {
		delete holder;
		return 0;
	}

	if (uv_timer_init(&holder->loop, &holder->timer) != 0) {
		uv_loop_close(&holder->loop);
		delete holder;
		return 0;
	}

	return holder;
}

// Closes whatever is still open on a loop, its watchers, which are freed as
// they close, and its timer, and then the loop: its epoll set goes with it,
// and so does anything registered there that could no longer be named.
static void closeLoop(LoopHolder* holder) {
	uv_walk(&holder->loop, closeHandle, 0);
	while (uv_run(&holder->loop, UV_RUN_DEFAULT) != 0) {}

	if (uv_loop_close(&holder->loop) == 0) {
		delete holder;
	}
	// Otherwise libuv still points into it; leaking it is the safe choice.
}

static inline bool isOpen(const Watcher* watcher) {
	return descriptorOf(watcher->socketHandle) == watcher->socket;
}

static inline bool isLive(const Watcher* watcher) {
	return !watcher->retired && !watcher->tombstone && isOpen(watcher);
}

// Forgets the snapshot positions that point at a watcher about to go.
static void forgetPositions(PollState* state, Watcher* watcher) {
	int read = watcher->readIndex;
	if (read >= 0 && read < (int)state->readWatchers.size() && state->readWatchers[read] == watcher) {
		state->readWatchers[read] = 0;
	}

	int write = watcher->writeIndex;
	if (write >= 0 && write < (int)state->writeWatchers.size() && state->writeWatchers[write] == watcher) {
		state->writeWatchers[write] = 0;
	}

	watcher->readIndex = -1;
	watcher->writeIndex = -1;
}

// Stops polling a socket and lets the loop free its watcher on its next pass.
// uv_close stops the handle first, so the kernel forgets the descriptor now
// while it can still be named.
static void retire(PollState* state, Watcher* watcher) {
	forgetPositions(state, watcher);
	state->table.erase(watcher->socket, watcher);

	int last = (int)state->list.size() - 1;
	Watcher* moved = state->list[last];
	state->list[watcher->listIndex] = moved;
	moved->listIndex = watcher->listIndex;
	state->list.pop_back();

	if (watcher->tombstone) {
		state->buried--;
	}
	watcher->retired = true;
	uv_close(reinterpret_cast<uv_handle_t*>(&watcher->handle), onWatcherClosed);
	state->retiredCount++;
}

// A watcher whose descriptor was closed while it was still polling, which
// is what CrossByte does today: the socket is closed first and deregistered
// afterwards, where libuv needs polling stopped before the close.
//
// Usually that is harmless: closing the last reference to a socket takes it
// out of every epoll set. When another reference lives on, a child process
// that inherited the descriptor, the registration outlives the close, can
// no longer be removed by descriptor, and fires for as long as the socket is
// ready: libuv then re-polls without sleeping until its timeout is spent
// (189,806 epoll_wait calls in one 100 ms wait). So on Linux the watcher is
// left in the loop, reporting nothing, as a tombstone. If it ever fires,
// the registration is stale and the next events() moves every live watcher
// to a fresh loop, whose epoll set does not have it. If the descriptor is
// reused first, the tombstone goes and the new socket's watcher takes its
// place; a stale registration then shows up as that watcher being reported
// ready call after call while it is not, which the streak check catches.
static void closedUnder(PollState* state, Watcher* watcher) {
#if defined(__linux__)
	// Only a handle libuv still holds, whose registration a loop pass has
	// already made: a pending one would be made for a closed descriptor,
	// which libuv answers with abort().
	if (watcher->events != 0 && watcher->armedCall != state->callGeneration) {
		forgetPositions(state, watcher);
		watcher->tombstone = true;
		state->buried++;
		return;
	}
#endif
	retire(state, watcher);
}

static void onPoll(uv_poll_t* handle, int status, int events);

// The watcher for a socket not found at its position in the last snapshot:
// the one kept for its descriptor, or a new one.
static Watcher* watcherFor(PollState* state, hx::Object* value) {
	hx::Object* handle = socketHandleOf(value);
	if (handle == 0) {
		hx::Throw(HX_CSTRING("Invalid socket handle"));
		return 0;
	}

	uv_os_sock_t socket = descriptorOf(handle);

	Watcher* watcher = state->table.find(socket);
	if (watcher != 0) {
		if (watcher->socketHandle == handle && !watcher->tombstone) {
			return watcher;
		}

		// The descriptor now belongs to another socket, so whatever held it
		// was closed under its watcher. That one goes before the new one is
		// made: libuv keeps one watcher per descriptor.
		retire(state, watcher);
	}

	watcher = new Watcher();
	memset(watcher, 0, sizeof(Watcher));
	watcher->state = state;
	watcher->socketHandle = handle;
	watcher->socket = socket;
	watcher->readIndex = -1;
	watcher->writeIndex = -1;

	if (uv_poll_init_socket(&state->holder->loop, &watcher->handle, socket) != 0) {
		delete watcher;
		hx::Throw(HX_CSTRING("uv_poll_init_socket failed"));
		return 0;
	}
	watcher->handle.data = watcher;

	state->table.set(socket, watcher);
	watcher->listIndex = (int)state->list.size();
	state->list.push_back(watcher);
	state->created++;
	return watcher;
}

static void walk(PollState* state, Array<Dynamic>& sockets, int length, std::vector<hx::Object*>& lastSockets,
		std::vector<Watcher*>& lastWatchers, bool readable, unsigned int generation) {
	int previous = (int)lastSockets.size();
	lastSockets.resize(length, 0);
	lastWatchers.resize(length, 0);

	for (int i = 0; i < length; ++i) {
		hx::Object* value = sockets->__unsafe_get(i).mPtr;
		Watcher* watcher = lastWatchers[i];

		// The same socket in the same place, still open: nothing to look up.
		if (!(i < previous && lastSockets[i] == value && watcher != 0 && isLive(watcher))) {
			watcher = watcherFor(state, value);
		}

		lastSockets[i] = value;
		lastWatchers[i] = watcher;
		if (watcher == 0) {
			continue;
		}

		if (watcher->seen != generation) {
			watcher->seen = generation;
			watcher->readIndex = -1;
			watcher->writeIndex = -1;
		}

		int& index = readable ? watcher->readIndex : watcher->writeIndex;
		if (index >= 0) {
			// The same socket twice in one list: its first place answers for
			// it, and only one place may point at a watcher, retiring it
			// forgets that one.
			lastWatchers[i] = 0;
			continue;
		}
		index = i;
	}
}

// Stops the watchers of sockets that left, and starts or changes the rest.
static void sweep(PollState* state, unsigned int generation) {
	// Backwards, so the watcher retire() swaps into a slot is one already seen.
	for (int i = (int)state->list.size() - 1; i >= 0; --i) {
		if (i >= (int)state->list.size()) {
			continue;
		}

		Watcher* watcher = state->list[i];
		if (watcher->tombstone) {
			continue;
		}

		if (watcher->seen != generation) {
			if (isOpen(watcher)) {
				retire(state, watcher);
			} else {
				closedUnder(state, watcher);
			}
			continue;
		}

		int wanted = (watcher->readIndex >= 0 ? UV_READABLE : 0) | (watcher->writeIndex >= 0 ? UV_WRITABLE : 0);
		if (wanted != watcher->events) {
			if (uv_poll_start(&watcher->handle, wanted, onPoll) == 0) {
				watcher->events = wanted;
				watcher->armedCall = state->callGeneration;
			} else {
				retire(state, watcher);
				state->dropped++;
			}
		}
	}
}

// Moves every live watcher to a fresh loop and closes the old one, and with
// it an epoll set holding a registration that can no longer be removed.
static void purge(PollState* state) {
	LoopHolder* fresh = openLoop();
	if (fresh == 0) {
		// Keep polling on the old loop and try again at the next call.
		state->stale = true;
		return;
	}

	std::vector<Watcher*> moved;
	moved.reserve(state->list.size());

	for (int i = 0; i < (int)state->list.size(); ++i) {
		Watcher* old = state->list[i];
		old->replacement = 0;
		state->table.erase(old->socket, old);

		if (old->tombstone || !isOpen(old)) {
			continue;
		}

		Watcher* watcher = new (std::nothrow) Watcher();
		if (watcher == 0) {
			state->dropped++;
			continue;
		}
		*watcher = *old;
		memset(&watcher->handle, 0, sizeof(watcher->handle));
		watcher->replacement = 0;

		if (uv_poll_init_socket(&fresh->loop, &watcher->handle, watcher->socket) != 0) {
			delete watcher;
			state->dropped++;
			continue;
		}
		watcher->handle.data = watcher;

		int wanted = (watcher->readIndex >= 0 ? UV_READABLE : 0) | (watcher->writeIndex >= 0 ? UV_WRITABLE : 0);
		watcher->events = 0;
		if (wanted != 0) {
			if (uv_poll_start(&watcher->handle, wanted, onPoll) != 0) {
				uv_close(reinterpret_cast<uv_handle_t*>(&watcher->handle), onWatcherClosed);
				state->dropped++;
				continue;
			}
			watcher->events = wanted;
			watcher->armedCall = state->callGeneration;
		}

		watcher->listIndex = (int)moved.size();
		moved.push_back(watcher);
		state->table.set(watcher->socket, watcher);
		old->replacement = watcher;
	}

	for (int i = 0; i < (int)state->readWatchers.size(); ++i) {
		Watcher* watcher = state->readWatchers[i];
		state->readWatchers[i] = watcher != 0 ? watcher->replacement : 0;
	}
	for (int i = 0; i < (int)state->writeWatchers.size(); ++i) {
		Watcher* watcher = state->writeWatchers[i];
		state->writeWatchers[i] = watcher != 0 ? watcher->replacement : 0;
	}

	LoopHolder* old = state->holder;
	state->holder = fresh;
	state->list.swap(moved);
	state->buried = 0;
	state->purges++;

	// Frees every old watcher, buried ones included.
	closeLoop(old);
}

static void onPoll(uv_poll_t* handle, int status, int events) {
	Watcher* watcher = static_cast<Watcher*>(handle->data);
	PollState* state = watcher->state;

	if (watcher->tombstone) {
		// Its descriptor is closed: this is a registration another process's
		// reference kept alive. See closedUnder().
		state->stale = true;
		uv_stop(handle->loop);
		return;
	}

	if (status < 0) {
		// libuv stopped the handle itself; the next prepare starts it again.
		watcher->events = 0;
	}

	bool reported = false;
	if ((status < 0 || (events & UV_READABLE)) && watcher->readIndex >= 0 && watcher->reportedRead != state->callGeneration) {
		watcher->reportedRead = state->callGeneration;
		state->readReady.push_back(watcher->readIndex);
		reported = true;
	}
	if ((status < 0 || (events & UV_WRITABLE)) && watcher->writeIndex >= 0 && watcher->reportedWrite != state->callGeneration) {
		watcher->reportedWrite = state->callGeneration;
		state->writeReady.push_back(watcher->writeIndex);
		reported = true;
	}

	if (reported) {
		state->fresh++;
	}

#if defined(__linux__)
	if (reported && watcher->lastReport != state->callGeneration) {
		watcher->streak = watcher->lastReport + 1 == state->callGeneration ? watcher->streak + 1 : 1;
		watcher->lastReport = state->callGeneration;
		if ((watcher->streak & 63) == 0) {
			state->suspects.push_back(watcher);
		}
	}
#endif

	uv_stop(handle->loop);
}

#if defined(__linux__)
// A watcher reported on 64 calls in a row is asked directly whether it is
// ready for what it was reported for. A genuinely busy socket is, and costs
// one poll(2) per 64 reports. A socket answering for a stale registration
// that shares its descriptor number is not, and the loop is purged.
static void checkSuspects(PollState* state) {
	for (int i = 0; i < (int)state->suspects.size(); ++i) {
		Watcher* watcher = state->suspects[i];
		struct pollfd fd;
		fd.fd = watcher->socket;
		fd.events = 0;
		if (watcher->reportedRead == state->callGeneration) {
			fd.events |= POLLIN;
		}
		if (watcher->reportedWrite == state->callGeneration) {
			fd.events |= POLLOUT;
		}
		fd.revents = 0;

		if (poll(&fd, 1, 0) == 0) {
			state->stale = true;
			return;
		}
	}
}
#endif

static void destroyState(PollState* state) {
	state->list.clear();
	state->table.clear();
	state->readSockets.clear();
	state->readWatchers.clear();
	state->writeSockets.clear();
	state->writeWatchers.clear();
	closeLoop(state->holder);
	state->holder = 0;
	delete state;
}

struct LibuvPollData : public hx::Object {
	PollState* state;
	int capacity;
	Array<int> ridx;
	Array<int> widx;

	LibuvPollData() : state(0), capacity(0) {}

	void create(PollState* inState, int inCapacity) {
		state = inState;
		capacity = inCapacity;
		ridx = newIndexes(capacity);
		HX_OBJ_WB_GET(this, ridx.mPtr);
		widx = newIndexes(capacity);
		HX_OBJ_WB_GET(this, widx.mPtr);
		_hx_set_finalizer(this, finalize);
	}

	static Array<int> newIndexes(int count) {
		Array<int> indexes = Array_obj<int>::__new(count + 1, count + 1);
		for (int i = 0; i <= count; ++i) {
			indexes[i] = -1;
		}
		return indexes;
	}

	// Room for every position in the lists about to be prepared, and a -1
	// after them. Allocates, so it runs before prepare touches anything the
	// collector reads.
	void reserve(int readLength, int writeLength) {
		if (ridx->length < readLength + 1) {
			ridx = newIndexes(std::max(readLength, ridx->length + ridx->length / 2));
			HX_OBJ_WB_GET(this, ridx.mPtr);
		}
		if (widx->length < writeLength + 1) {
			widx = newIndexes(std::max(writeLength, widx->length + widx->length / 2));
			HX_OBJ_WB_GET(this, widx.mPtr);
		}
	}

	Array<Dynamic> indexes() {
		Array<Dynamic> result = Array_obj<Dynamic>::__new(2, 2);
		result[0] = ridx;
		result[1] = widx;
		return result;
	}

	void destroy() {
		if (state != 0) {
			PollState* old = state;
			state = 0;
			destroyState(old);
		}
	}

	void __Mark(hx::MarkContext* __inCtx) HXCPP_OVERRIDE {
		HX_MARK_MEMBER(ridx);
		HX_MARK_MEMBER(widx);
		if (state != 0) {
			for (int i = 0; i < (int)state->list.size(); ++i) {
				HX_MARK_OBJECT(state->list[i]->socketHandle);
			}
			for (int i = 0; i < (int)state->readSockets.size(); ++i) {
				HX_MARK_OBJECT(state->readSockets[i]);
			}
			for (int i = 0; i < (int)state->writeSockets.size(); ++i) {
				HX_MARK_OBJECT(state->writeSockets[i]);
			}
		}
	}

#ifdef HXCPP_VISIT_ALLOCS
	void __Visit(hx::VisitContext* __inCtx) HXCPP_OVERRIDE {
		HX_VISIT_MEMBER(ridx);
		HX_VISIT_MEMBER(widx);
		if (state != 0) {
			for (int i = 0; i < (int)state->list.size(); ++i) {
				HX_VISIT_OBJECT(state->list[i]->socketHandle);
			}
			for (int i = 0; i < (int)state->readSockets.size(); ++i) {
				HX_VISIT_OBJECT(state->readSockets[i]);
			}
			for (int i = 0; i < (int)state->writeSockets.size(); ++i) {
				HX_VISIT_OBJECT(state->writeSockets[i]);
			}
		}
	}
#endif

	int __GetType() const HXCPP_OVERRIDE {
		return libuvPollType();
	}

	static void finalize(Dynamic obj) {
		((LibuvPollData*)(obj.mPtr))->destroy();
	}

	String toString() HXCPP_OVERRIDE {
		return HX_CSTRING("crossbyte_libuv_poll");
	}
};

static LibuvPollData* crossbyte_libuv_poll_data(Dynamic handle) {
	if (!handle.mPtr || handle->__GetType() != libuvPollType()) {
		hx::Throw(HX_CSTRING("Invalid crossbyte-libuv poll handle"));
		return 0;
	}

	return static_cast<LibuvPollData*>(handle.mPtr);
}

static void fill(Array<int>& target, const std::vector<int>& ready) {
	int* base = target->Pointer();
	int count = std::min((int)ready.size(), target->length - 1);
	for (int i = 0; i < count; ++i) {
		base[i] = ready[i];
	}
	base[count] = -1;
}

} // namespace

Dynamic crossbyte_libuv_poll_create(int capacity) {
	if (capacity < 0 || capacity > 1000000) {
		return null();
	}

	LoopHolder* holder = openLoop();
	if (holder == 0) {
		hx::Throw(HX_CSTRING("Failed to initialize libuv loop"));
		return null();
	}

	PollState* state = new (std::nothrow) PollState();
	if (state == 0) {
		closeLoop(holder);
		return null();
	}
	state->holder = holder;
	state->prepareGeneration = 0;
	state->callGeneration = 1;
	state->fresh = 0;
	state->stale = false;
	state->buried = 0;
	state->created = 0;
	state->retiredCount = 0;
	state->purges = 0;
	state->dropped = 0;

	LibuvPollData* data = new LibuvPollData();
	data->create(state, capacity);
	return data;
}

Array<Dynamic> crossbyte_libuv_poll_prepare(Dynamic handle, Array<Dynamic> read, Array<Dynamic> write) {
	LibuvPollData* data = crossbyte_libuv_poll_data(handle);

	int readLength = read.mPtr ? read->length : 0;
	int writeLength = write.mPtr ? write->length : 0;
	data->reserve(readLength, writeLength);

	PollState* state = data->state;
	if (state != 0) {
		unsigned int generation = ++state->prepareGeneration;
		walk(state, read, readLength, state->readSockets, state->readWatchers, true, generation);
		walk(state, write, writeLength, state->writeSockets, state->writeWatchers, false, generation);
		sweep(state, generation);
		HX_OBJ_WB_PESSIMISTIC_GET(data);
	}

	return data->indexes();
}

void crossbyte_libuv_poll_events(Dynamic handle, double timeout) {
	LibuvPollData* data = crossbyte_libuv_poll_data(handle);
	PollState* state = data->state;
	if (state == 0) {
		data->ridx[0] = -1;
		data->widx[0] = -1;
		return;
	}

	state->callGeneration++;
	state->readReady.clear();
	state->writeReady.clear();
	state->suspects.clear();

	if (state->stale) {
		state->stale = false;
		purge(state);
	}

	uv_loop_t* loop = &state->holder->loop;
	uv_timer_t* timer = &state->holder->timer;
	bool timed = timeout > 0;
	if (timed) {
		// From the time now, not the time the loop last looked: a host that
		// pumps every 16 ms with a 5 ms budget armed a timer already due, and
		// libuv runs due timers before it polls, so the wait ended before it
		// began and no socket event was ever seen.
		uv_update_time(loop);
		uv_timer_start(timer, onTimer, (uint64_t)std::ceil(timeout * 1000.0), 0);
	}

	state->fresh = 0;
	hx::EnterGCFreeZone();
	uv_run(loop, timeout == 0 ? UV_RUN_NOWAIT : UV_RUN_DEFAULT);
#if defined(_WIN32)
	// libuv takes at most 128 completions from the port in a pass
	// (win/core.c), and the first report ends the run, so with more sockets
	// ready than that one call reported only 128 of them. More passes,
	// without waiting, while a pass still brings a full batch not yet seen.
	for (int pass = 0; pass < 64 && state->fresh >= 128; ++pass) {
		state->fresh = 0;
		uv_run(loop, UV_RUN_NOWAIT);
	}
#endif
	hx::ExitGCFreeZone();

	if (timed) {
		uv_timer_stop(timer);
	}

#if defined(__linux__)
	if (!state->suspects.empty()) {
		checkSuspects(state);
	}
#endif

	fill(data->ridx, state->readReady);
	fill(data->widx, state->writeReady);
}

void crossbyte_libuv_poll_remove(Dynamic handle, Dynamic socket) {
	LibuvPollData* data = crossbyte_libuv_poll_data(handle);
	PollState* state = data->state;
	hx::Object* socketHandle = socketHandleOf(socket.mPtr);
	if (state == 0 || socketHandle == 0) {
		return;
	}

	uv_os_sock_t descriptor = descriptorOf(socketHandle);
	if (descriptor != CROSSBYTE_INVALID_SOCKET) {
		Watcher* watcher = state->table.find(descriptor);
		if (watcher != 0 && watcher->socketHandle == socketHandle && !watcher->tombstone) {
			retire(state, watcher);
		}
		return;
	}

	// Closed already, so it can only be found by handle.
	for (int i = 0; i < (int)state->list.size(); ++i) {
		Watcher* watcher = state->list[i];
		if (watcher->socketHandle == socketHandle && !watcher->tombstone) {
			closedUnder(state, watcher);
			return;
		}
	}
}

Array<int> crossbyte_libuv_poll_stats(Dynamic handle) {
	LibuvPollData* data = crossbyte_libuv_poll_data(handle);
	PollState* state = data->state;
	Array<int> result = Array_obj<int>::__new(6, 6);
	if (state != 0) {
		result[0] = (int)state->list.size() - state->buried;
		result[1] = state->buried;
		result[2] = state->created;
		result[3] = state->retiredCount;
		result[4] = state->purges;
		result[5] = state->dropped;
	} else {
		for (int i = 0; i < 6; ++i) {
			result[i] = 0;
		}
	}
	return result;
}

void crossbyte_libuv_poll_dispose(Dynamic handle) {
	LibuvPollData* data = crossbyte_libuv_poll_data(handle);
	data->destroy();
}
