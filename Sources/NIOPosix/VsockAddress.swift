//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2023 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore

#if canImport(Darwin)
import CNIODarwin
#elseif os(Linux) || os(Android)
#if canImport(Glibc)
@preconcurrency import Glibc
#elseif canImport(Musl)
@preconcurrency import Musl
#endif
import CNIOLinux
#elseif os(Windows)
import WinSDK
#endif
let vsockUnimplemented = "VSOCK support is not implemented for this platform"

#if os(Windows)
@usableFromInline
let swiftNIOVsockContextNamespaceData2: UInt16 = 0x534E // "SN"
@usableFromInline
let swiftNIOVsockContextNamespaceData3: UInt16 = 0x5601
@usableFromInline
let swiftNIOVsockContextNamespaceData4: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
    (0x56, 0x53, 0x43, 0x54, 0x49, 0x44, 0x21, 0x31) // "VSCTID!1"

@usableFromInline
let swiftNIOVsockServiceNamespaceData2: UInt16 = 0x534E // "SN"
@usableFromInline
let swiftNIOVsockServiceNamespaceData3: UInt16 = 0x5602
@usableFromInline
let swiftNIOVsockServiceNamespaceData4: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
    (0x56, 0x53, 0x50, 0x4F, 0x52, 0x54, 0x21, 0x31) // "VSPORT!1"

@usableFromInline
func swiftNIOVsockGuidEquals(_ lhs: GUID, _ rhs: GUID) -> Bool {
    withUnsafeBytes(of: lhs) { lhsBytes in
        withUnsafeBytes(of: rhs) { rhsBytes in
            lhsBytes.elementsEqual(rhsBytes)
        }
    }
}

@usableFromInline
func swiftNIOVsockMakeNamespaceGUID(
    value: UInt32,
    data2: UInt16,
    data3: UInt16,
    data4: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
) -> GUID {
    GUID(
        Data1: value,
        Data2: data2,
        Data3: data3,
        Data4: data4
    )
}

@usableFromInline
func swiftNIOVsockDecodeNamespaceGUID(
    _ guid: GUID,
    expectedData2: UInt16,
    expectedData3: UInt16,
    expectedData4: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
) -> UInt32? {
    guard guid.Data2 == expectedData2,
          guid.Data3 == expectedData3 else {
        return nil
    }
    var expected = expectedData4
    let matches = withUnsafeBytes(of: guid.Data4) { guidBytes in
        withUnsafeBytes(of: &expected) { expectedBytes in
            guidBytes.elementsEqual(expectedBytes)
        }
    }
    guard matches else {
        return nil
    }
    return guid.Data1
}

