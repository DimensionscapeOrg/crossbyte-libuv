# Changelog

All notable changes to crossbyte-libuv will be documented in this file.

## Unreleased

## 1.0.0 - 2026-10-02

### Fixed
- When libuv cannot start a loop (out of descriptors, say), the runtime falls
  back to the built-in backend instead of failing. A closed socket, or
  anything else that cannot be polled, is left out of the poll set rather
  than stopping every other socket from being polled.
- Each ready socket is reported once per wait, however many are ready at
  once. With more than 1,024 ready, some sockets were dispatched twice, and
  on Windows one wait reported at most 128 of them.
- A socket joining or leaving the set costs only that socket's watcher,
  instead of a rebuild of every watcher; the README has the figures. A
  descriptor reused by a new socket is polled for the new socket.
- A socket closed while it is still polled no longer makes the loop spin, or
  makes a later socket on the same descriptor look ready when it is not, even
  when a child process has inherited it. `LibuvPollBackend.remove(socket)`
  stops polling a socket at once, for a caller that can do it before the
  close.
- `HostApplication.advance(delta, socketTimeout)` with a socket timeout sees
  socket events; the wait used to end before it polled.
- `-D LIBUV_LIB` works with GCC and Clang, which were handed an MSVC-only
  flag.

### Changed
- `LibuvPoll.install()` and `uninstall()` throw `IllegalOperationError` once
  a CrossByte runtime exists, since a running runtime would otherwise switch
  backends silently when its socket set grew. Call `install()` in `main`,
  before the application is constructed.

### Added
- `LibuvPoll.isInstalled()`, and `LibuvPoll.isActive(runtime)` to see which
  backend a runtime polls with.
- `LibuvPoll` compiles on every target, so code shared with Node or the
  browser can call it. Off native builds `install()` returns false and
  `LibuvPoll.createBackend` returns null.
- `-D LIBUV_STATIC` links libuv's static library on Windows instead of
  `uv.dll`'s import library.
- The README says how to build against CrossByte (with the hxcpp fork and
  `haxelib dev crossbyte`) and what Windows needs at run time.
