package crossbyte.libuv;

import crossbyte.net.poll.PollBackend;
import crossbyte.net.poll.PollBackendFactory;
import crossbyte.net.poll.PollBackendRegistry;

class LibuvPoll {
	private static var __factory:PollBackendFactory = createBackend;

	public static function install():Bool {
		if (!isAvailable()) {
			return false;
		}

		PollBackendRegistry.register(__factory);
		return true;
	}

	public static function uninstall():Bool {
		return PollBackendRegistry.unregister(__factory);
	}

	public static function isAvailable():Bool {
		#if (cpp && crossbyte_libuv_native)
		return true;
		#else
		return false;
		#end
	}

	public static function createBackend(capacity:Int):PollBackend {
		#if (cpp && crossbyte_libuv_native)
		return new LibuvPollBackend(capacity);
		#else
		throw "crossbyte-libuv requires cpp target and -D crossbyte_libuv_native";
		#end
	}
}
