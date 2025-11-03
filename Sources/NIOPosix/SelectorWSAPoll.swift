//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2025 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if os(Windows)
import CNIOWindows
import NIOConcurrencyHelpers
import NIOCore
import WinSDK

@usableFromInline
let invalidSocketHandle: NIOBSDSocket.Handle = ~NIOBSDSocket.Handle(0)

extension SelectorEventSet {
    // Use this property to create pollfd's event field. Reset and errors are (hopefully) always included.
    // According to the docs we don't need to listen for them explicitly.
    // Source: https://learn.microsoft.com/en-us/windows/win32/api/winsock2/ns-winsock2-wsapollfd
    var wsaPollEvent: Int16 {
        var result: Int16 = 0
        if self.contains(.read) {
            result |= Int16(WinSDK.POLLRDNORM)
        }
        if self.contains(.write) || self.contains(.writeEOF) {
            result |= Int16(WinSDK.POLLWRNORM)
        }
        return result
    }

    // Use this initializer to create a EventSet from the wsa pollfd's revent field
    @usableFromInline
    init(revents: Int16) {
        // Event Constant   Meaning	                What to do (Typical Socket API)
        // POLLRDNORM       Normal data readable    Use recv, WSARecv, or ReadFile
        // POLLRDBAND       Priority data readable  Use recv, WSARecv (with MSG_OOB for out-of-band)
        // POLLWRNORM       Normal data writable    Use send, WSASend, or WriteFile
        // POLLWRBAND       Priority data writable  Use send (with MSG_OOB for out-of-band data)
        // POLLERR          Error condition         Use getsockopt with SO_ERROR; may need closesocket
        // POLLHUP          Closed                  Usually just cleanup: closesocket
        // POLLNVAL         Invalid fd (not open)   Fix your code; close and remove fd
        self.rawValue = 0
        let mapped = Int32(revents)
        if mapped & WinSDK.POLLRDNORM != 0 {
            self.formUnion(.read)
        }
        if mapped & WinSDK.POLLWRNORM != 0 {
            self.formUnion(.write)
        }
        if mapped & WinSDK.POLLERR != 0 {
            self.formUnion(.error)
        }
        if mapped & WinSDK.POLLHUP != 0 {
            self.formUnion(.reset)
        }
        if mapped & WinSDK.POLLNVAL != 0 {
            preconditionFailure("Invalid fd supplied.")
        }
    }
}

extension Selector: _SelectorBackendProtocol {

    func initialiseState0() throws {
        self.pollFDs.reserveCapacity(16)
        self.pollFDIndices.reserveCapacity(16)
        let (readSocket, writeSocket) = try NIOPipeBootstrap.makePipeDescriptorPair()
        do {
            try NIOBSDSocket.setNonBlocking(socket: readSocket)
            try NIOBSDSocket.setNonBlocking(socket: writeSocket)
        } catch {
            _ = try? NIOBSDSocket.close(socket: readSocket)
            _ = try? NIOBSDSocket.close(socket: writeSocket)
            throw error
        }

        self.wakeupReadFD = readSocket
        self.wakeupWriteFD = writeSocket

        let wakeupKey: UInt64 = numericCast(readSocket)
        let poll = pollfd(fd: wakeupKey, events: Int16(WinSDK.POLLRDNORM), revents: 0)
        self.pollFDs.append(poll)
        self.pollFDIndices[wakeupKey] = self.pollFDs.count - 1
        self.lifecycleState = .open
    }

    func deinitAssertions0() {
        assert(self.wakeupReadFD == invalidSocketHandle, "leaking wakeup read socket")
        assert(self.wakeupWriteFD == invalidSocketHandle, "leaking wakeup write socket")
    }

    @inlinable
    func whenReady0(
        strategy: SelectorStrategy,
        onLoopBegin loopStart: () -> Void,
        _ body: (SelectorEvent<R>) throws -> Void
    ) throws {
        assert(self.myThread.isCurrentSlow)
        guard self.lifecycleState == .open else {
            throw IOError(errnoCode: WinSDK.EBADF, reason: "can't call whenReady for selector as it's \(self.lifecycleState).")
        }

        let timeout: Int32 =
            switch strategy {
            case .now:
                0
            case .block:
                -1
            case .blockUntilTimeout(let timeAmount):
                Int32(clamping: timeAmount.nanoseconds / 1_000_000)
            }

        let result = self.pollFDs.withUnsafeMutableBufferPointer { ptr in
            WSAPoll(ptr.baseAddress!, UInt32(ptr.count), timeout)
        }

        if result == WinSDK.SOCKET_ERROR {
            throw IOError(winsock: WSAGetLastError(), reason: "WSAPoll")
        }

        loopStart()

        if result == 0 {
            return
        }

        let wakeupKey: UInt64? = self.wakeupReadFD == invalidSocketHandle ? nil : UInt64(self.wakeupReadFD)

        for index in self.pollFDs.indices {
            let pollFD = self.pollFDs[index]
            guard pollFD.revents != 0 else {
                continue
            }
            self.pollFDs[index].revents = 0

            if let wakeupKey, pollFD.fd == wakeupKey {
                self.drainWakeupSocket()
                continue
            }

            guard let registration = self.registrations[Int(pollFD.fd)] else {
                continue
            }

            var selectorEvent = SelectorEventSet(revents: pollFD.revents)
            selectorEvent = selectorEvent.intersection(registration.interested)

            guard selectorEvent != ._none else {
                continue
            }

            try body(SelectorEvent(io: selectorEvent, registration: registration))
        }
    }

