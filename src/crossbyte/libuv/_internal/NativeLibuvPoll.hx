package crossbyte.libuv._internal;

#if (cpp && crossbyte_libuv_native)
// The linker flags follow the compiler, not the OS: `-libpath:` and `.lib`
// names are MSVC's, and handing `-libpath:` to GCC or Clang failed every
// non-Windows link that set LIBUV_LIB. With MSVC, `uv.lib` is the import
// library of libuv's `uv.dll`, which then has to ship beside the executable;
// `-D LIBUV_STATIC` links the static `libuv.lib` instead. Both names are
// what libuv's CMake build produces.
@:buildXml("
<files id='haxe'>
	<compilerflag value='-I${haxelib:crossbyte-libuv}/native'/>
	<compilerflag value='-I${LIBUV_INCLUDE}' if='LIBUV_INCLUDE'/>
	<file name='${haxelib:crossbyte-libuv}/native/NativeLibuvPoll.cpp'>
		<depend name='${haxelib:crossbyte-libuv}/native/NativeLibuvPoll.h'/>
	</file>
</files>

<target id='haxe'>
	<lib name='-L${LIBUV_LIB}' if='LIBUV_LIB' unless='isMsvc'/>
	<lib name='-luv' unless='isMsvc'/>
	<flag value='-libpath:${LIBUV_LIB}' if='LIBUV_LIB isMsvc'/>
	<lib name='uv.lib' if='isMsvc' unless='LIBUV_STATIC'/>
	<lib name='libuv.lib' if='isMsvc LIBUV_STATIC'/>
	<lib name='ws2_32.lib' if='isMsvc'/>
	<lib name='iphlpapi.lib' if='isMsvc'/>
	<lib name='psapi.lib' if='isMsvc'/>
	<lib name='userenv.lib' if='isMsvc'/>
	<lib name='user32.lib' if='isMsvc'/>
	<lib name='advapi32.lib' if='isMsvc'/>
	<lib name='dbghelp.lib' if='isMsvc'/>
	<lib name='ole32.lib' if='isMsvc'/>
	<lib name='shell32.lib' if='isMsvc'/>
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
