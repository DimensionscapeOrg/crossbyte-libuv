#include <hxcpp.h>
#include "NativeLibuvPoll.h"

#include <algorithm>
#include <cmath>
#include <string.h>
#include <vector>
#include <uv.h>

#if defined(HX_WINDOWS) || defined(NEKO_WINDOWS)
#include <winsock2.h>
typedef SOCKET CrossByteSocketHandle;
#define CROSSBYTE_INVALID_SOCKET INVALID_SOCKET
#else
typedef int CrossByteSocketHandle;
#define CROSSBYTE_INVALID_SOCKET (-1)
#endif

namespace {

static int libuvPollType = 0;
static int stdSocketType = 0;

static int crossbyte_socket_type() {
	if (stdSocketType == 0) {
		Dynamic probe = _hx_std_socket_new(false, false);
		stdSocketType = probe->__GetType();
		_hx_std_socket_close(probe);
	}

	return stdSocketType;
}

struct SocketWrapper : public hx::Object {
	HX_IS_INSTANCE_OF enum { _hx_ClassId = hx::clsIdSocket };

	CrossByteSocketHandle socket;

	int __GetType() const {
		return crossbyte_socket_type();
	}
};

static CrossByteSocketHandle crossbyte_val_sock(Dynamic inValue) {
	if (inValue.mPtr == 0) {
		hx::Throw(HX_CSTRING("Invalid socket handle"));
		return CROSSBYTE_INVALID_SOCKET;
	}

	if (inValue->__GetType() == vtClass) {
		inValue = inValue->__Field(HX_CSTRING("__s"), hx::paccNever);
		if (inValue.mPtr == 0) {
			hx::Throw(HX_CSTRING("Invalid socket handle"));
			return CROSSBYTE_INVALID_SOCKET;
		}
	}

	return reinterpret_cast<SocketWrapper*>(inValue.mPtr)->socket;
}

struct LibuvPollData;

struct LibuvWatcher {
	uv_poll_t handle;
	LibuvPollData* owner;
	uv_os_sock_t socket;
	int readIndex;
	int writeIndex;
};

static void crossbyte_libuv_stop_timer(uv_timer_t* timer) {
	if (timer != 0) {
		uv_timer_stop(timer);
	}
}

static void crossbyte_libuv_on_timer(uv_timer_t* timer);

struct LibuvPollData : public hx::Object {
	int capacity;
	bool ok;
	bool timerClosing;
	uv_loop_t* loop;
	uv_timer_t timer;
	std::vector<LibuvWatcher*> watchers;
	std::vector<int> readReady;
	std::vector<int> writeReady;

	void create(int inCapacity) {
		ok = true;
		timerClosing = false;
		capacity = inCapacity;
		loop = new uv_loop_t();
		if (uv_loop_init(loop) != 0) {
			delete loop;
			loop = 0;
			ok = false;
			hx::Throw(HX_CSTRING("Failed to initialize libuv loop"));
			return;
		}

		memset(&timer, 0, sizeof(timer));
		if (uv_timer_init(loop, &timer) != 0) {
			destroy();
			hx::Throw(HX_CSTRING("Failed to initialize libuv timer"));
			return;
		}
		timer.data = this;

		_hx_set_finalizer(this, finalize);
	}

	void destroyWatchers() {
		if (loop == 0) {
			watchers.clear();
			return;
		}

		crossbyte_libuv_stop_timer(&timer);
		for (int i = 0; i < (int)watchers.size(); ++i) {
			LibuvWatcher* watcher = watchers[i];
			if (watcher != 0 && !uv_is_closing(reinterpret_cast<uv_handle_t*>(&watcher->handle))) {
				uv_poll_stop(&watcher->handle);
				uv_close(reinterpret_cast<uv_handle_t*>(&watcher->handle), onWatcherClosed);
			}
		}
		watchers.clear();

		while (uv_run(loop, UV_RUN_DEFAULT) != 0) {}
	}

	void destroy() {
		if (!ok) {
			return;
		}

		ok = false;
		destroyWatchers();

		if (loop != 0 && !timerClosing && !uv_is_closing(reinterpret_cast<uv_handle_t*>(&timer))) {
			timerClosing = true;
			uv_close(reinterpret_cast<uv_handle_t*>(&timer), 0);
			while (uv_run(loop, UV_RUN_DEFAULT) != 0) {}
		}

		if (loop != 0) {
			uv_loop_close(loop);
			delete loop;
			loop = 0;
		}
	}

	int __GetType() const {
		return libuvPollType;
	}

	static void finalize(Dynamic obj) {
		((LibuvPollData*)(obj.mPtr))->destroy();
	}

	static void onWatcherClosed(uv_handle_t* handle) {
		LibuvWatcher* watcher = reinterpret_cast<LibuvWatcher*>(handle->data);
		delete watcher;
	}

	static void onPoll(uv_poll_t* handle, int status, int events) {
		LibuvWatcher* watcher = reinterpret_cast<LibuvWatcher*>(handle->data);
		if (watcher == 0 || watcher->owner == 0 || !watcher->owner->ok) {
			return;
		}

		if ((status < 0 || (events & UV_READABLE)) && watcher->readIndex >= 0) {
			watcher->owner->readReady.push_back(watcher->readIndex);
		}
		if ((status < 0 || (events & UV_WRITABLE)) && watcher->writeIndex >= 0) {
			watcher->owner->writeReady.push_back(watcher->writeIndex);
		}

		uv_stop(watcher->owner->loop);
	}

