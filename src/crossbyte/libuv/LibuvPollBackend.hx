package crossbyte.libuv;

// Not built for JavaScript: there is no socket set there to poll, and core's
// poll backend registry does not exist on either JavaScript target.
#if !js
import crossbyte._internal.socket.poll.PollBackend;
import sys.net.Socket;
#if (cpp && crossbyte_libuv_native)
import crossbyte.libuv._internal.NativeLibuvPoll;
#end

/**
	A CrossByte poll backend on libuv: one `uv_poll_t` per socket, kept from
	one `prepare` to the next and changed only where the socket set changed.

	Made by `LibuvPoll`'s factory once `LibuvPoll.install()` has run; there is
	little reason to make one directly.
**/
class LibuvPollBackend implements PollBackend {
	private var __capacity:Int;
	private var __handle:Dynamic;
	private var __disposed:Bool = false;

	public var capacity(get, never):Int;
	public var readIndexes(default, null):Array<Int> = [-1];
	public var writeIndexes(default, null):Array<Int> = [-1];

	private inline function get_capacity():Int {
		return __capacity;
	}

	/**
		Starts a libuv loop for up to `capacity` sockets (a sizing hint: it
		grows past it). Throws when the extension was not compiled with
		`-D crossbyte_libuv_native`, or when libuv cannot start a loop;
		`LibuvPoll.createBackend` answers null for both instead.
	**/
	public function new(capacity:Int) {
		#if (cpp && crossbyte_libuv_native)
		__capacity = capacity;
		__handle = NativeLibuvPoll.create(capacity);
		if (__handle == null) {
			throw "crossbyte-libuv could not start a libuv loop";
		}
		var indexes = NativeLibuvPoll.prepare(__handle, null, null);
		readIndexes = indexes[0];
		writeIndexes = indexes[1];
		#else
		throw "crossbyte-libuv requires cpp target and -D crossbyte_libuv_native";
		#end
	}

	public function prepare(read:Array<Socket>, write:Array<Socket>):Void {
		#if (cpp && crossbyte_libuv_native)
		if (__disposed) {
			return;
		}

		var indexes = NativeLibuvPoll.prepare(__handle, read, write);
		readIndexes = indexes[0];
		writeIndexes = indexes[1];
		#end
	}

	public function events(timeout:Float):Void {
		#if (cpp && crossbyte_libuv_native)
		if (__disposed) {
			readIndexes[0] = -1;
			writeIndexes[0] = -1;
			return;
		}

		NativeLibuvPoll.events(__handle, timeout);
		#else
		readIndexes[0] = -1;
		writeIndexes[0] = -1;
		#end
	}

	/**
		Stops polling `socket` now rather than at the next `prepare`: the way
		to leave the poll set before the socket is closed, which is the order
		libuv needs. A socket closed while it is still polled is handled,
		see the native side's `closedUnder`, but can leave the kernel a
		registration only a fresh loop gets rid of.
	**/
	public function remove(socket:Socket):Void {
		#if (cpp && crossbyte_libuv_native)
		if (!__disposed && socket != null) {
			NativeLibuvPoll.remove(__handle, socket);
		}
		#end
	}

	/**
		Counters, for tests and diagnostics: `watchers` polling now,
		`tombstones` left for descriptors closed under their watcher,
		`created` and `retired` watchers since the backend was made,
		`purges` of the loop, and sockets `dropped` as unpollable.
	**/
	@:noCompletion public function stats():{
		watchers:Int,
		tombstones:Int,
		created:Int,
		retired:Int,
		purges:Int,
		dropped:Int
	} {
		#if (cpp && crossbyte_libuv_native)
		if (!__disposed) {
			var values = NativeLibuvPoll.stats(__handle);
			return {
				watchers: values[0],
				tombstones: values[1],
				created: values[2],
				retired: values[3],
				purges: values[4],
				dropped: values[5]
			};
		}
		#end
		return {
			watchers: 0,
			tombstones: 0,
			created: 0,
			retired: 0,
			purges: 0,
			dropped: 0
		};
	}

	public function dispose():Void {
		#if (cpp && crossbyte_libuv_native)
		if (__disposed) {
			return;
		}

		__disposed = true;
		NativeLibuvPoll.dispose(__handle);
		__handle = null;
		#end
	}
}
#end
