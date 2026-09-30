# crossbyte-libuv

Optional libuv poll backend extension for CrossByte.

CrossByte core polls its sockets with its built-in backend (`poll(2)` on
native builds). This package installs a libuv-backed one through CrossByte's
internal poll backend seam: one `uv_poll_t` per socket, kept for as long as
the socket is registered, so a wait costs what libuv's epoll, kqueue or IOCP
wait costs rather than a scan of every socket.

Measured on Linux (WSL2, libuv 1.48, `bench/PollBench.hx`), per call:

| Sockets | Join or leave, built-in | Join or leave, libuv | Wait with 8 ready, built-in | Wait with 8 ready, libuv |
| --- | --- | --- | --- | --- |
| 1,000 | 114 us | 5.3 us | 81 us | 1.4 us |
| 4,000 | 343 us | 28 us | 380 us | 1.2 us |
| 10,000 | 2,268 us | 44 us | 1,632 us | 1.2 us |

Making the libuv backend's first watchers for a set costs more than the
built-in's (32 ms for 10,000 sockets), once.

## Usage

Install the backend in `main`, before anything creates a CrossByte runtime:

```haxe
import crossbyte.libuv.LibuvPoll;

class Main {
	public static function main():Void {
		if (!LibuvPoll.install()) {
			throw "crossbyte-libuv was not compiled with native libuv support";
		}

		// Create the Application, ServerApplication or runtime after installing.
		new MyServer();
	}
}
```

A runtime picks its backend when it is made, and again whenever its socket
set grows past its capacity (1,024 by default). So `install()` and
`uninstall()` throw `IllegalOperationError` once a runtime exists: an
`Application` subclass makes its runtime in its constructor, so calling
`install()` from there is too late.

To see what a runtime ended up with:

```haxe
LibuvPoll.isInstalled();          // runtimes made now get libuv
LibuvPoll.isActive();             // this thread's runtime polls through libuv
LibuvPoll.isActive(someRuntime);
```

`LibuvPoll` compiles on every target, so code shared with JavaScript can call
it; outside a native build with `-D crossbyte_libuv_native`, `install()`
returns `false` and the built-in backend stays.

If libuv cannot start a loop (out of descriptors, say), the backend's factory
returns null and the runtime falls back to the built-in backend.

## Building

Native builds need three things resolvable by haxelib name, because the
native code is included through `${haxelib:...}` paths:

- the hxcpp fork CrossByte is developed against (stock hxcpp does not build
  current CrossByte);
- `crossbyte`, whose externs include their own `Build.xml`;
- `crossbyte-libuv` itself.

```sh
haxelib git hxcpp https://github.com/dimensionscape/hxcpp.git production
haxelib dev crossbyte path/to/crossbyte
haxelib dev crossbyte-libuv path/to/crossbyte-libuv
```

After a `haxelib git` of hxcpp, build its tools once, from the directory
`haxelib path hxcpp` prints: `haxe compile.hxml` in `tools/run` and then in
`tools/hxcpp`.

Then build with the define:

```sh
haxe -lib crossbyte -lib crossbyte-libuv -D crossbyte_libuv_native -main Main --cpp export/app
```

Without `-D crossbyte_libuv_native` the package still compiles and
`LibuvPoll.install()` returns `false`.

### libuv

The native build compiles against libuv's headers and links its library.

- **Linux**: `sudo apt-get install libuv1-dev` (or your distribution's
  equivalent). Links `-luv`.
- **macOS**: `brew install libuv`, then pass its prefix:
  `-D LIBUV_INCLUDE=$(brew --prefix libuv)/include -D LIBUV_LIB=$(brew --prefix libuv)/lib`.
- **Windows (MSVC)**: build libuv with CMake (or take it from vcpkg) and pass
  where it is: `-D LIBUV_INCLUDE=C:/libuv/include -D LIBUV_LIB=C:/libuv/lib`.
  By default the build links `uv.lib`, which is the import library of
  `uv.dll`: copy `uv.dll` next to your executable (or onto `PATH`), or it
  will not start (exit code `0xC0000135`, a DLL not found).
  Add `-D LIBUV_STATIC` to link libuv's static library, `libuv.lib`, instead
  and ship no DLL. hxcpp links the static C runtime, so build that library
  with it too, or the link fails on unresolved `__imp_` symbols:
  `cmake -DCMAKE_POLICY_DEFAULT_CMP0091=NEW -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded ...`.

`LIBUV_INCLUDE` and `LIBUV_LIB` work on every platform, for a libuv that is
not where the compiler looks by default.

## Local Development

With the haxelibs above set up, `utest` installed (and `hxnodejs` for the
JavaScript check), and CrossByte checked out beside this repository
(`../crossbyte`):

```sh
haxe test.hxml                  # interpreter: the API without native support
haxe native-test.hxml           # native tests, into ../crossbyte/export/crossbyte-libuv-native-test
../crossbyte/export/crossbyte-libuv-native-test/LibuvNativeTestMain
haxe js-check.hxml && node export/js-check/node.js   # LibuvPoll compiles for Node and the browser
haxe bench.hxml && export/bench/PollBench             # needs `ulimit -n` above 10,000
```

`CB_ONLY=<class name part>` runs some of the native test classes.