	String toString() {
		return HX_CSTRING("crossbyte_libuv_poll");
	}
};

static void crossbyte_libuv_on_timer(uv_timer_t* timer) {
	LibuvPollData* owner = reinterpret_cast<LibuvPollData*>(timer->data);
	if (owner != 0 && owner->loop != 0) {
		uv_stop(owner->loop);
	}
}

static LibuvPollData* crossbyte_libuv_poll_data(Dynamic handle) {
	if (!handle.mPtr || handle->__GetType() != libuvPollType) {
		hx::Throw(HX_CSTRING("Invalid crossbyte-libuv poll handle"));
		return 0;
	}

	return static_cast<LibuvPollData*>(handle.mPtr);
}

static LibuvWatcher* findWatcher(LibuvPollData* data, uv_os_sock_t socket) {
	for (int i = 0; i < (int)data->watchers.size(); ++i) {
		if (data->watchers[i]->socket == socket) {
			return data->watchers[i];
		}
	}

	return 0;
}

static void addSocket(LibuvPollData* data, Dynamic socketValue, int index, bool readable) {
	uv_os_sock_t socket = (uv_os_sock_t)crossbyte_val_sock(socketValue);
	LibuvWatcher* watcher = findWatcher(data, socket);

	if (watcher == 0) {
		watcher = new LibuvWatcher();
		memset(watcher, 0, sizeof(LibuvWatcher));
		watcher->owner = data;
		watcher->socket = socket;
		watcher->readIndex = -1;
		watcher->writeIndex = -1;
		watcher->handle.data = watcher;

		int status = uv_poll_init_socket(data->loop, &watcher->handle, socket);
		if (status != 0) {
			delete watcher;
			hx::Throw(HX_CSTRING("uv_poll_init_socket failed"));
			return;
		}

		data->watchers.push_back(watcher);
	}

	if (readable) {
		watcher->readIndex = index;
	} else {
		watcher->writeIndex = index;
	}
}

static Array<int> toArray(const std::vector<int>& indexes, int capacity) {
	int count = std::min((int)indexes.size(), capacity);
	Array<int> result = Array_obj<int>::__new(count + 1, count + 1);
	for (int i = 0; i < count; ++i) {
		result[i] = indexes[i];
	}
	result[count] = -1;
	return result;
}

} // namespace

Dynamic crossbyte_libuv_poll_create(int capacity) {
	if (capacity < 0 || capacity > 1000000) {
		return null();
	}

	if (libuvPollType == 0) {
		libuvPollType = hxcpp_alloc_kind();
	}

	LibuvPollData* data = new LibuvPollData();
	data->create(capacity);
	return data;
}

void crossbyte_libuv_poll_prepare(Dynamic handle, Array<Dynamic> read, Array<Dynamic> write) {
	LibuvPollData* data = crossbyte_libuv_poll_data(handle);
	if (data == 0 || !data->ok) {
		return;
	}

	int readLength = read.mPtr ? read->length : 0;
	int writeLength = write.mPtr ? write->length : 0;
	if (readLength + writeLength > data->capacity) {
		hx::Throw(HX_CSTRING("Too many sockets in libuv poll"));
		return;
	}

	data->destroyWatchers();

	for (int i = 0; i < readLength; ++i) {
		addSocket(data, read[i], i, true);
	}
	for (int i = 0; i < writeLength; ++i) {
		addSocket(data, write[i], i, false);
	}

	for (int i = 0; i < (int)data->watchers.size(); ++i) {
		LibuvWatcher* watcher = data->watchers[i];
		int events = 0;
		if (watcher->readIndex >= 0) {
			events |= UV_READABLE;
		}
		if (watcher->writeIndex >= 0) {
			events |= UV_WRITABLE;
		}

		int status = uv_poll_start(&watcher->handle, events, LibuvPollData::onPoll);
		if (status != 0) {
			hx::Throw(HX_CSTRING("uv_poll_start failed"));
			return;
		}
	}
}

Array<Dynamic> crossbyte_libuv_poll_events(Dynamic handle, double timeout) {
	LibuvPollData* data = crossbyte_libuv_poll_data(handle);
	if (data == 0 || !data->ok) {
		Array<Dynamic> empty = Array_obj<Dynamic>::__new(2, 2);
		empty[0] = toArray(std::vector<int>(), 0);
		empty[1] = toArray(std::vector<int>(), 0);
		return empty;
	}

	data->readReady.clear();
	data->writeReady.clear();

	if (timeout > 0) {
		uint64_t timeoutMs = (uint64_t)std::ceil(timeout * 1000.0);
		uv_timer_start(&data->timer, crossbyte_libuv_on_timer, timeoutMs, 0);
	}

	hx::EnterGCFreeZone();
	if (timeout == 0) {
		uv_run(data->loop, UV_RUN_NOWAIT);
	} else {
		uv_run(data->loop, UV_RUN_DEFAULT);
	}
	hx::ExitGCFreeZone();

	if (timeout > 0) {
		uv_timer_stop(&data->timer);
	}

	Array<Dynamic> result = Array_obj<Dynamic>::__new(2, 2);
	result[0] = toArray(data->readReady, data->capacity);
	result[1] = toArray(data->writeReady, data->capacity);
	return result;
}

void crossbyte_libuv_poll_dispose(Dynamic handle) {
	LibuvPollData* data = crossbyte_libuv_poll_data(handle);
	if (data != 0) {
		data->destroy();
	}
}