    func register0(
        selectableFD: NIOBSDSocket.Handle,
        fileDescriptor: NIOBSDSocket.Handle,
        interested: SelectorEventSet,
        registrationID: SelectorRegistrationID
    ) throws {
        let fdKey: UInt64 = numericCast(fileDescriptor)
        assert(self.pollFDIndices[fdKey] == nil, "File descriptor \(fileDescriptor) registered twice")

        let poll = pollfd(fd: fdKey, events: interested.wsaPollEvent, revents: 0)
        self.pollFDs.append(poll)
        self.pollFDIndices[fdKey] = self.pollFDs.count - 1
    }

    func reregister0(
        selectableFD: NIOBSDSocket.Handle,
        fileDescriptor: NIOBSDSocket.Handle,
        oldInterested: SelectorEventSet,
        newInterested: SelectorEventSet,
        registrationID: SelectorRegistrationID
    ) throws {
        let fdKey: UInt64 = numericCast(fileDescriptor)
        guard let index = self.pollFDIndices[fdKey] else {
            assert(
                self.lifecycleState != .open,
                "Attempted to reregister unknown descriptor \(fileDescriptor)"
            )
            return
        }

        self.pollFDs[index].events = newInterested.wsaPollEvent
    }

    func deregister0(
        selectableFD: NIOBSDSocket.Handle,
        fileDescriptor: NIOBSDSocket.Handle,
        oldInterested: SelectorEventSet,
        registrationID: SelectorRegistrationID
    ) throws {
        let fdKey: UInt64 = numericCast(fileDescriptor)
        guard let index = self.pollFDIndices.removeValue(forKey: fdKey) else {
            return
        }

        let lastIndex = self.pollFDs.count - 1
        if index != lastIndex {
            self.pollFDs.swapAt(index, lastIndex)
            let movedFDKey: UInt64 = numericCast(self.pollFDs[index].fd)
            self.pollFDIndices[movedFDKey] = index
        }

        self.pollFDs.removeLast()
    }

    @usableFromInline
    @inline(__always)
    func drainWakeupSocket() {
        guard self.wakeupReadFD != invalidSocketHandle else {
            return
        }

        var scratch = [UInt8](repeating: 0, count: 64)
        while true {
            let ioResult: IOResult<size_t>
            do {
                ioResult = try scratch.withUnsafeMutableBytes { ptr -> IOResult<size_t> in
                    guard let baseAddress = ptr.baseAddress else {
                        return .processed(0)
                    }
                    return try NIOBSDSocket.recv(
                        socket: self.wakeupReadFD,
                        buffer: baseAddress,
                        length: ptr.count
                    )
                }
            } catch let error as IOError where error.winsockCode == WinSDK.WSAEWOULDBLOCK {
                break
            } catch {
                break
            }

            switch ioResult {
            case .processed(let count):
                if count == 0 || count < scratch.count {
                    return
                }
            case .wouldBlock:
                return
            }
        }
    }

    func wakeup0() throws {
        if self.myThread.isCurrentSlow {
            return
        }
        try self.externalSelectorFDLock.withLock {
            guard self.lifecycleState == .open else {
                throw EventLoopError.shutdown
            }

            let writeFD = self.wakeupWriteFD
            guard writeFD != invalidSocketHandle else {
                throw EventLoopError.shutdown
            }

            var byte: UInt8 = 1
            let sent = withUnsafePointer(to: &byte) { pointer -> CInt in
                pointer.withMemoryRebound(to: CChar.self, capacity: 1) { charPointer in
                    WinSDK.send(writeFD, charPointer, 1, 0)
                }
            }

            if sent == WinSDK.SOCKET_ERROR {
                let error = WSAGetLastError()
                switch error {
                case WinSDK.WSAEWOULDBLOCK:
                    // There's already a byte pending; that's enough to wake the selector.
                    return
                case WinSDK.WSAENOTSOCK:
                    throw EventLoopError.shutdown
                default:
                    throw IOError(winsock: error, reason: "wakeup send")
                }
            }
        }
    }

    func close0() throws {
        if self.wakeupReadFD != invalidSocketHandle {
            let handle = self.wakeupReadFD
            self.wakeupReadFD = invalidSocketHandle
            _ = try? NIOBSDSocket.close(socket: handle)
        }
        if self.wakeupWriteFD != invalidSocketHandle {
            let handle = self.wakeupWriteFD
            self.wakeupWriteFD = invalidSocketHandle
            _ = try? NIOBSDSocket.close(socket: handle)
        }
        self.pollFDs.removeAll(keepingCapacity: false)
        self.pollFDIndices.removeAll(keepingCapacity: false)
    }
}

#endif
