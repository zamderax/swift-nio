#if os(Windows)
import WinSDK
import NIOCore
@testable import NIOPosix

@inline(__always)
func usleep(_ usecs: UInt32) {
    let milliseconds = (usecs + 999) / 1000
    Sleep(DWORD(milliseconds))
}

@inline(__always)
func usleep(_ usecs: Int) {
    usleep(UInt32(usecs))
}

@inline(__always)
@discardableResult
func sleep(_ seconds: UInt32) -> UInt32 {
    Sleep(DWORD(seconds * 1000))
    return 0
}

@inline(__always)
@discardableResult
func sleep(_ seconds: Int) -> UInt32 {
    sleep(UInt32(seconds))
}

struct WindowsTestSocket {
    let descriptor: NIOPipeBootstrap.PipeDescriptor

    func writeBytes(_ bytes: ArraySlice<UInt8>) throws {
        var totalSent = 0
        while totalSent < bytes.count {
            let remaining = bytes.dropFirst(totalSent)
            let result: CInt = remaining.withUnsafeBytes { ptr in
                WinSDK.send(
                    self.descriptor,
                    ptr.baseAddress!.assumingMemoryBound(to: CChar.self),
                    CInt(ptr.count),
                    0
                )
            }
            if result == WinSDK.SOCKET_ERROR {
                throw IOError(winsock: WinSDK.WSAGetLastError(), reason: "send")
            }
            totalSent += Int(result)
        }
    }

    func readBytes(ofExactLength length: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: length)
        var received = 0
        while received < length {
            let result = buffer.withUnsafeMutableBytes { ptr in
                WinSDK.recv(
                    self.descriptor,
                    ptr.baseAddress!.advanced(by: received).assumingMemoryBound(to: CChar.self),
                    CInt(length - received),
                    0
                )
            }
            if result == WinSDK.SOCKET_ERROR {
                throw IOError(winsock: WinSDK.WSAGetLastError(), reason: "recv")
            }
            if result == 0 {
                throw IOError(winsock: WinSDK.WSAECONNRESET, reason: "recv")
            }
            received += Int(result)
        }
        return buffer
    }

    func close() {
        _ = WinSDK.closesocket(self.descriptor)
    }
}
#endif
