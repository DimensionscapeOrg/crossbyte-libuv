package crossbyte.libuv;

import crossbyte._internal.socket.poll.PollBackendRegistry;
import sys.net.Host;
import sys.net.Socket as SysSocket;
import utest.Assert;

class LibuvPollTest extends utest.Test {
	public function testAvailabilityReflectsNativeDefine():Void {
		#if (cpp && crossbyte_libuv_native)
		Assert.isTrue(LibuvPoll.isAvailable());
		#else
		Assert.isFalse(LibuvPoll.isAvailable());
		#end
	}

	public function testInstallOnlyRegistersWhenNativeAvailable():Void {
		PollBackendRegistry.clear();
		var installed = LibuvPoll.install();

		#if (cpp && crossbyte_libuv_native)
		Assert.isTrue(installed);
		Assert.isTrue(LibuvPoll.uninstall());
		#else
		Assert.isFalse(installed);
		#end

		PollBackendRegistry.clear();
	}

	#if (cpp && crossbyte_libuv_native)
	public function testNativeBackendPollsReadableSocket():Void {
		PollBackendRegistry.clear();
		Assert.isTrue(LibuvPoll.install());

		var server = new SysSocket();
		var client = new SysSocket();
		var peer:SysSocket = null;
		var backend = PollBackendRegistry.create(4);

		try {
			server.bind(new Host("127.0.0.1"), 0);
			server.listen(1);
			client.connect(new Host("127.0.0.1"), server.host().port);

			backend.prepare([server], []);
			backend.events(1.0);

			Assert.equals(0, backend.readIndexes[0]);
			peer = server.accept();
		} catch (e:Dynamic) {
			closeQuietly(peer);
			closeQuietly(client);
			closeQuietly(server);
			backend.dispose();
			PollBackendRegistry.clear();
			throw e;
		}

		backend.dispose();
		closeQuietly(peer);
		closeQuietly(client);
		closeQuietly(server);
		PollBackendRegistry.clear();
	}
	#end

	private static function closeQuietly(socket:SysSocket):Void {
		try {
			if (socket != null) {
				socket.close();
			}
		} catch (_:Dynamic) {}
	}
}
