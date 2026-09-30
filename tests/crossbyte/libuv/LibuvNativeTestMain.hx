package crossbyte.libuv;

import utest.Runner;
import utest.ui.Report;

@:access(crossbyte.core.CrossByte)
class LibuvNativeTestMain {
	public static function main():Void {
		// Before the runtime exists, as an application has to.
		if (!LibuvPoll.install()) {
			throw "crossbyte-libuv was not compiled with native libuv support";
		}
		new crossbyte.core.CrossByte(true, DEFAULT, true);

		var runner = new Runner();
		var only = Sys.getEnv("CB_ONLY");
		for (test in cases()) {
			var name = Type.getClassName(Type.getClass(test));
			if (only == null || only == "" || [for (part in only.split(",")) if (part != "" && name.indexOf(part) >= 0) part].length > 0) {
				runner.addCase(test);
			}
		}
		Report.create(runner);
		runner.run();
	}

	private static function cases():Array<utest.Test> {
		return [
			new LibuvPollTest(),
			#if (cpp && crossbyte_libuv_native)
			new LibuvWatcherTest(),
			new LibuvTimeoutTest(),
			new LibuvReadyBatchTest(),
			new LibuvRuntimeTest(),
			#if linux
			new LibuvStaleRegistrationTest(),
			#end
			#end
		];
	}
}
