//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2021-2023 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
#if os(Linux) || os(FreeBSD) || os(Android)
import CNIOLinux
#if canImport(Glibc)
@preconcurrency import Glibc
#elseif canImport(Musl)
@preconcurrency import Musl
#elseif canImport(Android)
@preconcurrency import Android
#endif
#elseif os(Windows)
import ucrt
import let WinSDK.RelationProcessorCore

import let WinSDK.AF_UNSPEC
import let WinSDK.ERROR_BUFFER_OVERFLOW
import let WinSDK.ERROR_SUCCESS
import let WinSDK.AF_INET
import let WinSDK.IPPROTO_UDP
import let WinSDK.INVALID_SOCKET
import let WinSDK.SOCKET_ERROR
import let WinSDK.SOCK_DGRAM
import let WinSDK.UDP_RECV_MAX_COALESCED_SIZE
import let WinSDK.UDP_SEND_MSG_SIZE
import let WinSDK.WSAEOPNOTSUPP
import let WinSDK.WSAENOPROTOOPT

import func WinSDK.GetAdaptersAddresses
import func WinSDK.GetLastError
import func WinSDK.GetLogicalProcessorInformation
import func WinSDK.WSAGetLastError
import func WinSDK.closesocket
import func WinSDK.setsockopt
import func WinSDK.socket

import struct WinSDK.IP_ADAPTER_ADDRESSES
import struct WinSDK.IP_ADAPTER_UNICAST_ADDRESS
import struct WinSDK.SYSTEM_LOGICAL_PROCESSOR_INFORMATION
import struct WinSDK.ULONG

import typealias WinSDK.DWORD
import typealias WinSDK.SOCKET
#elseif canImport(Darwin)
import Darwin
#elseif canImport(WASILibc)
@preconcurrency import WASILibc
#else
#error("The Core utilities module was unable to identify your C library.")
#endif

/// A utility function that runs the body code only in debug builds, without
/// emitting compiler warnings.
///
/// This is currently the only way to do this in Swift: see
/// https://forums.swift.org/t/support-debug-only-code/11037 for a discussion.
@inlinable
internal func debugOnly(_ body: () -> Void) {
    // FIXME: duplicated with NIO.
    assert(
        {
            body()
            return true
        }()
    )
}

/// Allows to "box" another value.
final class Box<T> {
    // FIXME: Duplicated with NIO.
    let value: T
    init(_ value: T) { self.value = value }
}

extension Box: Sendable where T: Sendable {}

public enum System: Sendable {
    /// A utility function that returns an estimate of the number of *logical* cores
    /// on the system available for use.
    ///
    /// This value can be used to help provide an estimate of how many threads to use with
    /// the `MultiThreadedEventLoopGroup`. The exact ratio between this number and the number
    /// of threads to use is a matter for the programmer, and can be determined based on the
    /// specific execution behaviour of the program.
    ///
    /// On Linux the value returned will take account of cgroup || cpuset restrictions.
    /// The result will be rounded up to the nearest whole number where fractional CPUs have been assigned.
    ///
    /// - Returns: The logical core count on the system.
    public static var coreCount: Int {
        #if os(Windows)
        var dwLength: DWORD = 0
        _ = GetLogicalProcessorInformation(nil, &dwLength)

        let alignment: Int =
            MemoryLayout<SYSTEM_LOGICAL_PROCESSOR_INFORMATION>.alignment
        let pBuffer: UnsafeMutableRawPointer =
            UnsafeMutableRawPointer.allocate(
                byteCount: Int(dwLength),
                alignment: alignment
            )
        defer {
            pBuffer.deallocate()
        }

        let dwSLPICount: Int =
            Int(dwLength) / MemoryLayout<SYSTEM_LOGICAL_PROCESSOR_INFORMATION>.stride
        let pSLPI: UnsafeMutablePointer<SYSTEM_LOGICAL_PROCESSOR_INFORMATION> =
            pBuffer.bindMemory(
                to: SYSTEM_LOGICAL_PROCESSOR_INFORMATION.self,
                capacity: dwSLPICount
            )

        let bResult: Bool = GetLogicalProcessorInformation(pSLPI, &dwLength)
        precondition(bResult, "GetLogicalProcessorInformation: \(GetLastError())")

        return UnsafeBufferPointer<SYSTEM_LOGICAL_PROCESSOR_INFORMATION>(
            start: pSLPI,
            count: dwSLPICount
        )
        .filter { $0.Relationship == RelationProcessorCore }
        .map { $0.ProcessorMask.nonzeroBitCount }
        .reduce(0, +)
        #elseif os(Linux) || os(Android)
        if let quota2 = Linux.coreCountCgroup2Restriction() {
            return quota2
        } else if let quota = Linux.coreCountCgroup1Restriction() {
            return quota
        } else if let cpusetCount = Linux.coreCount(cpuset: Linux.cpuSetPath) {
            return cpusetCount
        } else {
            return sysconf(CInt(_SC_NPROCESSORS_ONLN))
        }
        #else
        return sysconf(CInt(_SC_NPROCESSORS_ONLN))
        #endif
    }