@usableFromInline
func swiftNIOVsockHashGUID(_ guid: GUID) -> UInt32 {
    withUnsafeBytes(of: guid) { bytes -> UInt32 in
        var hash: UInt32 = 2_166_136_261 // FNV-1a offset basis
        for byte in bytes {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return hash
    }
}

@usableFromInline
let swiftNIOVsockGuidNull = GUID()
#endif

// MARK: - Public API that's available on all platforms.

/// A vsock socket address.
///
/// A socket address is defined as a combination of a Context Identifier (CID) and a port number.
/// The CID identifies the source or destination, which is either a virtual machine or the host.
/// The port number differentiates between multiple services running on a single machine.
///
/// For well-known CID values and port numbers, see ``VsockAddress/ContextID`` and ``VsockAddress/Port-swift.struct``.
public struct VsockAddress: Hashable, Sendable {
    /// The context ID associated with the address.
    public var cid: ContextID

    /// The port associated with the address.
    public var port: Port

    /// Creates a new vsock address.
    ///
    /// - Parameters:
    ///   - cid: the context ID.
    ///   - port: the target port.
    public init(cid: ContextID, port: Port) {
        self.cid = cid
        self.port = port
    }

    /// A vsock Context Identifier (CID).
    ///
    /// The CID identifies the source or destination, which is either a virtual machine or the host.
    public struct ContextID: RawRepresentable, ExpressibleByIntegerLiteral, Hashable, Sendable {
        public var rawValue: UInt32

        @inlinable
        public init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        @inlinable
        public init(integerLiteral value: UInt32) {
            self.init(rawValue: value)
        }

        @inlinable
        public init(_ value: Int) {
            self.init(rawValue: UInt32(bitPattern: Int32(truncatingIfNeeded: value)))
        }

        /// Wildcard, matches any address.
        ///
        /// On all platforms, using this value with `bind(2)` means "any address".
        ///
        /// On Darwin platforms, the man page states this can be used with `connect(2)` to mean "this host".
        ///
        /// This is equal to `VMADDR_CID_ANY (-1U)`.
        @inlinable
        public static var any: Self { Self(rawValue: UInt32(bitPattern: -1)) }

        /// The address of the hypervisor.
        ///
        /// This is equal to `VMADDR_CID_HYPERVISOR (0)`.
        @inlinable
        public static var hypervisor: Self { Self(rawValue: 0) }

        /// The address of the host.
        ///
        /// This is equal to `VMADDR_CID_HOST (2)`.
        @inlinable
        public static var host: Self { Self(rawValue: 2) }

        /// The address for local communication (loopback).
        ///
        /// This directs packets to the same host that generated them.  This is useful for testing
        /// applications on a single host and for debugging.
        ///
        /// The local context ID obtained with `getLocalContextID(_:)` can be used for the same
        /// purpose, but it is preferable to use `local`.
        ///
        /// This is equal to `VMADDR_CID_LOCAL (1)` on platforms that define it.
        ///
        /// - Warning: `VMADDR_CID_LOCAL (1)` is available from Linux 5.6. Its use is unsupported on
        /// other platforms.
        ///
        /// - SeeAlso: https://man7.org/linux/man-pages/man7/vsock.7.html
        @inlinable
        public static var local: Self { Self(rawValue: 1) }

    }

    /// A vsock port number.
    ///
    /// The vsock port number differentiates between multiple services running on a single machine.
    public struct Port: RawRepresentable, ExpressibleByIntegerLiteral, Hashable, Sendable {
        public var rawValue: UInt32

        @inlinable
        public init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        @inlinable
        public init(integerLiteral value: UInt32) {
            self.init(rawValue: value)
        }

        @inlinable
        public init(_ value: Int) {
            self.init(rawValue: UInt32(bitPattern: Int32(truncatingIfNeeded: value)))
        }

        /// Used to bind to any port number.
        ///
        /// This is equal to `VMADDR_PORT_ANY (-1U)`.
        @inlinable
        public static var any: Self { Self(rawValue: UInt32(bitPattern: -1)) }
    }
}

extension VsockAddress.ContextID: CustomStringConvertible {
    public var description: String {
        self == .any ? "-1" : self.rawValue.description
    }
}

extension VsockAddress.Port: CustomStringConvertible {
    public var description: String {
        self == .any ? "-1" : self.rawValue.description
    }
}

extension VsockAddress: CustomStringConvertible {
    public var description: String {
        "[VSOCK]\(self.cid):\(self.port)"
    }
}

extension ChannelOptions {
    /// - seealso: `LocalVsockContextID`
    public static let localVsockContextID = Types.LocalVsockContextID()
}

extension ChannelOption where Self == ChannelOptions.Types.LocalVsockContextID {
    public static var localVsockContextID: Self { .init() }
}

extension ChannelOptions.Types {
    /// This get-only option is used on channels backed by vsock sockets to get the local VSOCK context ID.
    public struct LocalVsockContextID: ChannelOption, Sendable {
        public typealias Value = VsockAddress.ContextID
        public init() {}
    }
}

// MARK: - Public API that might throw runtime error if not implemented on the platform.

extension NIOBSDSocket.AddressFamily {
    /// Address for vsock.
    public static var vsock: NIOBSDSocket.AddressFamily {
        #if os(Windows)
        NIOBSDSocket.AddressFamily.hyperV
        #elseif canImport(Darwin) || os(Linux) || os(Android)
        NIOBSDSocket.AddressFamily(rawValue: AF_VSOCK)
        #else
        fatalError(vsockUnimplemented)
        #endif
    }
}

extension NIOBSDSocket.ProtocolFamily {
    /// Address for vsock.
    public static var vsock: NIOBSDSocket.ProtocolFamily {
        #if os(Windows)
        NIOBSDSocket.ProtocolFamily.hyperV
        #elseif canImport(Darwin) || os(Linux) || os(Android)
        NIOBSDSocket.ProtocolFamily(rawValue: PF_VSOCK)
        #else
        fatalError(vsockUnimplemented)
        #endif
    }
}

extension VsockAddress {
    public func withSockAddr<T>(_ body: (UnsafePointer<sockaddr>, Int) throws -> T) rethrows -> T {
        #if os(Windows)
        return try self.makeHyperVSocketAddress().withSockAddr(body)
        #elseif canImport(Darwin) || os(Linux) || os(Android)
        return try self.address.withSockAddr({ try body($0, $1) })
        #else
        fatalError(vsockUnimplemented)
        #endif
    }
}

// MARK: - Internal functions that are only available on supported platforms.

#if canImport(Darwin) || os(Linux) || os(Android)
extension VsockAddress.ContextID {
    /// Get the context ID of the local machine.
    ///
    /// - Parameters:
    ///   - socketFD: the file descriptor for the open socket.
    ///
    /// This function wraps the `IOCTL_VM_SOCKETS_GET_LOCAL_CID` `ioctl()` request.
    ///
    /// To provide a consistent API on Linux and Darwin, this API takes a socket parameter, which is unused on Linux:
    ///
    /// - On Darwin, the `ioctl()` request operates on a socket.
    /// - On Linux, the `ioctl()` request operates on the `/dev/vsock` device.
    ///
    /// - Note: The semantics of this `ioctl` vary between vsock transports on Linux; ``local`` may be more suitable.
    static func getLocalContextID(_ socketFD: NIOBSDSocket.Handle) throws -> Self {
        #if canImport(Darwin)
        let request = CNIODarwin_IOCTL_VM_SOCKETS_GET_LOCAL_CID
        let fd = socketFD
        #elseif os(Linux) || os(Android)
        let request = CNIOLinux_IOCTL_VM_SOCKETS_GET_LOCAL_CID
        let fd = try Posix.open(file: "/dev/vsock", oFlag: O_RDONLY | O_CLOEXEC)
        defer { try! Posix.close(descriptor: fd) }
        #endif
        var cid = Self.any.rawValue
        try Posix.ioctl(fd: fd, request: request, ptr: &cid)
        return Self(rawValue: cid)
    }
}

extension sockaddr_vm {
    func withSockAddr<R>(_ body: (UnsafePointer<sockaddr>, Int) throws -> R) rethrows -> R {
        try withUnsafeBytes(of: self) { p in
            try body(p.baseAddress!.assumingMemoryBound(to: sockaddr.self), p.count)
        }
    }
}

extension VsockAddress {
    /// The libc socket address for a vsock socket.
    var address: sockaddr_vm {
        var addr = sockaddr_vm()
        addr.svm_family = sa_family_t(NIOBSDSocket.AddressFamily.vsock.rawValue)
        addr.svm_cid = self.cid.rawValue
        addr.svm_port = self.port.rawValue
        return addr
    }
}

extension sockaddr_storage {
    /// Converts the `socketaddr_storage` to a `sockaddr_vm`.
    ///
    /// This will crash if `ss_family` != AF_VSOCK!
    func convert() -> sockaddr_vm {
        precondition(self.ss_family == NIOBSDSocket.AddressFamily.vsock.rawValue)
        return withUnsafeBytes(of: self) {
            $0.load(as: sockaddr_vm.self)
        }
    }
}

extension BaseSocket {
    func bind(to address: VsockAddress) throws {
        try self.withUnsafeHandle { fd in
            try address.withSockAddr {
                try NIOBSDSocket.bind(socket: fd, address: $0, address_len: socklen_t($1))
            }
        }
    }

    func getLocalVsockContextID() throws -> VsockAddress.ContextID {
        try self.withUnsafeHandle { fd in
            try VsockAddress.ContextID.getLocalContextID(fd)
        }
    }
}

#elseif os(Windows)

extension VsockAddress.ContextID {
    @usableFromInline
    func hyperVVmId() -> GUID {
        switch self.rawValue {
        case Self.any.rawValue:
            return HyperVSocketAddress.VmId.wildcard
        case Self.local.rawValue:
            return HyperVSocketAddress.VmId.loopback
        case Self.host.rawValue:
            return HyperVSocketAddress.VmId.parent
        default:
            return swiftNIOVsockMakeNamespaceGUID(
                value: self.rawValue,
                data2: swiftNIOVsockContextNamespaceData2,
                data3: swiftNIOVsockContextNamespaceData3,
                data4: swiftNIOVsockContextNamespaceData4
            )
        }
    }

    @usableFromInline
    static func fromHyperVVmId(_ vmId: GUID) -> Self {
        if swiftNIOVsockGuidEquals(vmId, HyperVSocketAddress.VmId.wildcard) {
            return .any
        }
        if swiftNIOVsockGuidEquals(vmId, HyperVSocketAddress.VmId.loopback) {
            return .local
        }
        if swiftNIOVsockGuidEquals(vmId, HyperVSocketAddress.VmId.parent) {
            return .host
        }
        if let decoded = swiftNIOVsockDecodeNamespaceGUID(
            vmId,
            expectedData2: swiftNIOVsockContextNamespaceData2,
            expectedData3: swiftNIOVsockContextNamespaceData3,
            expectedData4: swiftNIOVsockContextNamespaceData4
        ) {
            return Self(rawValue: decoded)
        }
        var hash = swiftNIOVsockHashGUID(vmId)
        if hash == Self.any.rawValue || hash == Self.local.rawValue || hash == Self.host.rawValue {
            hash &+= 1
        }
        return Self(rawValue: hash)
    }

    static func getLocalContextID(_ socketFD: NIOBSDSocket.Handle) throws -> Self {
        var raw = HyperVRawSocketAddress(
            Family: hyperVAddressFamilyValue,
            VmId: GUID(),
            ServiceId: GUID()
        )
        var length = socklen_t(MemoryLayout<HyperVRawSocketAddress>.size)
        try withUnsafeMutablePointer(to: &raw) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                try NIOBSDSocket.getsockname(socket: socketFD, address: sockaddrPointer, address_len: &length)
            }
        }
        guard length >= MemoryLayout<HyperVRawSocketAddress>.size else {
            throw IOError(windows: DWORD(WSAEINVAL), reason: "getsockname")
        }
        return Self.fromHyperVVmId(raw.VmId)
    }
}

