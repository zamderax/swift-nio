# Windows Support TODO

## File I/O
- [ ] Rebuild `NIOFileHandle` functionality on Windows so `Tests/NIOPosixTests/NIOFileHandleTest.swift:8` can run.
- [ ] Implement Windows `NonBlockingFileIO` paths to un-skip `Tests/NIOPosixTests/NonBlockingFileIOTest.swift:10`.
- [ ] Enable Windows file-region support to restore `Tests/NIOPosixTests/FileRegionTest.swift:8`.

## Syscall Abstraction Layer
- [ ] Provide a Windows backend for the SAL event loop and channels (`Tests/NIOPosixTests/SALEventLoopTests.swift:8`, `SALChannelTests.swift:8`).
- [ ] Implement the Windows SAL context wrappers referenced by `Tests/NIOPosixTests/SyscallAbstractionLayer.swift:8` and `SyscallAbstractionLayerContext.swift:9`.
- [ ] Port the system-call performance helpers in `Tests/NIOPosixTests/SystemTest.swift:6` and `SystemCallWrapperHelpers.swift:8`.

## Socket Options & Event Loop Behaviours
- [ ] Support the single-thread bootstrap options used in `Tests/NIOPosixTests/EventLoopTest.swift:1447`.
- [ ] Add Windows implementations for socket-flag manipulation (`Tests/NIOPosixTests/SocketChannelTest.swift:627` and `764`).
- [ ] Recreate the drain-on-write-error behaviour checked in `Tests/NIOPosixTests/ChannelTests.swift:2983`.
- [ ] Expose SO_TIMESTAMP or a functional equivalent so `Tests/NIOPosixTests/ChannelTests.swift:3141` can execute.
- [ ] Implement `.socketOption` coverage to un-skip `Tests/NIOPosixTests/SocketOptionProviderTest.swift:8`.

## Datagram & Multicast Support
- [ ] Implement pending datagram write coalescing (`Tests/NIOPosixTests/PendingDatagramWritesManagerTests.swift:8`).
- [ ] Provide multicast membership/option support so `Tests/NIOPosixTests/MulticastTest.swift:8` can run.

## Pipe & Descriptor Utilities
- [ ] Extend `NIOPipeBootstrap` to accept single descriptor socketpairs on Windows (`Tests/NIOPosixTests/PipeChannelTest.swift:275`).
- [ ] Add Windows-friendly UNIX-domain path helpers and selector coverage to replace skips in `Tests/NIOPosixTests/TestUtils.swift:196` and `SelectorTest.swift:8`.

## Higher-Level Networking Features
- [ ] Implement the remaining Happy Eyeballs networking pieces required by `Tests/NIOPosixTests/HappyEyeballsTest.swift:6`.
- [ ] Restore system control message validation once cmsg inspection works on Windows (`Tests/NIOPosixTests/SystemTest.swift:6`).
- [ ] Provide full Windows coverage for `SocketAddress` POSIX-specific behaviour and vsock address parsing (`Tests/NIOPosixTests/SocketAddressTest.swift:23`, `VsockAddressTest.swift:8`).

## Cleanup
- [ ] Swap `getpid()` for `_getpid()` in `Sources/NIOHTTP1Server/main.swift:322` and `:339` to silence Windows deprecation warnings.
