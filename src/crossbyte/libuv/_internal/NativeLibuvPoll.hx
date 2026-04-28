package crossbyte.libuv._internal;

#if (cpp && crossbyte_libuv_native)
@:buildXml('<include name="${haxelib:crossbyte-libuv}/native/NativeLibuvPollBuild.xml"/>')
@:include("crossbyte/libuv/NativeLibuvPoll.h")
extern class NativeLibuvPoll {
	@:native("crossbyte_libuv_poll_create")
	public static function create(capacity:Int):Dynamic;

	@:native("crossbyte_libuv_poll_prepare")
	public static function prepare(handle:Dynamic, read:Array<sys.net.Socket>, write:Array<sys.net.Socket>):Void;

	@:native("crossbyte_libuv_poll_events")
	public static function events(handle:Dynamic, timeout:Float):Array<Array<Int>>;

	@:native("crossbyte_libuv_poll_dispose")
	public static function dispose(handle:Dynamic):Void;
}
#else
extern class NativeLibuvPoll {}
#end
