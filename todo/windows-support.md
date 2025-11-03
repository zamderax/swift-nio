# Windows Support TODO

## File I/O
- [x] Rebuild `NIOFileHandle` functionality on Windows so `Tests/NIOPosixTests/NIOFileHandleTest.swift:8` can run.
- [x] Implement Windows `NonBlockingFileIO` paths to un-skip `Tests/NIOPosixTests/NonBlockingFileIOTest.swift:10`.
- [x] Enable Windows file-region support to restore `Tests/NIOPosixTests/FileRegionTest.swift:8`.

## Syscall Abstraction Layer
- [x] Provide a Windows backend for the SAL event loop and channels (`Tests/NIOPosixTests/SALEventLoopTests.swift:8`, `SALChannelTests.swift:8`).
- [x] Implement the Windows SAL context wrappers referenced by `Tests/NIOPosixTests/SyscallAbstractionLayer.swift:8` and `SyscallAbstractionLayerContext.swift:9`.
- [x] Port the system-call performance helpers in `Tests/NIOPosixTests/SystemTest.swift:6` and `SystemCallWrapperHelpers.swift:8`.

## Socket Options & Event Loop Behaviours
- [x] Support the single-thread bootstrap options used in `Tests/NIOPosixTests/EventLoopTest.swift:1447`.
- [x] Add Windows implementations for socket-flag manipulation (`Tests/NIOPosixTests/SocketChannelTest.swift:627` and `764`).
- [x] Recreate the drain-on-write-error behaviour checked in `Tests/NIOPosixTests/ChannelTests.swift:2983`.
- [x] Expose SO_TIMESTAMP or a functional equivalent so `Tests/NIOPosixTests/ChannelTests.swift:3141` can execute.
- [x] Implement `.socketOption` coverage to un-skip `Tests/NIOPosixTests/SocketOptionProviderTest.swift:8`.

## Datagram & Multicast Support
- [x] Implement pending datagram write coalescing (`Tests/NIOPosixTests/PendingDatagramWritesManagerTests.swift:8`).
- [x] Provide multicast membership/option support so `Tests/NIOPosixTests/MulticastTest.swift:8` can run.

## Pipe & Descriptor Utilities
- [x] Extend `NIOPipeBootstrap` to accept single descriptor socketpairs on Windows (`Tests/NIOPosixTests/PipeChannelTest.swift:275`).
- [x] Add Windows-friendly UNIX-domain path helpers and selector coverage to replace skips in `Tests/NIOPosixTests/TestUtils.swift:196` and `SelectorTest.swift:8`.

## Higher-Level Networking Features
- [x] Implement the remaining Happy Eyeballs networking pieces required by `Tests/NIOPosixTests/HappyEyeballsTest.swift:6`.
- [x] Restore system control message validation once cmsg inspection works on Windows (`Tests/NIOPosixTests/SystemTest.swift:6`).
- [x] Provide full Windows coverage for `SocketAddress` POSIX-specific behaviour and vsock address parsing (`Tests/NIOPosixTests/SocketAddressTest.swift:23`, `VsockAddressTest.swift:8`).

## Cleanup
- [x] Swap `getpid()` for `_getpid()` in `Sources/NIOHTTP1Server/main.swift:322` and `:339` to silence Windows deprecation warnings.

## Platform Parity Follow-ups
- [x] Provide Windows definitions for `Posix.UIO_MAXIOV`/`SHUT_*` (`Sources/NIOPosix/System.swift:484-497`) instead of trapping with `fatalError("unsupported OS")`.
- [x] Implement a Windows `System.enumerateInterfaces()` path so `Tests/NIOCoreTests/UtilitiesTest.swift:26` and multicast coverage can execute.
- [x] Populate broadcast/multicast metadata when building `NIONetworkDevice` on Windows (`Sources/NIOCore/Interfaces.swift:357`) to match POSIX behaviour.
- [x] Revisit Windows skips for `ChannelOptions.socket` helpers in embedded tests (`Tests/NIOEmbeddedTests/AsyncTestingChannelTests.swift:691`, `EmbeddedChannelTest.swift:702`) by exposing the necessary socket constants.
- [x] Re-enable the deprecated interface-based multicast tests on Windows by rewriting them to use the new `System.enumerateDevices()` helpers instead of `XCTSkip` (`Tests/NIOPosixTests/MulticastTest.swift:56`, `:283`, `:358`, `:437`, `:502`).
- [x] Provide Windows-friendly implementations of the "configured stream/datagram socket helper" tests so they run via duplicated overlapped sockets (`Tests/NIOPosixTests/SocketChannelTest.swift:404`, `:451`).
- [x] Implement a Windows-backed `System.sendfile` (via `TransmitFile`) so zero-copy file sends work instead of trapping on `fatalError("unsupported OS")` (`Sources/NIOPosix/System.swift:799`).
- [x] Implement WinSock-backed multi-message datagram support (`sendmmsg`/`recvmmsg`) on Windows (`Sources/NIOPosix/BSDSocketAPIWindows.swift:462`).
- [x] Add Windows coverage for the Unix-domain-specific paths in `Tests/NIOPosixTests/PendingDatagramWritesManagerTests.swift` by supplying IPv4/IPv6 datagram scenarios instead of trapping with `fatalError`.
