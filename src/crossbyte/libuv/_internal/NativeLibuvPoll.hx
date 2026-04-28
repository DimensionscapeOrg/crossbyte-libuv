package crossbyte.libuv._internal;

#if (cpp && crossbyte_libuv_native)
@:buildXml("
<files id='haxe'>
	<compilerflag value='-I${haxelib:crossbyte-libuv}/native'/>
	<compilerflag value='-I${LIBUV_INCLUDE}' if='LIBUV_INCLUDE'/>
	<file name='${haxelib:crossbyte-libuv}/native/NativeLibuvPoll.cpp'>
		<depend name='${haxelib:crossbyte-libuv}/native/NativeLibuvPoll.h'/>
	</file>
</files>

<target id='haxe'>
	<lib name='-L${LIBUV_LIB}' if='LIBUV_LIB' unless='windows'/>
	<lib name='-luv' unless='windows'/>
	<flag value='-libpath:${LIBUV_LIB}' if='LIBUV_LIB'/>
	<lib name='uv.lib' if='windows'/>
	<lib name='ws2_32.lib' if='windows'/>
	<lib name='iphlpapi.lib' if='windows'/>
	<lib name='psapi.lib' if='windows'/>
	<lib name='userenv.lib' if='windows'/>
</target>
")
@:include("NativeLibuvPoll.h")
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
