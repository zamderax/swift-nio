//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2024 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Dispatch
import Foundation

#if os(Windows)
import WinSDK
import ucrt
#endif

#if !RUNNING_INTEGRATION_TESTS
@testable import NIOPosix
#endif

enum TestError: Error {
    case writeFailed
    case wouldBlock
}

public func measureRunTime(_ body: () throws -> Int) rethrows -> TimeInterval {
    func measureOne(_ body: () throws -> Int) rethrows -> TimeInterval {
        let start = DispatchTime.now().uptimeNanoseconds
        _ = try body()
        let end = DispatchTime.now().uptimeNanoseconds
        return Double(end - start) / 1_000_000
    }

    _ = try measureOne(body)
    var measurements = Array(repeating: 0.0, count: 10)
    for i in 0..<10 {
        measurements[i] = try measureOne(body)
    }

    return measurements.min()!
}

public func measureRunTimeAndPrint(desc: String, body: () throws -> Int) rethrows {
    print("measuring: \(desc)")
    print("\(try measureRunTime(body))s")
}

#if os(Windows)
private let nullDeviceName = "NUL"
#else
private let nullDeviceName = "/dev/null"
#endif

@inline(__always)
private func openNullDevice() -> CInt {
#if os(Windows)
    var fd: CInt = -1
    let result = nullDeviceName.withCString { ptr in
        _sopen_s(&fd, ptr, _O_WRONLY, _SH_DENYNO, 0)
    }
    if result != 0 {
        return -1
    }
    return fd
#else
    return open(nullDeviceName, O_WRONLY)
#endif
}

@inline(__always)
private func closeDescriptor(_ fd: CInt) {
#if os(Windows)
    _ = _close(fd)
#else
    _ = close(fd)
#endif
}

@inline(__always)
private func rawWrite(descriptor: CInt, pointer: UnsafePointer<UInt8>?, count: Int) -> Int {
#if os(Windows)
    return Int(_write(descriptor, pointer, CUnsignedInt(count)))
#else
    return write(descriptor, pointer, count)
#endif
}

func runStandalone() {
    func assertFun(
        condition: @autoclosure () -> Bool,
        string: @autoclosure () -> String,
        file: StaticString,
        line: UInt
    ) {
        if !condition() {
            fatalError(string(), file: (file), line: line)
        }
    }
    do {
        try runSystemCallWrapperPerformanceTest(testAssertFunction: assertFun, debugModeAllowed: false)
    } catch let e {
        fatalError("Error thrown: \(e)")
    }
}

func runSystemCallWrapperPerformanceTest(
    testAssertFunction: (@autoclosure () -> Bool, @autoclosure () -> String, StaticString, UInt) -> Void,
    debugModeAllowed: Bool
) throws {
    let fd = openNullDevice()
    precondition(fd >= 0, "couldn't open \(nullDeviceName) (\(NIOPosix.errno))")
    defer {
        closeDescriptor(fd)
    }

    let isDebugMode = _isDebugAssertConfiguration()
    if !debugModeAllowed && isDebugMode {
        fatalError("running in debug mode, release mode required")
    }

    let iterations = isDebugMode ? 100_000 : 1_000_000
    let pointer = UnsafePointer<UInt8>(bitPattern: 0xdeadbee)!

    let directCallTime = try measureRunTime { () -> Int in
        // imitate what the system call wrappers do to have a fair comparison
        var preventCompilerOptimisation: Int = 0
        for _ in 0..<iterations {
            while true {
                let result = rawWrite(descriptor: fd, pointer: pointer, count: 0)
                if result < 0 {
                    let saveErrno = NIOPosix.errno
                    switch saveErrno {
                    case EINTR:
                        continue
                    case EWOULDBLOCK:
                        throw TestError.wouldBlock
                    case EBADF, EFAULT:
                        fatalError()
                    default:
                        throw TestError.writeFailed
                    }
                } else {
                    preventCompilerOptimisation += result
                    break
                }
            }
        }
        return preventCompilerOptimisation
    }

    let withSystemCallWrappersTime = try measureRunTime { () -> Int in
        var preventCompilerOptimisation: Int = 0
        for _ in 0..<iterations {
            switch try Posix.write(descriptor: fd, pointer: pointer, size: 0) {
            case .processed(let value):
                preventCompilerOptimisation += value
            case .wouldBlock:
                throw TestError.wouldBlock
            }
        }
        return preventCompilerOptimisation
    }

    let allowedOverheadPercent: Int = isDebugMode ? 2000 : 20
    if allowedOverheadPercent > 100 {
        precondition(isDebugMode)
        print(
            "WARNING: Syscall wrapper test: Over 100% overhead allowed. Running in debug assert configuration which allows \(allowedOverheadPercent)% overhead :(. Consider running in Release mode."
        )
    }
    testAssertFunction(
        directCallTime * (1.0 + Double(allowedOverheadPercent) / 100) > withSystemCallWrappersTime,
        "Posix wrapper adds more than \(allowedOverheadPercent)% overhead (with wrapper: \(withSystemCallWrappersTime), without: \(directCallTime))",
        #filePath,
        #line
    )
}
