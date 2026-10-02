package crossbyte.libuv;

#if (cpp && crossbyte_libuv_native && linux)
import haxe.Timer;
import utest.Assert;

/**
	A socket closed while libuv still polled it, whose file another
	descriptor keeps open, as a child process does with every connection
	it inherited. Its epoll registration outlives the close and can no
	longer be removed by descriptor.

	A second descriptor made with dup() stands in for the child here.
**/
class LibuvStaleRegistrationTest extends utest.Test {
	// With no watcher left for the descriptor, libuv would re-poll without
	// sleeping for the whole wait. The waits must sleep, after one purge.
	public function testWaitSleepsAfterAClosedSocketStaysReady():Void {
		var backend = new LibuvPollBackend(16);
		var keep = TestSupport.udp();
		var closing = TestSupport.udp();
		var sender = TestSupport.udp();

		backend.prepare([keep, closing], null);
		backend.events(0);
		var held = TestSupport.duplicate(TestSupport.descriptor(closing));
		var port = closing.host().port;

		// Closed first and removed after, the order CrossByte uses.
		closing.close();
		backend.prepare([keep], null);
		// Its file becomes ready under a descriptor nothing polls any more.
		TestSupport.pokePort(sender, port);
		Sys.sleep(0.01);

		var cpu = TestSupport.threadCpuTime();
		var wall = Timer.stamp();
		for (_ in 0...5) {
			backend.events(0.05);
			Assert.same([], TestSupport.ready(backend.readIndexes));
		}
		cpu = TestSupport.threadCpuTime() - cpu;
		wall = Timer.stamp() - wall;

		Assert.isTrue(cpu < wall / 5, 'the waits used ${Math.round(cpu * 1000)} ms of CPU in ${Math.round(wall * 1000)} ms');
		Assert.equals(1, backend.stats().purges);

		// And what is still registered is still polled.
		TestSupport.poke(sender, keep);
		Assert.same([0], LibuvWatcherTest.waitForReady(backend, 2.0));

		backend.dispose();
		TestSupport.closeDescriptor(held);
		TestSupport.closeAll([keep, sender]);
	}

	// The descriptor is reused first, so the stale registration answers for
	// the new socket, which would be reported ready on every call with
	// nothing to read. The streak check must catch it and purge the loop.
	public function testReusedDescriptorDoesNotAnswerForTheClosedSocket():Void {
		var backend = new LibuvPollBackend(16);
		var closing = TestSupport.udp();
		var sender = TestSupport.udp();

		backend.prepare([closing], null);
		backend.events(0);
		var descriptor = TestSupport.descriptor(closing);
		var held = TestSupport.duplicate(descriptor);
		var port = closing.host().port;

		closing.close();
		var reuser = TestSupport.udp();
		Assert.equals(descriptor, TestSupport.descriptor(reuser));
		backend.prepare([reuser], null);
		TestSupport.pokePort(sender, port);
		Sys.sleep(0.01);

		var spurious = 0;
		for (_ in 0...200) {
			backend.events(0.01);
			if (TestSupport.ready(backend.readIndexes).length == 0) {
				break;
			}
			spurious++;
		}

		Assert.isTrue(spurious <= 64, 'reported $spurious times with nothing to read');
		Assert.same([], LibuvWatcherTest.waitForReady(backend, 0.05));
		Assert.isTrue(backend.stats().purges >= 1);

		// The socket that took the number is polled for itself.
		TestSupport.poke(sender, reuser);
		Assert.same([0], LibuvWatcherTest.waitForReady(backend, 2.0));

		backend.dispose();
		TestSupport.closeDescriptor(held);
		TestSupport.closeAll([reuser, sender]);
	}

	// remove() before close() (the order libuv needs, and the one the
	// registry can use) leaves nothing behind to purge.
	public function testRemovedBeforeCloseLeavesNothingToPurge():Void {
		var backend = new LibuvPollBackend(16);
		var keep = TestSupport.udp();
		var closing = TestSupport.udp();
		var sender = TestSupport.udp();

		backend.prepare([keep, closing], null);
		backend.events(0);
		var held = TestSupport.duplicate(TestSupport.descriptor(closing));
		var port = closing.host().port;

		backend.remove(closing);
		closing.close();
		backend.prepare([keep], null);
		TestSupport.pokePort(sender, port);
		Sys.sleep(0.01);

		var cpu = TestSupport.threadCpuTime();
		var wall = Timer.stamp();
		for (_ in 0...3) {
			backend.events(0.05);
		}
		cpu = TestSupport.threadCpuTime() - cpu;
		wall = Timer.stamp() - wall;

		Assert.isTrue(cpu < wall / 5, 'the waits used ${Math.round(cpu * 1000)} ms of CPU in ${Math.round(wall * 1000)} ms');
		Assert.equals(0, backend.stats().purges);
		Assert.equals(0, backend.stats().tombstones);

		backend.dispose();
		TestSupport.closeDescriptor(held);
		TestSupport.closeAll([keep, sender]);
	}
}
#end
