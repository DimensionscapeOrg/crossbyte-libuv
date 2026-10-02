package crossbyte.libuv;

#if (cpp && crossbyte_libuv_native)
import crossbyte.core.CrossByte;
import crossbyte.events.ProgressEvent;
import crossbyte.net.Socket as CBSocket;
import haxe.Timer;
import sys.net.Host;
import sys.net.Socket as SysSocket;
import sys.thread.Lock;
import sys.thread.Thread;
import utest.Assert;

/**
	A timed wait must poll, however long ago the loop last looked at its clock.
**/
class LibuvTimeoutTest extends utest.Test {
	// A host that pumps once a frame leaves the loop's cached clock one frame
	// stale, longer than the wait itself. libuv runs due timers before it
	// polls, so a timer armed from that clock would stop the loop before the
	// poll; the wait must arm it from the time now.
	public function testTimedWaitPollsWhenTheLoopClockIsStale():Void {
		var backend = new LibuvPollBackend(16);
		var target = TestSupport.udp();
		var sender = TestSupport.udp();

		backend.prepare([target], null);
		backend.events(0.005);
		Sys.sleep(0.03);
		TestSupport.poke(sender, target);
		Sys.sleep(0.01);

		backend.events(0.005);
		Assert.same([0], TestSupport.ready(backend.readIndexes));

		backend.dispose();
		TestSupport.closeAll([target, sender]);
	}

	// HostApplication's advance(1/60, 0.005), as a host framework calls it,
	// with a peer that sends a byte a second. Every byte must arrive.
	public function testHostDrivenPumpWithASocketTimeoutReceives():Void {
		var runtime = CrossByte.current();
		Assert.isTrue(LibuvPoll.isActive(runtime));

		var listener = new SysSocket();
		listener.bind(new Host("127.0.0.1"), 0);
		listener.listen(1);
		var port = listener.host().port;
		var finished = new Lock();
		var release = new Lock();

		Thread.create(() -> {
			var peer:SysSocket = null;
			try {
				peer = listener.accept();
				for (i in 0...3) {
					peer.output.writeByte(65 + i);
					peer.output.flush();
					Sys.sleep(1.0);
				}
				release.wait(10.0);
			} catch (_:Dynamic) {}
			TestSupport.closeAll([peer, listener]);
			finished.release();
		});

		var client = new CBSocket();
		var received = "";
		client.addEventListener(ProgressEvent.SOCKET_DATA, _ -> {
			received += client.readUTFBytes(client.bytesAvailable);
		});
		client.connect("127.0.0.1", port);

		var deadline = Timer.stamp() + 5.0;
		while (received.length < 3 && Timer.stamp() < deadline) {
			runtime.pump(1 / 60, 0.005);
			Sys.sleep(1 / 60);
		}

		Assert.equals("ABC", received);

		try {
			client.close();
		} catch (_:Dynamic) {}
		release.release();
		Assert.isTrue(finished.wait(10.0));
		// Let the runtime drop the closed socket before the next case.
		for (_ in 0...3) {
			runtime.pump(1 / 60, 0);
		}
	}
}
#end
