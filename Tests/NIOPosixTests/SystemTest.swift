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

import NIOCore
import XCTest

#if os(Windows)
import CNIOWindows
import WinSDK
#elseif canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Bionic)
import Bionic
#endif

@testable import NIOPosix

final class SystemTest: XCTestCase {
    func testSystemCallWrapperPerformance() throws {
        try runSystemCallWrapperPerformanceTest(
            testAssertFunction: XCTAssert,
            debugModeAllowed: true
        )
    }

    func testErrorsWorkCorrectly() throws {
        try withPipe { readFD, writeFD in
            var randomBytes: UInt8 = 42
            do {
                _ = try withUnsafePointer(to: &randomBytes) { ptr in
                    try readFD.withUnsafeFileDescriptor { descriptor in
                        let socketHandle: NIOBSDSocket.Handle = numericCast(descriptor)
                        try NIOBSDSocket.setsockopt(
                            socket: socketHandle,
                            level: NIOBSDSocket.OptionLevel(rawValue: -1),
                            option_name: NIOBSDSocket.Option(rawValue: -1),
                            option_value: ptr,
                            option_len: 0
                        )
                    }
                }
                XCTFail("success even though the call was invalid")
            } catch let error as IOError {
                #if os(Windows)
                if let winsockCode = error.winsockCode {
                    let expected: Set<CInt> = [WinSDK.WSAENOTSOCK, WinSDK.WSAENOPROTOOPT]
                    XCTAssertTrue(expected.contains(winsockCode), "unexpected winsock error: \(winsockCode)")
                } else if let errnoCode = error.windowsCode {
                    XCTFail("unexpected Windows system error: \(errnoCode)")
                } else {
                    XCTFail("unexpected error domain: \(error)")
                }
                #else
                XCTAssert(
                    [ENOTSOCK, ENOPROTOOPT].contains(error.errnoCode),
                    "unexpected errno: \(error.errnoCode)"
                )
                #endif
                XCTAssert(error.description.contains("setsockopt"))
            } catch {
                XCTFail("wrong error thrown: \(error)")
            }
            return [readFD, writeFD]
        }
    }

    func testCmsgFirstHeader() throws {
        withEncodedControlMessages(sampleControlMessages) { _, header in
            withUnsafeMutablePointer(to: &header) { pointer in
                guard let first = NIOBSDSocketControlMessage.firstHeader(inside: pointer) else {
                    return XCTFail("expected first header")
                }
                XCTAssertEqual(first.pointee.cmsg_level, sampleControlMessages[0].level)
                XCTAssertEqual(first.pointee.cmsg_type, sampleControlMessages[0].type)
                guard let firstData = NIOBSDSocketControlMessage.data(for: first) else {
                    return XCTFail("missing control message payload")
                }
                XCTAssertEqual(firstData.count, MemoryLayout<CInt>.size)
                XCTAssertEqual(
                    ControlMessageParser._readCInt(data: UnsafeRawBufferPointer(firstData)),
                    sampleControlMessages[0].payload
                )
            }
        }
    }

    func testCMsgNextHeader() throws {
        withEncodedControlMessages(sampleControlMessages) { _, header in
            withUnsafeMutablePointer(to: &header) { pointer in
                guard let first = NIOBSDSocketControlMessage.firstHeader(inside: pointer) else {
                    return XCTFail("expected first header")
                }
                guard let second = NIOBSDSocketControlMessage.nextHeader(inside: pointer, after: first) else {
                    return XCTFail("expected second header")
                }
                XCTAssertEqual(second.pointee.cmsg_level, sampleControlMessages[1].level)
                XCTAssertEqual(second.pointee.cmsg_type, sampleControlMessages[1].type)
                guard let payload = NIOBSDSocketControlMessage.data(for: second) else {
                    return XCTFail("missing control message payload")
                }
                XCTAssertEqual(payload.count, MemoryLayout<CInt>.size)
                XCTAssertEqual(
                    ControlMessageParser._readCInt(data: UnsafeRawBufferPointer(payload)),
                    sampleControlMessages[1].payload
                )
                XCTAssertNil(NIOBSDSocketControlMessage.nextHeader(inside: pointer, after: second))
            }
        }
    }

    func testCMsgData() throws {
        withEncodedControlMessages(sampleControlMessages) { _, header in
            let collection = UnsafeControlMessageCollection(messageHeader: header)
            XCTAssertEqual(collection.count, sampleControlMessages.count)
            for (index, message) in collection.enumerated() {
                let expected = sampleControlMessages[index]
                XCTAssertEqual(message.level, expected.level)
                XCTAssertEqual(message.type, expected.type)
                guard let data = message.data else {
                    return XCTFail("missing payload at index \(index)")
                }
                XCTAssertEqual(data.count, MemoryLayout<CInt>.size)
                XCTAssertEqual(ControlMessageParser._readCInt(data: data), expected.payload)
            }
        }
    }

    func testCMsgCollection() throws {
        withEncodedControlMessages(sampleControlMessages) { _, header in
            let collection = UnsafeControlMessageCollection(messageHeader: header)
            XCTAssertEqual(collection.count, sampleControlMessages.count)
            var iterator = collection.makeIterator()
            XCTAssertNotNil(iterator.next())
            XCTAssertNotNil(iterator.next())
            XCTAssertNil(iterator.next())
        }
    }
}

private struct ControlMessageExample {
    var level: CInt
    var type: CInt
    var payload: CInt
}

// Simple set of control messages used across the tests.
private let sampleControlMessages: [ControlMessageExample] = [
    ControlMessageExample(level: 1, type: 2, payload: 3),
    ControlMessageExample(level: 4, type: 5, payload: 6),
]

private func makeMessageHeader(for controlBytes: UnsafeMutableRawBufferPointer) -> msghdr {
    var message = msghdr()
    message.msg_name = nil
    message.msg_namelen = 0
#if os(Windows)
    message.control_ptr = controlBytes
    message.msg_flags = 0
#else
    message.msg_control = controlBytes.baseAddress
    message.msg_controllen = .init(controlBytes.count)
    message.msg_iov = nil
    message.msg_iovlen = 0
    message.msg_flags = 0
#endif
    return message
}

private func withEncodedControlMessages<T>(
    _ messages: [ControlMessageExample],
    _ body: (_ controlBytes: UnsafeMutableRawBufferPointer, _ header: inout msghdr) -> T
) -> T {
    precondition(!messages.isEmpty)
    let bytesPerMessage = NIOBSDSocketControlMessage.space(payloadSize: MemoryLayout<CInt>.stride)
    let totalBytes = bytesPerMessage * messages.count
    let storage = UnsafeMutableRawBufferPointer.allocate(
        byteCount: totalBytes,
        alignment: MemoryLayout<cmsghdr>.alignment
    )
    storage.initializeMemory(as: UInt8.self, repeating: 0)
    defer {
        storage.deallocate()
    }

    var encoder = UnsafeOutboundControlBytes(controlBytes: storage)
    for message in messages {
        encoder.appendControlMessage(level: message.level, type: message.type, payload: message.payload)
    }

    let controlBytes = encoder.validControlBytes
    var header = makeMessageHeader(for: controlBytes)
    return body(controlBytes, &header)
}