    #if os(Windows)
    @inline(never)
    private static func withAdapters<R>(
        _ body: (UnsafeMutablePointer<IP_ADAPTER_ADDRESSES>?) throws -> R
    ) throws -> R {
        var length: ULONG = 0
        var result = GetAdaptersAddresses(ULONG(AF_UNSPEC), 0, nil, nil, &length)
        guard result == ERROR_SUCCESS || result == ERROR_BUFFER_OVERFLOW else {
            throw IOError(windows: result, reason: "GetAdaptersAddresses")
        }

        let stride: Int = MemoryLayout<IP_ADAPTER_ADDRESSES>.stride
        var buffer: UnsafeMutableBufferPointer<IP_ADAPTER_ADDRESSES>? = nil
        defer { buffer?.deallocate() }

        repeat {
            let capacity = max(1, (Int(length) + stride - 1) / stride)
            buffer?.deallocate()
            buffer = UnsafeMutableBufferPointer.allocate(capacity: capacity)

            result = GetAdaptersAddresses(
                ULONG(AF_UNSPEC),
                0,
                nil,
                buffer!.baseAddress,
                &length
            )
        } while result == ERROR_BUFFER_OVERFLOW

        guard result == ERROR_SUCCESS else {
            throw IOError(windows: result, reason: "GetAdaptersAddresses")
        }

        return try body(buffer!.baseAddress)
    }
    #endif

    #if !os(Windows) && !os(WASI)
    /// A utility function that enumerates the available network interfaces on this machine.
    ///
    /// This function returns values that are true for a brief snapshot in time. These results can
    /// change, and the returned values will not change to reflect them. This function must be called
    /// again to get new results.
    ///
    /// - Returns: An array of network interfaces available on this machine.
    /// - Throws: If an error is encountered while enumerating interfaces.
    @available(*, deprecated, renamed: "enumerateDevices")
    public static func enumerateInterfaces() throws -> [NIONetworkInterface] {
        var interfaces: [NIONetworkInterface] = []
        interfaces.reserveCapacity(12)  // Arbitrary choice.

        var interface: UnsafeMutablePointer<ifaddrs>? = nil
        try SystemCalls.getifaddrs(&interface)
        let originalInterface = interface
        defer {
            freeifaddrs(originalInterface)
        }

        while let concreteInterface = interface {
            if let nioInterface = NIONetworkInterface(concreteInterface.pointee) {
                interfaces.append(nioInterface)
            }
            interface = concreteInterface.pointee.ifa_next
        }

        return interfaces
    }
    #elseif os(Windows)
    @available(*, deprecated, renamed: "enumerateDevices")
    public static func enumerateInterfaces() throws -> [NIONetworkInterface] {
        var interfaces: [NIONetworkInterface] = []
        interfaces.reserveCapacity(12)

        try self.withAdapters { head in
            var adapter = head
            while let currentAdapter = adapter {
                var unicast = currentAdapter.pointee.FirstUnicastAddress
                while let currentUnicast = unicast {
                    if let interface = NIONetworkInterface(currentAdapter, currentUnicast) {
                        interfaces.append(interface)
                    }
                    unicast = currentUnicast.pointee.Next
                }
                adapter = currentAdapter.pointee.Next
            }
        }

        return interfaces
    }
    #endif

