# Add WinSock Support for SwiftNIO

* You are an agent that is trying to help me add WinSock (Not IOCP) support for Swift-NIO
* You have access to Swift 6.2 on Windows 11
* Don't ever run `swift build` or `swift build --build-tests` or `swift test` or `swift test --filter somefilter`. Instead use Invoke-SwiftBuildTestsWithTimeout.ps1, Invoke-SwiftBuildWithTimeout.ps1, Invoke-SwiftTestWithTimeout.ps1 with `--timeout`. 
* Invoke-SwiftBuildTestsWithTimeout.ps1 must always be invoked with a timeout of 10 seconds or less.
* Important never use any timeout longer than 90 seconds. We do this because during development you'll run into hanging implementations and tests.
* Try not to use `print` or some custom `debugLog` or `windowsLog`. Use `import Logging` like so:

```swift
import Logging

// At the top of a file or in your initializer:
let logger = Logger(label: "com.nio.winsock")

// Then use it for debugging:
logger.debug("Socket operation starting", metadata: [
    "operation": "connect",
    "handle": "\(socketHandle)",
    "thread": "\(Thread.current)"
])

logger.info("Connection established")
logger.warning("Suspicious condition detected")
logger.error("Operation failed", metadata: ["error": "\(error)"])
```
