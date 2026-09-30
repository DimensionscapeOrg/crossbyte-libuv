import crossbyte.libuv.LibuvPoll;

/**
	Built for Node and for the browser by js-check.hxml. Shared code that
	installs the backend has to compile there, it failed with "Type not
	found : PollBackendRegistry", and find that there is nothing to install.
**/
class JsCheck {
	public static function main():Void {
		var wrong = [];
		if (LibuvPoll.isAvailable()) {
			wrong.push("isAvailable");
		}
		if (LibuvPoll.install()) {
			wrong.push("install");
		}
		if (LibuvPoll.isInstalled()) {
			wrong.push("isInstalled");
		}
		if (LibuvPoll.uninstall()) {
			wrong.push("uninstall");
		}
		if (LibuvPoll.isActive()) {
			wrong.push("isActive");
		}

		if (wrong.length > 0) {
			throw "LibuvPoll answered true without a native backend: " + wrong.join(", ");
		}
		trace("LibuvPoll: no backend on JavaScript, as expected");
	}
}