extension VsockAddress.Port {
    @usableFromInline
    func hyperVServiceId() -> GUID {
        if self == .any {
            return swiftNIOVsockGuidNull
        }
        return swiftNIOVsockMakeNamespaceGUID(
            value: self.rawValue,
            data2: swiftNIOVsockServiceNamespaceData2,
            data3: swiftNIOVsockServiceNamespaceData3,
            data4: swiftNIOVsockServiceNamespaceData4
        )
    }

    @usableFromInline
    static func fromHyperVServiceId(_ serviceId: GUID) -> Self {
        if swiftNIOVsockGuidEquals(serviceId, swiftNIOVsockGuidNull) {
            return .any
        }
        if let decoded = swiftNIOVsockDecodeNamespaceGUID(
            serviceId,
            expectedData2: swiftNIOVsockServiceNamespaceData2,
            expectedData3: swiftNIOVsockServiceNamespaceData3,
            expectedData4: swiftNIOVsockServiceNamespaceData4
        ) {
            return Self(rawValue: decoded)
        }
        var hash = swiftNIOVsockHashGUID(serviceId)
        if hash == Self.any.rawValue {
            hash &+= 1
        }
        return Self(rawValue: hash)
    }
}

extension VsockAddress {
    @usableFromInline
    func makeHyperVSocketAddress() -> HyperVSocketAddress {
        HyperVSocketAddress(
            vmId: self.cid.hyperVVmId(),
            serviceId: self.port.hyperVServiceId()
        )
    }
}

extension BaseSocket {
    func bind(to address: VsockAddress) throws {
        try self.bind(to: address.makeHyperVSocketAddress())
    }

    func getLocalVsockContextID() throws -> VsockAddress.ContextID {
        try self.withUnsafeHandle { fd in
            try VsockAddress.ContextID.getLocalContextID(fd)
        }
    }
}

#endif
