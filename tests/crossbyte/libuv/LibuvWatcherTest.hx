package crossbyte.libuv;

#if (cpp && crossbyte_libuv_native)
import sys.net.Socket as SysSocket;
import sys.net.UdpSocket;
import utest.Assert;

/**
	What a change to the socket set costs, and that each socket is still
	polled, under its own descriptor, after it.
**/
class LibuvWatcherTest extends utest.Test {
	// Every register or deregister closed all the watchers, ran the loop
	// until they were freed and made them all again: 129 made and 64 closed
	// here for one socket joining, where one is made.
	public function testJoiningOrLeavingChangesOnlyThatSocket():Void {
		var backend = new LibuvPollBackend(128);
		var sockets = TestSupport.udps(64);
		var extra = TestSupport.udp();
		var sender = TestSupport.udp();
		var set:Array<SysSocket> = [for (socket in sockets) socket];

		backend.prepare(set, null);
		backend.events(0);
		var start = backend.stats();
		Assert.equals(64, start.watchers);
		Assert.equals(64, start.created);
		Assert.equals(0, start.retired);

		set.push(extra);
		backend.prepare(set, null);
		backend.events(0);
		var joined = backend.stats();
		Assert.equals(65, joined.watchers);
		Assert.equals(65, joined.created);
		Assert.equals(0, joined.retired);

		// Removed the way the registry's DenseSet removes: the last socket
		// moves into the gap, so a socket changes position without leaving.
		var gone = set[10];
		set[10] = set[set.length - 1];
		set.pop();
		backend.prepare(set, null);
		backend.events(0);
		var left = backend.stats();
		Assert.equals(64, left.watchers);
		Assert.equals(65, left.created);
		Assert.equals(1, left.retired);

		// The socket that moved is reported at its new position.
		TestSupport.poke(sender, cast set[10]);
		Assert.same([10], waitForReady(backend, 2.0));

		backend.dispose();
		TestSupport.closeAll(cast sockets);
		TestSupport.closeAll([extra, gone, sender]);
	}

	// A closed socket, or a null, among the sockets used to fail the prepare
	// with a throw, and the registry, left dirty, prepared again and threw
	// again at every update after, so nothing was polled for good.
	public function testUnpollableEntriesAreLeftOut():Void {
		var backend = new LibuvPollBackend(16);
		var closed = TestSupport.udp();
		var live = TestSupport.udp();
		var sender = TestSupport.udp();
		closed.close();

		backend.prepare([closed, null, live], null);
		TestSupport.poke(sender, live);
		Assert.same([2], waitForReady(backend, 2.0));
		Assert.equals(1, backend.stats().watchers);

		backend.dispose();
		TestSupport.closeAll([live, sender]);
	}

	// Watchers are found by descriptor now, and descriptors are reused: a
	// socket that takes a closed one's number must get its own watcher, not
	// inherit the old one's registration.
	public function testReusedDescriptorIsPolledForTheNewSocket():Void {
		var backend = new LibuvPollBackend(16);
		var keep = TestSupport.udp();
		var first = TestSupport.udp();
		var sender = TestSupport.udp();

		backend.prepare([keep, first], null);
		backend.events(0);
		var descriptor = TestSupport.descriptor(first);

		// Closed first and removed after, the order CrossByte uses today.
		first.close();
		var second = TestSupport.udp();
		#if linux
		Assert.equals(descriptor, TestSupport.descriptor(second));
		#end

		backend.prepare([keep, second], null);
		Assert.same([], waitForReady(backend, 0.05));
		TestSupport.poke(sender, second);
		Assert.same([1], waitForReady(backend, 2.0));
		TestSupport.drain(second);
		// On Windows the completion for a read already made can still be
		// queued; libuv allows that one spurious report.
		backend.events(0);
		Assert.same([], waitForReady(backend, 0.05));

		backend.dispose();
		TestSupport.closeAll([keep, second, sender]);
	}

	// The same, with the new socket arriving while the closed one is still
	// in the list, as when a socket is closed and another accepted in one
	// dispatch pass.
	public function testReusedDescriptorWhileTheClosedSocketIsStillListed():Void {
		var backend = new LibuvPollBackend(16);
		var first = TestSupport.udp();
		var sender = TestSupport.udp();

		backend.prepare([first], null);
		backend.events(0);
		first.close();
		var second = TestSupport.udp();

		backend.prepare([first, second], null);
		TestSupport.poke(sender, second);
		Assert.same([1], waitForReady(backend, 2.0));

		backend.dispose();
		TestSupport.closeAll([second, sender]);
	}

	// The registry never lists a socket twice, but a caller of the backend
	// can. One watcher answers, for the first place.
	public function testSocketListedTwiceIsReportedOnce():Void {
		var backend = new LibuvPollBackend(16);
		var twice = TestSupport.udp();
		var other = TestSupport.udp();
		var sender = TestSupport.udp();

		backend.prepare([twice, other, twice], null);
		Assert.equals(2, backend.stats().watchers);
		TestSupport.poke(sender, twice);
		Assert.same([0], waitForReady(backend, 2.0));

		backend.dispose();
		TestSupport.closeAll([twice, other, sender]);
	}

	// Asked to leave while listed twice, and listed twice again: only one
	// place may point at a watcher, or the other goes on pointing at it
	// after the loop has freed it, and the next prepare reads it.
	public function testRemovingASocketListedTwice():Void {
		var backend = new LibuvPollBackend(16);
		var twice = TestSupport.udp();
		var other = TestSupport.udp();
		var sender = TestSupport.udp();

		backend.prepare([twice, other, twice], null);
		backend.events(0);
		backend.remove(twice);
		backend.events(0);
		backend.prepare([twice, other, twice], null);
		Assert.equals(2, backend.stats().watchers);
		TestSupport.poke(sender, twice);
		Assert.same([0], waitForReady(backend, 2.0));

		backend.dispose();
		TestSupport.closeAll([twice, other, sender]);
	}

	// A socket asked to leave with remove(), before it is closed, the
	// order libuv needs, is gone at once, and the next prepare does not
	// bring it back.
	public function testRemoveStopsPollingAtOnce():Void {
		var backend = new LibuvPollBackend(16);
		var keep = TestSupport.udp();
		var leaving = TestSupport.udp();
		var sender = TestSupport.udp();

		backend.prepare([keep, leaving], null);
		backend.events(0);
		backend.remove(leaving);
		Assert.equals(1, backend.stats().watchers);
		Assert.equals(1, backend.stats().retired);

		TestSupport.poke(sender, leaving);
		Assert.same([], waitForReady(backend, 0.05));

		leaving.close();
		backend.prepare([keep], null);
		Assert.equals(1, backend.stats().watchers);
		Assert.equals(0, backend.stats().tombstones);

		backend.dispose();
		TestSupport.closeAll([keep, sender]);
	}

	/** Waits up to `timeout` for something to be reported, and answers what was. **/
	public static function waitForReady(backend:LibuvPollBackend, timeout:Float):Array<Int> {
		var deadline = haxe.Timer.stamp() + timeout;
		do {
			backend.events(0.01);
			var ready = TestSupport.ready(backend.readIndexes);
			if (ready.length > 0) {
				ready.sort((a, b) -> a - b);
				return ready;
			}
		} while (haxe.Timer.stamp() < deadline);
		return [];
	}
}
#end
