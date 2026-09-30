# Changelog

All notable changes to crossbyte-libuv will be documented in this file.

## Unreleased

### Fixed
- A backend failure no longer takes the runtime with it. The factory threw
  where CrossByte's registry expects null, so a libuv that could not start
  a loop, out of descriptors, as a busy server is when it grows past its
  socket capacity, failed the runtime instead of leaving it on the
  built-in backend; now it answers null and the registry falls back. A
  closed socket, or anything else that cannot be polled, among the sockets
  is left out rather than thrown on: the throw left the registry dirty, so
  every update after prepared again and threw again, and nothing was
  polled for good. `LibuvPoll.createBackend` answers null off native
  builds too, where it threw.
- Each ready socket is reported once per wait. libuv takes 1,024 events
  from the kernel at a time and polls again, without blocking, while a
  batch comes back full, up to 48 times, and a level-triggered socket
  is in every batch it is still ready for; each report was passed on, so
  with more than 1,024 sockets ready some were dispatched twice and the
  list was cut short at capacity. On Windows the opposite: libuv takes 128
  completions at a time and the first report ended the wait, so one call
  reported at most 128 ready sockets and the rest waited for later calls.
- A change to the socket set costs what changed. Every register or
  deregister closed every watcher, ran the loop until they were freed and
  made them all again, each found by a linear scan: 3.7 ms per change at
  1,000 sockets, 22.6 ms at 4,000 and 75 ms at 10,000, measured, where the
  built-in backend takes 0.1, 0.34 and 2.3 ms. Watchers are now kept from
  one prepare to the next: a change costs 5.3, 28 and 44 us, since a socket
  in the same place as last time is a pointer compare. They are found by
  descriptor, and one whose descriptor now belongs to another socket is
  replaced, so a reused descriptor is polled for its new socket.
  `bench/PollBench.hx` measures it against the built-in backend.
- A socket closed while it is still polled is let go without disturbing
  the loop. CrossByte closes a socket and deregisters it afterwards; libuv
  needs polling stopped first, and when another process holds the socket,
  a child that inherited it, its epoll registration outlives the close
  and cannot be removed any more. libuv then re-polled without sleeping for
  the whole of every wait (189,806 `epoll_wait` calls in one 100 ms wait),
  or, once the descriptor went to a new socket, reported that socket ready
  on every call with nothing to read. The backend now leaves such a watcher
  in place as a tombstone, and a tombstone that fires, or a socket
  reported 64 calls in a row that `poll(2)` says is not ready, moves the
  live watchers to a fresh loop, whose epoll set does not have the stale
  registration. `LibuvPollBackend.remove(socket)` stops polling a socket
  at once, for a caller that can do it before the close.
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
