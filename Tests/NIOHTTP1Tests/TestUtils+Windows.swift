#if os(Windows)
import Foundation
import NIOCore
import XCTest
import WinSDK

@inline(__always)
private func nioHTTP1Usleep(_ usecs: UInt32) {
    let milliseconds = (usecs + 999) / 1000
    Sleep(DWORD(milliseconds))
}

func assert(
    _ condition: @autoclosure () -> Bool,
    within time: TimeAmount,
    testInterval: TimeAmount? = nil,
    _ message: String = "condition not satisfied in time",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let interval = testInterval ?? TimeAmount.nanoseconds(time.nanoseconds / 5)
    let endTime = NIODeadline.now() + time

    repeat {
        if condition() { return }
        nioHTTP1Usleep(UInt32(interval.nanoseconds / 1000))
    } while NIODeadline.now() < endTime

    if !condition() {
        XCTFail(message, file: (file), line: line)
    }
}

@discardableResult
func assertNoThrowWithValue<T>(
    _ body: @autoclosure () throws -> T,
    defaultValue: T? = nil,
    message: String? = nil,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> T {
    do {
        return try body()
    } catch {
        let prefix = message.map { "\($0): " } ?? ""
        XCTFail("\(prefix)unexpected error \(error) thrown", file: (file), line: line)
        if let defaultValue {
            return defaultValue
        } else {
            throw error
        }
    }
}

@inline(__always)
func usleep(_ usecs: UInt32) {
    nioHTTP1Usleep(usecs)
}

var temporaryDirectory: String {
    if #available(Windows 10.0, *) {
        return FileManager.default.temporaryDirectory.path
    } else {
        return NSTemporaryDirectory()
    }
}

extension Channel {
    func syncCloseAcceptingAlreadyClosed() throws {
        do {
            try self.close().wait()
        } catch ChannelError.alreadyClosed {
            // acceptable: already closed
        } catch {
            throw error
        }
    }
}
#endif
