package crossbyte.libuv;

import utest.Runner;
import utest.ui.Report;

@:access(crossbyte.core.CrossByte)
class LibuvNativeTestMain {
	public static function main():Void {
		new crossbyte.core.CrossByte(true, DEFAULT, true);
		var runner = new Runner();
		runner.addCase(new LibuvPollTest());
		Report.create(runner);
		runner.run();
	}
}
