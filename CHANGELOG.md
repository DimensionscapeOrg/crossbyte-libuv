# Changelog

All notable changes to crossbyte-libuv will be documented in this file.

## Unreleased

### Changed
- `LibuvPoll.install()` and `uninstall()` throw `IllegalOperationError` once
  a CrossByte runtime exists. A runtime asks for its backend when it is made
  and again whenever its socket set outgrows its capacity, so installing
  after one existed moved it to libuv at its 1,025th socket, silently. Call
  `install()` in `main`, before the application is constructed.

### Added
- `LibuvPoll.isInstalled()`, and `LibuvPoll.isActive(runtime)` to see which
  backend a runtime polls with; there was no way to tell.
- `LibuvPoll` compiles on every target, so code shared with Node or the
  browser can call it; it failed there with "Type not found :
  PollBackendRegistry". Off native builds `install()` answers false.
- `-D LIBUV_STATIC` links libuv's static library on Windows instead of
  `uv.dll`'s import library. `LIBUV_LIB` no longer breaks every
  non-Windows link: its MSVC `-libpath:` flag was passed to GCC and Clang
  too. The README says how to build against current CrossByte (which needs
  the hxcpp fork and `haxelib dev crossbyte`) and what Windows needs at
  run time, and the extension's CI builds that way.
