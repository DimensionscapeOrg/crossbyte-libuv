# Changelog

All notable changes to crossbyte-libuv will be documented in this file.

## Unreleased

### Fixed
- A host-driven runtime polls its sockets when it is given a socket
  timeout. `HostApplication.advance(delta, socketTimeout)`, a host
  pumping once a frame with a few milliseconds to wait, saw no socket
  events while its socket set stayed the same: the wait's timer was armed
  from the loop's cached clock, a frame old and so already past the
  deadline, and libuv runs due timers before it polls, so the timer ended
  every wait before its poll. The timer is armed from the time now.

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
