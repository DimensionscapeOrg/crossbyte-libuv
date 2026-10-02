package crossbyte.libuv;

#if (cpp && crossbyte_libuv_native)
import crossbyte._internal.socket.HaxePollBackend;
import sys.net.Socket as SysSocket;
import utest.Assert;

/**
	More sockets ready at once than libuv takes from the kernel in a batch.
**/
class LibuvReadyBatchTest extends utest.Test {
	// libuv takes 1,024 events at a time and, while a batch comes back full,
	// polls again without blocking (up to 48 times); a level-triggered socket
	// is in every batch it is still ready for. Each must be reported once, and
	// the list must not be cut short at capacity.
	public function testEachReadySocketIsReportedOnce():Void {
		var count = 1500;
		var backend = new LibuvPollBackend(2048);
		var sockets = TestSupport.udps(count);
		var sender = TestSupport.udp();
		var set:Array<SysSocket> = [for (socket in sockets) socket];

		backend.prepare(set, null);
		backend.events(0);
		Assert.equals(count, backend.stats().watchers);

		// Loopback drops what overflows its backlog, so every socket is
		// checked with the built-in backend's poll(2) until all are ready.
		var oracle = new HaxePollBackend(count);
		oracle.prepare(set, null);
		var missing = [for (i in 0...count) i];
		for (round in 0...50) {
			for (i in missing) {
				TestSupport.poke(sender, sockets[i]);
			}
			Sys.sleep(0.01);
			oracle.events(0);
			var ready = new Map<Int, Bool>();
			for (i in TestSupport.ready(oracle.readIndexes)) {
				ready.set(i, true);
			}
			missing = [for (i in 0...count) if (!ready.exists(i)) i];
			if (missing.length == 0) {
				break;
			}
		}
		oracle.dispose();
		Assert.equals(0, missing.length, '${missing.length} sockets never became readable');

		for (pass in 0...2) {
			backend.events(0.5);
			var ready = TestSupport.ready(backend.readIndexes);
			var seen = new Map<Int, Bool>();
			for (index in ready) {
				seen.set(index, true);
			}
			Assert.equals(count, ready.length, 'pass $pass: ${ready.length} reported');
			Assert.equals(count, Lambda.count(seen), 'pass $pass: ${Lambda.count(seen)} distinct');
		}

		backend.dispose();
		TestSupport.closeAll(cast sockets);
		TestSupport.closeQuietly(sender);
	}
}
#end
