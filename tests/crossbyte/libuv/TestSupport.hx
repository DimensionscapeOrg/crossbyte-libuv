package crossbyte.libuv;

import haxe.io.Bytes;
import sys.net.Address;
import sys.net.Host;
import sys.net.Socket as SysSocket;
import sys.net.UdpSocket;

/**
	Sockets and a few POSIX calls for the native tests. The POSIX ones answer
	-1 (or do nothing) where they are not built.
**/
#if (cpp && linux)
@:cppFileCode("#include <unistd.h>\n#include <sys/resource.h>\n#include <time.h>\nstruct CrossByteLibuvTestSocket : public hx::Object { int socket; };\n")
#end
class TestSupport {
	private static var __ports:Map<Int, Bool> = new Map();

	/**
		A UDP socket bound to an ephemeral loopback port no other socket made
		here has had. hxcpp sets SO_REUSEADDR before binding, and Linux then
		hands two UDP sockets the same ephemeral port now and then, and only
		one of them receives what is sent to it.

		A socket that drew a taken port is closed before the next try, so the
		one returned still gets the lowest free descriptor: the tests that
		reuse a closed socket's descriptor depend on it.
	**/
	public static function udp():UdpSocket {
		while (true) {
			var socket = new UdpSocket();
			socket.bind(new Host("127.0.0.1"), 0);
			socket.setBlocking(false);
			var port = socket.host().port;
			if (!__ports.exists(port)) {
				__ports.set(port, true);
				return socket;
			}
			closeQuietly(socket);
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

	/** The descriptor under a socket. **/
	public static function descriptor(socket:SysSocket):Int {
		#if (cpp && linux)
		var handle:Dynamic = @:privateAccess socket.__s;
		return untyped __cpp__("reinterpret_cast<CrossByteLibuvTestSocket*>({0}.mPtr)->socket", handle);
		#else
		return -1;
		#end
	}

	/** A second descriptor for the same socket, as a child process holds one. **/
	public static function duplicate(descriptor:Int):Int {
		#if (cpp && linux)
		return untyped __cpp__("::dup({0})", descriptor);
		#else
		return -1;
		#end
	}

	public static function closeDescriptor(descriptor:Int):Void {
		#if (cpp && linux)
		if (descriptor >= 0) {
			untyped __cpp__("::close({0})", descriptor);
		}
		#end
	}

	/** CPU seconds this thread has used. **/
	public static function threadCpuTime():Float {
		#if (cpp && linux)
		return untyped __cpp__("([]() { struct timespec t; clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t); return (double)t.tv_sec + t.tv_nsec / 1e9; })()");
		#else
		return -1;
		#end
	}

	/** Sets the soft descriptor limit; answers the one it replaced. **/
	public static function setDescriptorLimit(soft:Int):Int {
		#if (cpp && linux)
		return untyped __cpp__("([](int soft) { struct rlimit r; getrlimit(RLIMIT_NOFILE, &r); int old = (int)r.rlim_cur; r.rlim_cur = (rlim_t)soft; setrlimit(RLIMIT_NOFILE, &r); return old; })({0})", soft);
		#else
		return -1;
		#end
	}
}
