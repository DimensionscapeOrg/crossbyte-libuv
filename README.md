# crossbyte-libuv

Optional libuv poll backend extension for CrossByte.

CrossByte core keeps its built-in Haxe/hxcpp poll backend as the fallback. This
package installs a libuv-backed implementation through CrossByte's internal poll
backend seam.

## Usage

```haxe
import crossbyte.libuv.LibuvPoll;

class Main {
	public static function main():Void {
		if (!LibuvPoll.install()) {
			throw "crossbyte-libuv was not compiled with native libuv support";
		}

		// Create/use CrossByte after installing the backend.
	}
}
```

Native support is opt-in:

```sh
haxe -lib crossbyte -lib crossbyte-libuv -D crossbyte_libuv_native --cpp export/app -main Main
```

The native build expects libuv headers and libraries to be available to hxcpp.
On Unix-like systems this usually means `libuv1-dev` or equivalent and `-luv`.
On Windows, provide libuv through your toolchain or define/link paths in your
hxcpp environment.

Without `-D crossbyte_libuv_native`, the package still type-checks and
`LibuvPoll.install()` returns `false`.

## Local Development

From this repo, point haxelib at your local CrossByte checkout:

```sh
haxelib dev crossbyte ../crossbyte
haxelib dev crossbyte-libuv .
haxelib install utest
haxe test.hxml
```

Native smoke build:

```sh
haxe native-test.hxml -D crossbyte_libuv_native
```