    /// A utility function that enumerates the available network devices on this machine.
    ///
    /// This function returns values that are true for a brief snapshot in time. These results can
    /// change, and the returned values will not change to reflect them. This function must be called
    /// again to get new results.
    ///
    /// - Returns: An array of network devices available on this machine.
    /// - Throws: If an error is encountered while enumerating interfaces.
    public static func enumerateDevices() throws -> [NIONetworkDevice] {
        var devices: [NIONetworkDevice] = []
        devices.reserveCapacity(12)  // Arbitrary choice.

        #if os(Windows)
        try self.withAdapters { head in
            var adapter = head
            while let currentAdapter = adapter {
                var unicast = currentAdapter.pointee.FirstUnicastAddress
                while let currentUnicast = unicast {
                    if let device = NIONetworkDevice(currentAdapter, currentUnicast) {
                        devices.append(device)
                    }
                    unicast = currentUnicast.pointee.Next
                }
                adapter = currentAdapter.pointee.Next
            }
        }
        #elseif !os(WASI)
        var interface: UnsafeMutablePointer<ifaddrs>? = nil
        try SystemCalls.getifaddrs(&interface)
        let originalInterface = interface
        defer {
            freeifaddrs(originalInterface)
        }

        while let concreteInterface = interface {
            if let nioInterface = NIONetworkDevice(concreteInterface.pointee) {
                devices.append(nioInterface)
            }
            interface = concreteInterface.pointee.ifa_next
        }

        #endif
        return devices
    }
}

