package crossbyte.libuv;

import crossbyte._internal.socket.poll.PollBackendRegistry;
import crossbyte.errors.IllegalOperationError;
import sys.net.Host;
import sys.net.Socket as SysSocket;
import utest.Assert;

/**
	Runs in both mains. The native one installs the backend before it makes
	its runtime, as an application must; the interpreter one has no backend.
**/
class LibuvPollTest extends utest.Test {
	public function testAvailabilityReflectsNativeDefine():Void {
		#if (cpp && crossbyte_libuv_native)
		Assert.isTrue(LibuvPoll.isAvailable());
		#else
		Assert.isFalse(LibuvPoll.isAvailable());
		#end
	}

	#if (cpp && crossbyte_libuv_native)
	public function testRuntimeMadeAfterInstallPollsThroughLibuv():Void {
		Assert.isTrue(LibuvPoll.isInstalled());
		Assert.isTrue(LibuvPoll.isActive());
		Assert.isTrue(LibuvPoll.isActive(crossbyte.core.CrossByte.current()));
	}

	public function testInstallIsAnsweredWhenAlreadyInstalled():Void {
		Assert.isTrue(LibuvPoll.install());
		Assert.isTrue(LibuvPoll.isInstalled());
	}

	// A runtime made before install() used to move to libuv without a word
	// at its 1,025th socket, when its registry grew and asked the registry
	// for a backend again; uninstall() did the same the other way.
	public function testInstallAndUninstallRefuseOnceARuntimeExists():Void {
		var factory = @:privateAccess LibuvPoll.__factory;

		Assert.raises(() -> LibuvPoll.uninstall(), IllegalOperationError);
		Assert.isTrue(LibuvPoll.isInstalled());

		PollBackendRegistry.clear();
		try {
			Assert.raises(() -> LibuvPoll.install(), IllegalOperationError);
			Assert.isFalse(LibuvPoll.isInstalled());
		} catch (e:Dynamic) {
			PollBackendRegistry.register(factory);
			throw e;
		}
		PollBackendRegistry.register(factory);
		Assert.isTrue(LibuvPoll.isInstalled());
	}

	public function testNativeBackendPollsReadableSocket():Void {
		var server = new SysSocket();
		var client = new SysSocket();
		var peer:SysSocket = null;
		var backend = PollBackendRegistry.create(4);

		try {
			Assert.isOfType(backend, LibuvPollBackend);
			server.bind(new Host("127.0.0.1"), 0);
			server.listen(1);
			client.connect(new Host("127.0.0.1"), server.host().port);

			backend.prepare([server], []);
			backend.events(1.0);

			Assert.equals(0, backend.readIndexes[0]);
			peer = server.accept();
		} catch (e:Dynamic) {
			backend.dispose();
			TestSupport.closeAll([peer, client, server]);
			throw e;
		}

		backend.dispose();
		TestSupport.closeAll([peer, client, server]);
	}
	#else
	public function testInstallAnswersFalseWithoutNativeSupport():Void {
		Assert.isFalse(LibuvPoll.install());
		Assert.isFalse(LibuvPoll.isInstalled());
		Assert.isFalse(LibuvPoll.uninstall());
		Assert.isFalse(LibuvPoll.isActive());
	}
	#end
}
