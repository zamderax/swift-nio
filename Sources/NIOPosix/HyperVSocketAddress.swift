//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2024 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if os(Windows)

import NIOCore
import WinSDK

/// Represents an address for a Hyper-V socket endpoint.
///
/// Hyper-V sockets address peers using a pair of GUIDs: the virtual machine identifier (`VmId`)
/// and the service identifier (`ServiceId`). The Hyper-V loopback transport can be reached using
/// the `HV_GUID_LOOPBACK` VmId.
@usableFromInline
struct HyperVRawSocketAddress {
    var Family: ADDRESS_FAMILY
    var VmId: GUID
    var ServiceId: GUID

    @usableFromInline
    init(Family: ADDRESS_FAMILY, VmId: GUID, ServiceId: GUID) {
        self.Family = Family
        self.VmId = VmId
        self.ServiceId = ServiceId
    }
}

@usableFromInline
let hyperVAddressFamilyValue: ADDRESS_FAMILY = ADDRESS_FAMILY(34)
@usableFromInline
let hyperVProtocolFamilyValue: CInt = 34

@usableFromInline
func makeGUID(
    _ data1: UInt32,
    _ data2: UInt16,
    _ data3: UInt16,
    _ b0: UInt8,
    _ b1: UInt8,
    _ b2: UInt8,
    _ b3: UInt8,
    _ b4: UInt8,
    _ b5: UInt8,
    _ b6: UInt8,
    _ b7: UInt8
) -> GUID {
    GUID(
        Data1: data1,
        Data2: data2,
        Data3: data3,
        Data4: (b0, b1, b2, b3, b4, b5, b6, b7)
    )
}

public struct HyperVSocketAddress: Sendable {
    public var vmId: GUID
    public var serviceId: GUID

    public init(vmId: GUID, serviceId: GUID) {
        self.vmId = vmId
        self.serviceId = serviceId
    }

    /// Executes `body` with a pointer to a `sockaddr` representation of this address.
    @inlinable
    public func withSockAddr<T>(
        _ body: (UnsafePointer<sockaddr>, Int) throws -> T
    ) rethrows -> T {
        var address = HyperVRawSocketAddress(
            Family: hyperVAddressFamilyValue,
            VmId: self.vmId,
            ServiceId: self.serviceId
        )

        return try withUnsafePointer(to: &address) { hvPointer in
            try hvPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                try body(sockaddrPointer, MemoryLayout<HyperVRawSocketAddress>.size)
            }
        }
    }
}

extension HyperVSocketAddress {
    private static func guidEquals(_ lhs: GUID, _ rhs: GUID) -> Bool {
        withUnsafeBytes(of: lhs) { lhsBytes in
            withUnsafeBytes(of: rhs) { rhsBytes in
                lhsBytes.elementsEqual(rhsBytes)
            }
        }
    }

    private static func hashGuid(_ guid: GUID, into hasher: inout Hasher) {
        withUnsafeBytes(of: guid) { buffer in
            for byte in buffer {
                hasher.combine(byte)
            }
        }
    }
}

extension HyperVSocketAddress: Equatable {
    public static func == (lhs: HyperVSocketAddress, rhs: HyperVSocketAddress) -> Bool {
        Self.guidEquals(lhs.vmId, rhs.vmId) && Self.guidEquals(lhs.serviceId, rhs.serviceId)
    }
}

extension HyperVSocketAddress: Hashable {
    public func hash(into hasher: inout Hasher) {
        Self.hashGuid(self.vmId, into: &hasher)
        Self.hashGuid(self.serviceId, into: &hasher)
    }
}

extension HyperVSocketAddress {
    /// Common Hyper-V VmIds.
    public enum VmId {
        /// Hyper-V loopback transport.
        public static var loopback: GUID {
            makeGUID(0xe0e16197, 0xdd56, 0x4a10, 0x91, 0x95, 0x5e, 0xe7, 0xa1, 0x55, 0xa8, 0x38)
        }

        /// Hyper-V wildcard transport.
        public static var wildcard: GUID {
            makeGUID(0x00000000, 0x0000, 0x0000, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00)
        }

        /// Hyper-V parent partition transport.
        public static var parent: GUID {
            makeGUID(0xa42e7cda, 0xd03f, 0x480c, 0x9c, 0xc2, 0xa4, 0xde, 0x20, 0xab, 0xb8, 0x78)
        }
    }

    /// Generates a fresh GUID suitable for use as a service identifier.
    ///
    /// - Returns: A newly generated GUID.
    /// - Throws: An `IOError` if `CoCreateGuid` fails.
    public static func generateServiceIdentifier() throws -> GUID {
        var guid = GUID()
        let hr = CoCreateGuid(&guid)
        guard hr == S_OK else {
            throw IOError(windows: DWORD(bitPattern: hr), reason: "CoCreateGuid")
        }
        return guid
    }
}

extension NIOBSDSocket.AddressFamily {
    /// Address family for Hyper-V sockets.
    public static var hyperV: NIOBSDSocket.AddressFamily {
        NIOBSDSocket.AddressFamily(rawValue: hyperVProtocolFamilyValue)
    }
}

extension NIOBSDSocket.ProtocolFamily {
    /// Protocol family for Hyper-V sockets.
    public static var hyperV: NIOBSDSocket.ProtocolFamily {
        NIOBSDSocket.ProtocolFamily(rawValue: hyperVProtocolFamilyValue)
    }
}

extension BaseSocket {
    func bind(to address: HyperVSocketAddress) throws {
        try self.withUnsafeHandle { fd in
            try address.withSockAddr {
                try NIOBSDSocket.bind(socket: fd, address: $0, address_len: socklen_t($1))
            }
        }
    }
}

extension Socket {
    func connect(to address: HyperVSocketAddress) throws -> Bool {
        try self.withUnsafeHandle { fd in
            try address.withSockAddr { ptr, size in
                try NIOBSDSocket.connect(socket: fd, address: ptr, address_len: socklen_t(size))
            }
        }
    }
}

public enum HyperVSocketChannelEvents: Sendable {
    public struct BindToAddress: Hashable, Sendable {
        public var address: HyperVSocketAddress

        public init(_ address: HyperVSocketAddress) {
            self.address = address
        }
    }

    public struct ConnectToAddress: Hashable, Sendable {
        public var address: HyperVSocketAddress

        public init(_ address: HyperVSocketAddress) {
            self.address = address
        }
    }
}

#endif // os(Windows)
