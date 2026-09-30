package crossbyte.libuv;

#if (cpp && crossbyte_libuv_native)
import crossbyte.core.CrossByte;
import crossbyte.events.Event;
import crossbyte.events.ProgressEvent;
import crossbyte.events.ServerSocketConnectEvent;
import crossbyte.net.ServerSocket;
import crossbyte.net.Socket as CBSocket;
import haxe.Timer;
import sys.net.Host;
import sys.net.Socket as SysSocket;
import sys.thread.Deque;
import sys.thread.Thread;
import utest.Assert;

/**
	The backend under a runtime, the way a server uses it.
**/
class LibuvRuntimeTest extends utest.Test {
	// Connections opened and closed one after another: each close is the
	// runtime's own, the socket closed first and deregistered after, and
	// each new connection is handed the descriptor the last one had. Every
	// echo has to come back, through watchers kept across all of it.
	public function testConnectionChurnThroughTheRuntime():Void {
		var runtime = CrossByte.current();
		var backend:LibuvPollBackend = cast @:privateAccess runtime.__socketRegistry.__poll;
		Assert.notNull(backend);
		var before = backend.stats();

		var server = new ServerSocket();
		var accepted = 0;
		var closed = 0;
		server.addEventListener(ServerSocketConnectEvent.CONNECT, e -> {
			accepted++;
			var peer:CBSocket = e.socket;
			peer.addEventListener(ProgressEvent.SOCKET_DATA, _ -> {
				peer.writeUTFBytes(peer.readUTFBytes(peer.bytesAvailable));
				peer.flush();
			});
			peer.addEventListener(Event.CLOSE, _ -> closed++);
		});
		server.bind(0, "127.0.0.1");
		server.listen();

		var connections = 200;
		var port = server.localPort;
		var outcome = new Deque<String>();
		Thread.create(() -> {
			var wrong = 0;
			var failure:String = null;
			for (i in 0...connections) {
				var socket = new SysSocket();
				try {
					socket.connect(new Host("127.0.0.1"), port);
					socket.output.writeString('line $i\n');
					socket.output.flush();
					if (socket.input.readLine() != 'line $i') {
						wrong++;
					}
				} catch (e:Dynamic) {
					failure = 'connection $i: $e';
				}
				TestSupport.closeQuietly(socket);
				if (failure != null) {
					break;
				}
			}
			outcome.add(failure != null ? failure : 'wrong $wrong');
		});

		var result:String = null;
		var deadline = Timer.stamp() + 30.0;
		while (result == null && Timer.stamp() < deadline) {
			runtime.pump(1 / 60, 0);
			Sys.sleep(0.0005);
			result = outcome.pop(false);
		}
		// Until the runtime has seen every connection closed.
		while (closed < accepted && Timer.stamp() < deadline) {
			runtime.pump(1 / 60, 0);
			Sys.sleep(0.0005);
		}
		server.close();
		for (_ in 0...3) {
			runtime.pump(1 / 60, 0);
		}

		Assert.equals("wrong 0", result);
		Assert.equals(connections, accepted);
		Assert.equals(connections, closed);
		Assert.isTrue(LibuvPoll.isActive(runtime));

		// The registry does not prepare an empty set, so the backend is not
		// told the last connection left until something else registers. The
		// prepare it would make then is made here.
		Assert.equals(0, @:privateAccess runtime.__socketRegistry.size);
		backend.prepare([], null);
		var after = backend.stats();
		Assert.equals(0, after.watchers, 'watchers left behind: ${after.watchers}');
		// One watcher for each connection, and one for the listener: core
		// watches listeners through the backend as well (dc59281).
		Assert.equals(connections + 1, after.created - before.created, "watchers made for 200 connections and their listener");
		Assert.equals(0, after.purges - before.purges);
		Assert.equals(0, after.dropped - before.dropped);
	}
}
#end
