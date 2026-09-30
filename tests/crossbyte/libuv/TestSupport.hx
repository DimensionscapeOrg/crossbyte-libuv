package crossbyte.libuv;

import sys.net.Socket as SysSocket;

class TestSupport {
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
}
