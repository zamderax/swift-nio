# Windows IOCP Backend Plan

SwiftNIO’s Windows support currently relies on a WSAPoll-based selector that mirrors readiness semantics from epoll/kqueue. Long-term we want to replace it with an I/O Completion Port (IOCP) backend to unlock scalable asynchronous I/O. This note captures the work needed so we can tackle it in focussed slices.

## Current State
- `SelectorWSAPoll` wires sockets into a `pollfd` array and drives tasks via readiness notifications. `reregister0`/`deregister0` are now implemented, but the design still inherits O(n) scans and timer gaps.
- Channel implementations (`BaseSocketChannel`, `SocketChannel`, `ServerSocketChannel`) issue synchronous `recv`/`send` style syscalls after being told a descriptor is readable/writable. There is no overlapped I/O or IOCP integration today.
- Wakeups use `QueueUserAPC` and timers are simulated by `SleepEx` when no sockets are registered.

## IOCP Design Goals
- Back the selector with `CreateIoCompletionPort` and consume completions via `GetQueuedCompletionStatusEx`.
- Preserve the existing `SelectorEventSet` interface so higher-level event loop code stays largely intact, mapping IOCP completions to `.read`, `.write`, `.reset`, etc.
- Support cancellation and teardown by cancelling pending overlapped operations before sockets are closed.
- Integrate timers without blocking threads (e.g. waitable timers queued into the completion port or a deadline wheel combined with `GQCS` timeouts).
- Maintain wakeup semantics (`EventLoop.execute` should still unblock the selector promptly).

## Work Breakdown
1. **Selector Infrastructure**
   - Introduce `SelectorIOCP` implementing `_SelectorBackendProtocol`.
   - Store the IOCP handle plus an array of `OVERLAPPED_ENTRY` records (replaces the existing `pollfd` buffer).
   - Wire `wakeup0` to `PostQueuedCompletionStatus`.
   - Provide lifecycle management (`initialiseState0`, `close0`) around the IOCP handle.
2. **Overlapped I/O Plumbing**
   - Define pooled `IOCPOverlapped`/`IOCPWorkItem` structures holding buffers, state, and completion callbacks.
   - Update socket channels to post overlapped `WSARecv`, `WSASend`, `AcceptEx`, `ConnectEx` operations whenever interest is registered, owning buffers until the completion fires.
   - Translate completions into event loop tasks that fire the existing channel read/write paths with the received data.
3. **Timer & Shutdown Integration**
   - Decide on timer strategy (waitable timer tied to IOCP vs. deadline heap with timeouts on `GQCS`).
   - Ensure graceful shutdown cancels outstanding operations (`CancelIoEx`) before closing sockets, mirroring the current `closeGently` semantics.
4. **Testing & Tooling**
   - Extend `SelectorTest` with Windows-specific coverage for wakeups, read/write completions, and cancellation.
   - Add end-to-end channel tests that stress simultaneous reads/writes, connection teardown, and server accept loops under IOCP.
   - Document the configuration toggle (e.g. `SWIFTNIO_USE_IOCP`) and update CI once the backend is feature-complete.

## Next Steps
1. Land the selector scaffolding (Step 1) behind an opt-in flag while it still falls back to WSAPoll.
2. Incrementally update channel code to post overlapped reads/writes, starting with TCP sockets.
3. Validate behaviour with focused tests before switching the default backend on Windows.

