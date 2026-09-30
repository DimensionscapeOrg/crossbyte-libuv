package crossbyte.libuv;

import crossbyte.core.CrossByte;
import crossbyte.errors.IllegalOperationError;
#if !js
import crossbyte._internal.socket.poll.PollBackend;
import crossbyte._internal.socket.poll.PollBackendRegistry;
#end

/**
	Installs the libuv poll backend for the CrossByte runtimes made after it.

	Compiles on every target, so code shared with JavaScript can call it;
	only a cpp build with `-D crossbyte_libuv_native` has the backend, and
	everywhere else `install()` answers false and nothing changes.
**/
class LibuvPoll {
	#if !js
	private static var __factory:Int->PollBackend = createBackend;
	#end

	/**
		Makes every CrossByte runtime created from now on poll its sockets
		through libuv. Answers false when this build has no libuv backend
		(not cpp, or no `-D crossbyte_libuv_native`), and true when it is
		installed, including when it already was.

		Call it before the first runtime exists, in `main`, before the
		`Application` or `ServerApplication` is made. A runtime reads the
		backend when it is created and again each time its socket set outgrows
		its capacity, so installing afterwards moved a running runtime to
		libuv silently at its 1,025th socket.

		@throws IllegalOperationError When a CrossByte runtime already exists.
	**/
	public static function install():Bool {
		if (!isAvailable()) {
			return false;
		}

		#if !js
		if (isInstalled()) {
			return true;
		}

		__refuseWhileRunning("install");
		PollBackendRegistry.register(__factory);
		#end
		return true;
	}

	/**
		Puts back the built-in backend for runtimes created from now on.
		Answers false when the libuv backend was not installed.

		@throws IllegalOperationError When a CrossByte runtime exists: it
			would go back to the built-in backend in the middle of its run.
	**/
	public static function uninstall():Bool {
		#if !js
		if (!isInstalled()) {
			return false;
		}

		__refuseWhileRunning("uninstall");
		return PollBackendRegistry.unregister(__factory);
		#else
		return false;
		#end
	}

	/** Whether this build has the libuv backend: cpp with `-D crossbyte_libuv_native`. **/
	public static function isAvailable():Bool {
		#if (cpp && crossbyte_libuv_native)
		return true;
		#else
		return false;
		#end
	}

	/** Whether runtimes created now get the libuv backend. **/
	public static function isInstalled():Bool {
		#if !js
		return @:privateAccess PollBackendRegistry.__factory == __factory;
		#else
		return false;
		#end
	}

	/**
		Whether `runtime`, the calling thread's by default, polls its
		sockets through libuv. False on a thread with no runtime.
	**/
	public static function isActive(?runtime:CrossByte):Bool {
		#if (cpp && crossbyte_libuv_native)
		if (runtime == null) {
			runtime = @:privateAccess CrossByte.__currentOrNull();
		}
		if (runtime == null) {
			return false;
		}

		var registry = @:privateAccess runtime.__socketRegistry;
		return registry != null && Std.isOfType(@:privateAccess registry.__poll, LibuvPollBackend);
		#else
		return false;
		#end
	}

	#if !js
	/** The factory `install()` registers: a libuv backend for `capacity` sockets. **/
	public static function createBackend(capacity:Int):PollBackend {
		#if (cpp && crossbyte_libuv_native)
		return new LibuvPollBackend(capacity);
		#else
		throw "crossbyte-libuv requires cpp target and -D crossbyte_libuv_native";
		#end
	}
	#end

	private static function __refuseWhileRunning(action:String):Void {
		if (@:privateAccess CrossByte.__primordial != null) {
			throw new IllegalOperationError('LibuvPoll.$action() must run before the first CrossByte runtime is created: a runtime picks its poll backend when it is made and again whenever its socket set grows past its capacity, so changing it now would switch a running runtime mid-run. Call it in main(), before the Application is constructed.');
		}
	}
}