extension System {
    #if os(Linux)
    /// Returns true if the platform supports `UDP_SEGMENT` (GSO).
    ///
    /// The option can be enabled by setting the ``ChannelOptions/Types/DatagramSegmentSize`` channel option.
    public static let supportsUDPSegmentationOffload: Bool = CNIOLinux_supports_udp_segment()
#elseif os(Windows)
    /// Returns true if the platform supports `UDP_SEGMENT` (GSO).
    ///
    /// The option can be enabled by setting the ``ChannelOptions/Types/DatagramSegmentSize`` channel option.
    public static let supportsUDPSegmentationOffload: Bool = {
        guard let socket = Self.makeUDPSocket() else {
            return false
        }
        defer { _ = WinSDK.closesocket(socket) }

        var value: UInt32 = 1200
        let result = withUnsafeBytes(of: value) { buffer -> CInt in
            let optPtr = buffer.bindMemory(to: CChar.self).baseAddress!
            return WinSDK.setsockopt(
                socket,
                Int32(IPPROTO_UDP.rawValue),
                Int32(UDP_SEND_MSG_SIZE),
                optPtr,
                Int32(buffer.count)
            )
        }
        if result == SOCKET_ERROR {
            return false
        }

        value = 0
        _ = withUnsafeBytes(of: value) { buffer in
            let optPtr = buffer.bindMemory(to: CChar.self).baseAddress!
            WinSDK.setsockopt(
                socket,
                Int32(IPPROTO_UDP.rawValue),
                Int32(UDP_SEND_MSG_SIZE),
                optPtr,
                Int32(buffer.count)
            )
        }
        return true
    }()
#else
    /// Returns true if the platform supports `UDP_SEGMENT` (GSO).
    ///
    /// The option can be enabled by setting the ``ChannelOptions/Types/DatagramSegmentSize`` channel option.
    public static let supportsUDPSegmentationOffload: Bool = false
#endif

#if os(Linux)
    /// Returns true if the platform supports `UDP_GRO`.
    ///
    /// The option can be enabled by setting the ``ChannelOptions/Types/DatagramReceiveOffload`` channel option.
    public static let supportsUDPReceiveOffload: Bool = CNIOLinux_supports_udp_gro()
#elseif os(Windows)
    /// Returns true if the platform supports `UDP_GRO`.
    ///
    /// The option can be enabled by setting the ``ChannelOptions/Types/DatagramReceiveOffload`` channel option.
    public static let supportsUDPReceiveOffload: Bool = {
        guard let socket = Self.makeUDPSocket() else {
            return false
        }
        defer { _ = WinSDK.closesocket(socket) }

        var value: UInt32 = 65_535
        let setResult = withUnsafeBytes(of: value) { buffer -> CInt in
            let optPtr = buffer.bindMemory(to: CChar.self).baseAddress!
            return WinSDK.setsockopt(
                socket,
                Int32(IPPROTO_UDP.rawValue),
                Int32(UDP_RECV_MAX_COALESCED_SIZE),
                optPtr,
                Int32(buffer.count)
            )
        }
        if setResult == SOCKET_ERROR {
            return false
        }

        value = 0
        _ = withUnsafeBytes(of: value) { buffer in
            let optPtr = buffer.bindMemory(to: CChar.self).baseAddress!
            WinSDK.setsockopt(
                socket,
                Int32(IPPROTO_UDP.rawValue),
                Int32(UDP_RECV_MAX_COALESCED_SIZE),
                optPtr,
                Int32(buffer.count)
            )
        }
        return true
    }()
#else
    /// Returns true if the platform supports `UDP_GRO`.
    ///
    /// The option can be enabled by setting the ``ChannelOptions/Types/DatagramReceiveOffload`` channel option.
    public static let supportsUDPReceiveOffload: Bool = false
#endif

    /// Returns the UDP maximum segment count if the platform supports and defines it.
    public static var udpMaxSegments: Int? {
        #if os(Linux)
        let maxSegments = CNIOLinux_UDP_MAX_SEGMENTS
        if maxSegments != -1 {
            return maxSegments
        }
        #endif
        return nil
    }

#if os(Windows)
    private static func makeUDPSocket() -> WinSDK.SOCKET? {
        let socket = WinSDK.socket(Int32(AF_INET), Int32(SOCK_DGRAM), Int32(IPPROTO_UDP.rawValue))
        guard socket != INVALID_SOCKET else {
            return nil
        }
        return socket
    }
#endif
}

#if os(Windows)
@usableFromInline
package enum Windows {
    @usableFromInline
    package static func strerror(_ errnoCode: CInt) -> String? {
        withUnsafeTemporaryAllocation(of: CChar.self, capacity: 256) { ptr in
            if strerror_s(ptr.baseAddress, ptr.count, errnoCode) == 0 {
                return String(cString: UnsafePointer(ptr.baseAddress!))
            }
            return nil
        }
    }

    package static func getenv(_ env: String) -> String? {
        var count = 0
        var ptr: UnsafeMutablePointer<CChar>? = nil
        withUnsafeMutablePointer(to: &ptr) { buffer in
            // according to docs only EINVAL and ENOMEM are possible here.
            _ = _dupenv_s(buffer, &count, env)
        }
        defer { if let ptr { free(ptr) } }
        if count > 0, let ptr {
            let buffer = UnsafeBufferPointer(start: ptr, count: count)
            return buffer.withMemoryRebound(to: UInt8.self) {
                String(decoding: $0, as: Unicode.UTF8.self)
            }
        } else {
            return nil
        }
    }
}
#endif
