package crossbyte.libuv;

import crossbyte.libuv._internal.NativeLibuvPoll;
import crossbyte.net.poll.PollBackend;
import crossbyte.net.poll.PollEvents;
import sys.net.Socket;

class LibuvPollBackend implements PollBackend {
	private var __capacity:Int;
	private var __handle:Dynamic;
	private var __disposed:Bool = false;

	public var capacity(get, never):Int;

	private inline function get_capacity():Int {
		return __capacity;
	}

	public function new(capacity:Int) {
		#if (cpp && crossbyte_libuv_native)
		__capacity = capacity;
		__handle = NativeLibuvPoll.create(capacity);
		#else
		throw "crossbyte-libuv requires cpp target and -D crossbyte_libuv_native";
		#end
	}

	public function prepare(read:Array<Socket>, write:Array<Socket>):Void {
		#if (cpp && crossbyte_libuv_native)
		if (__disposed) {
			return;
		}

		NativeLibuvPoll.prepare(__handle, read != null ? read : [], write != null ? write : []);
		#end
	}

	public function events(timeout:Float):PollEvents {
		#if (cpp && crossbyte_libuv_native)
		if (__disposed) {
			return {readIndexes: [-1], writeIndexes: [-1]};
		}

		var result = NativeLibuvPoll.events(__handle, timeout);
		return {
			readIndexes: result[0],
			writeIndexes: result[1]
		};
		#else
		return {readIndexes: [-1], writeIndexes: [-1]};
		#end
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
