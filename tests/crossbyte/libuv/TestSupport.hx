package crossbyte.libuv;

import haxe.io.Bytes;
import sys.net.Address;
import sys.net.Host;
import sys.net.Socket as SysSocket;
import sys.net.UdpSocket;

/** Sockets for the native tests. **/
class TestSupport {
	private static var __ports:Map<Int, Bool> = new Map();

	/**
		A UDP socket bound to an ephemeral loopback port no other socket made
		here has had. hxcpp sets SO_REUSEADDR before binding, and Linux then
		hands two UDP sockets the same ephemeral port now and then, 27 of
		1,500 once, and only one of them receives what is sent to it.
	**/
	public static function udp():UdpSocket {
		var shared:Array<UdpSocket> = [];
		while (true) {
			var socket = new UdpSocket();
			socket.bind(new Host("127.0.0.1"), 0);
			socket.setBlocking(false);
			var port = socket.host().port;
			if (!__ports.exists(port)) {
				__ports.set(port, true);
				for (other in shared) {
					closeQuietly(other);
				}
				return socket;
			}
			shared.push(socket);
		}
	}

	public static function udps(count:Int):Array<UdpSocket> {
		return [for (_ in 0...count) udp()];
	}

	/** Makes `target` readable by sending it one datagram from `sender`. **/
	public static function poke(sender:UdpSocket, target:SysSocket):Void {
		pokePort(sender, target.host().port);
	}

	/** Sends one datagram to a loopback port. **/
	public static function pokePort(sender:UdpSocket, port:Int):Void {
		var address = new Address();
		address.host = new Host("127.0.0.1").ip;
		address.port = port;
		sender.sendTo(Bytes.ofString("x"), 0, 1, address);
	}

	/** Reads whatever datagram `socket` holds, so it stops being readable. **/
	public static function drain(socket:UdpSocket):Void {
		var buffer = Bytes.alloc(64);
		var from = new Address();
		try {
			while (true) {
				socket.readFrom(buffer, 0, buffer.length, from);
			}
		} catch (_:Dynamic) {}
	}

	public static function closeAll(sockets:Array<Dynamic>):Void {
		for (socket in sockets) {
			closeQuietly(socket);
		}
	}

	public static function closeQuietly(socket:SysSocket):Void {
		try {
			if (socket != null) {
				socket.close();
			}
		} catch (_:Dynamic) {}
	}

	/** Positions reported ready, up to the -1 that ends them. **/
	public static function ready(indexes:Array<Int>):Array<Int> {
		var result = [];
		for (index in indexes) {
			if (index == -1) {
				break;
			}
			result.push(index);
		}
		return result;
	}
}
