import crossbyte._internal.socket.HaxePollBackend;
import crossbyte._internal.socket.poll.PollBackend;
import crossbyte.libuv.LibuvPollBackend;
import haxe.Timer;
import haxe.io.Bytes;
import sys.net.Address;
import sys.net.Host;
import sys.net.Socket;
import sys.net.UdpSocket;

/**
	What a poll backend costs a server: a prepare when one socket joins or
	leaves the set, which the registry does on every accept and every close,
	and a wait with a few sockets ready.

	haxe bench.hxml, then run the binary with a descriptor limit above
	10,000 (`ulimit -n 65536`).
**/
class PollBench {
	static inline var READY = 8;

	public static function main():Void {
		var sizes = [1000, 4000, 10000];
		var arg = Sys.args();
		if (arg.length > 0) {
			sizes = [for (value in arg[0].split(",")) Std.parseInt(value)];
		}

		Sys.println("sockets  backend   first prepare   churn prepare   events(0), 8 ready   events(0), none ready");
		for (size in sizes) {
			var sockets = [for (_ in 0...size) udp()];
			var sender = udp();
			for (kind in ["built-in", "libuv"]) {
				var backend:PollBackend = kind == "libuv" ? new LibuvPollBackend(size + 64) : new HaxePollBackend(size + 64);
				measure(kind, backend, sockets, sender);
				backend.dispose();
			}
			for (socket in sockets) {
				socket.close();
			}
			sender.close();
		}
	}

	static function measure(kind:String, backend:PollBackend, sockets:Array<UdpSocket>, sender:UdpSocket):Void {
		var set:Array<Socket> = [for (socket in sockets) socket];

		var start = Timer.stamp();
		backend.prepare(set, null);
		backend.events(0);
		var first = Timer.stamp() - start;

		// One socket leaves, the way the registry's DenseSet removes it, the
		// last one moves into the gap, and comes back.
		var rounds = 0;
		start = Timer.stamp();
		var budget = start + 2.0;
		while (rounds < 400 && (rounds < 4 || Timer.stamp() < budget)) {
			var at = (rounds * 7919) % set.length;
			var leaving = set[at];
			set[at] = set[set.length - 1];
			set.pop();
			backend.prepare(set, null);
			backend.events(0);
			set.push(leaving);
			backend.prepare(set, null);
			backend.events(0);
			rounds++;
		}
		var churn = (Timer.stamp() - start) / (rounds * 2);

		var idle = time(backend, 2000);

		// Eight readable ones, left unread so every call reports them.
		var readable = [];
		for (i in 0...READY) {
			var socket = sockets[(i * 997) % sockets.length];
			poke(sender, socket);
			readable.push(socket);
		}
		Sys.sleep(0.05);
		backend.events(0);
		var reported = 0;
		for (index in backend.readIndexes) {
			if (index == -1) {
				break;
			}
			reported++;
		}
		var busy = time(backend, 2000);
		for (socket in readable) {
			drain(socket);
		}

		Sys.println('${pad(set.length, 7)}  ${padRight(kind, 8)}  ${micros(first)}  ${micros(churn)}  ${micros(busy)} ($reported ready)  ${micros(idle)}');
	}

	static function time(backend:PollBackend, calls:Int):Float {
		var start = Timer.stamp();
		for (_ in 0...calls) {
			backend.events(0);
		}
		return (Timer.stamp() - start) / calls;
	}

	static var ports:Map<Int, Bool> = new Map();

	// hxcpp binds with SO_REUSEADDR, and Linux then gives two UDP sockets
	// the same ephemeral port now and then; only one of them receives.
	static function udp():UdpSocket {
		while (true) {
			var socket = new UdpSocket();
			socket.bind(new Host("127.0.0.1"), 0);
			socket.setBlocking(false);
			var port = socket.host().port;
			if (!ports.exists(port)) {
				ports.set(port, true);
				return socket;
			}
			socket.close();
		}
	}

	static function poke(sender:UdpSocket, target:UdpSocket):Void {
		var address = new Address();
		address.host = new Host("127.0.0.1").ip;
		address.port = target.host().port;
		sender.sendTo(Bytes.ofString("x"), 0, 1, address);
	}

	static function drain(socket:UdpSocket):Void {
		var buffer = Bytes.alloc(16);
		var from = new Address();
		try {
			while (true) {
				socket.readFrom(buffer, 0, buffer.length, from);
			}
		} catch (_:Dynamic) {}
	}

	static function micros(seconds:Float):String {
		var value = seconds * 1e6;
		var text = value >= 100 ? Std.string(Math.round(value)) : Std.string(Math.round(value * 10) / 10);
		return pad(text + " us", 14);
	}

	static function pad(value:Dynamic, width:Int):String {
		var text = Std.string(value);
		while (text.length < width) {
			text = " " + text;
		}
		return text;
	}

	static function padRight(value:String, width:Int):String {
		while (value.length < width) {
			value += " ";
		}
		return value;
	}
}
