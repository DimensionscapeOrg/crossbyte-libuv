import utest.Runner;
import utest.ui.Report;

@:access(crossbyte.core.CrossByte)
class TestMain {
	public static function main():Void {
		new crossbyte.core.CrossByte(true, DEFAULT, true);
		var runner = new Runner();
		runner.addCase(new crossbyte.libuv.LibuvPollTest());
		Report.create(runner);
		runner.run();
	}
}
