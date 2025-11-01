#if os(Windows)

import Foundation
import SystemPackage
import WinSDK
import ucrt

/// Captures details about a Win32 failure and bridges it to `Errno`.
struct Win32Error: Error, Sendable, CustomStringConvertible {
    let function: StaticString
    let code: DWORD
    let message: String

    init(function: StaticString, code: DWORD = GetLastError()) {
        self.function = function
        self.code = code
        self.message = Win32Error.loadMessage(for: code)
    }

    var description: String {
        "\(self.function): \(self.message) (\(self.code))"
    }

    private static func loadMessage(for code: DWORD) -> String {
        var buffer = Array<WCHAR>(repeating: 0, count: 1024)
        let flags = DWORD(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS)
        let length = buffer.withUnsafeMutableBufferPointer { pointer -> DWORD in
            guard let baseAddress = pointer.baseAddress else {
                return 0
            }
            return FormatMessageW(
                flags,
                nil,
                code,
                0,
                baseAddress,
                DWORD(pointer.count),
                nil
            )
        }

        guard length != 0 else {
            return "Windows error \(code)"
        }

        return buffer.withUnsafeBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress else {
                return "Windows error \(code)"
            }
            return String(decodingCString: baseAddress, as: UTF16.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

extension FileSystemError {
    static func win32(_ error: Win32Error, path: FilePath, message: String) -> FileSystemError {
        let mappedCode: FileSystemError.Code
        switch error.code {
        case DWORD(ERROR_FILE_NOT_FOUND),
             DWORD(ERROR_PATH_NOT_FOUND),
             DWORD(ERROR_INVALID_DRIVE):
            mappedCode = .notFound
        case DWORD(ERROR_ALREADY_EXISTS),
             DWORD(ERROR_FILE_EXISTS):
            mappedCode = .alreadyExists
        case DWORD(ERROR_ACCESS_DENIED),
             DWORD(ERROR_PRIVILEGE_NOT_HELD),
             DWORD(ERROR_SHARING_VIOLATION):
            mappedCode = .permissionDenied
        case DWORD(ERROR_DIR_NOT_EMPTY):
            mappedCode = .directoryNotEmpty
        case DWORD(ERROR_NOT_SUPPORTED),
             DWORD(ERROR_INVALID_FUNCTION):
            mappedCode = .unsupported
        case DWORD(ERROR_DISK_FULL),
             DWORD(ERROR_HANDLE_DISK_FULL),
             DWORD(ERROR_WRITE_FAULT),
             DWORD(ERROR_READ_FAULT):
            mappedCode = .io
        default:
            mappedCode = .unknown
        }

        return FileSystemError(code: mappedCode, message: message, path: path, cause: error)
    }
}

enum Win32FileSystemShim {
    static func fileInfo(at path: FilePath) throws -> FileInfo {
        do {
            let attributes = try self.attributes(of: path)
            return self.makeFileInfo(path: path, attributes: attributes)
        } catch let error as Win32Error {
            throw FileSystemError.win32(
                error,
                path: path,
                message: "Unable to read attributes for '\(path)'."
            )
        }
    }

    static func exists(at path: FilePath) throws -> Bool {
        do {
            _ = try self.attributes(of: path)
            return true
        } catch let error as Win32Error {
            switch error.code {
            case DWORD(ERROR_FILE_NOT_FOUND), DWORD(ERROR_PATH_NOT_FOUND):
                return false
            default:
                throw FileSystemError.win32(
                    error,
                    path: path,
                    message: "Unable to check existence of '\(path)'."
                )
            }
        }
    }

    static func listDirectory(at path: FilePath) throws -> [DirectoryEntry] {
        do {
            let attributes = try self.attributes(of: path)
            guard attributes.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0 else {
                throw FileSystemError.unsupported(
                    "Path '\(path)' is not a directory.",
                    path: path
                )
            }

            return try self.enumerateDirectory(path)
        } catch let error as FileSystemError {
            throw error
        } catch let error as Win32Error {
            throw FileSystemError.win32(
                error,
                path: path,
                message: "Unable to list directory '\(path)'."
            )
        }
    }

    static func createDirectory(
        at path: FilePath,
        withIntermediateDirectories: Bool
    ) throws {
        do {
            if withIntermediateDirectories {
                let result: Int32 = try self.withWidePath(path) { widePointer in
                    SHCreateDirectoryExW(nil, widePointer, nil)
                }

                switch result {
                case Int32(ERROR_SUCCESS), Int32(ERROR_ALREADY_EXISTS):
                    return
                case Int32(ERROR_FILE_EXISTS):
                    throw FileSystemError(
                        code: .alreadyExists,
                        message: "A file already exists at '\(path)'.",
                        path: path
                    )
                default:
                    throw Win32Error(function: #function, code: DWORD(UInt32(bitPattern: result)))
                }
            } else {
                let created: Bool = try self.withWidePath(path) { widePointer in
                    CreateDirectoryW(widePointer, nil)
                }

                if !created {
                    let error = Win32Error(function: #function)
                    if error.code == DWORD(ERROR_ALREADY_EXISTS) {
                        return
                    }

                    if error.code == DWORD(ERROR_FILE_EXISTS) {
                        throw FileSystemError(
                            code: .alreadyExists,
                            message: "A file already exists at '\(path)'.",
                            path: path
                        )
                    }

                    throw error
                }
            }
        } catch let error as FileSystemError {
            throw error
        } catch let error as Win32Error {
            throw FileSystemError.win32(
                error,
                path: path,
                message: "Unable to create directory '\(path)'."
            )
        }
    }

    static func removeItem(at path: FilePath, recursively: Bool) throws {
        do {
            let attributes = try self.attributes(of: path)
            let isDirectory = attributes.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0
            let isReparsePoint = attributes.dwFileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) != 0

            if isDirectory {
                if !isReparsePoint {
                    if recursively {
                        let entries = try self.enumerateDirectory(path)
                        for entry in entries {
                            try self.removeItem(at: entry.path, recursively: true)
                        }
                    } else {
                        let entries = try self.enumerateDirectory(path)
                        guard entries.isEmpty else {
                            throw FileSystemError(
                                code: .directoryNotEmpty,
                                message: "Directory '\(path)' is not empty.",
                                path: path
                            )
                        }
                    }
                }

                let removed: Bool = try self.withWidePath(path) { widePointer in
                    RemoveDirectoryW(widePointer)
                }

                if !removed {
                    throw Win32Error(function: #function)
                }
            } else {
                let deleted: Bool = try self.withWidePath(path) { widePointer in
                    DeleteFileW(widePointer)
                }

                if !deleted {
                    let error = Win32Error(function: #function)
                    // If the file is gone already we treat as success.
                    if error.code == DWORD(ERROR_FILE_NOT_FOUND) || error.code == DWORD(ERROR_PATH_NOT_FOUND) {
                        return
                    }
                    throw error
                }
            }
        } catch let error as FileSystemError {
            throw error
        } catch let error as Win32Error {
            if error.code == DWORD(ERROR_FILE_NOT_FOUND) || error.code == DWORD(ERROR_PATH_NOT_FOUND) {
                return
            }

            throw FileSystemError.win32(
                error,
                path: path,
                message: "Unable to remove '\(path)'."
            )
        }
    }

    static func moveItem(from source: FilePath, to destination: FilePath) throws {
        if (try? self.exists(at: destination)) == true {
            throw FileSystemError(
                code: .alreadyExists,
                message: "Destination '\(destination)' already exists.",
                path: destination
            )
        }

        do {
            let moved: Bool = try self.withWidePathPair(source, destination) { sourcePointer, destinationPointer in
                MoveFileExW(
                    sourcePointer,
                    destinationPointer,
                    DWORD(MOVEFILE_COPY_ALLOWED)
                )
            }

            if !moved {
                throw Win32Error(function: #function)
            }
        } catch let error as FileSystemError {
            throw error
        } catch let error as Win32Error {
            throw FileSystemError.win32(
                error,
                path: source,
                message: "Unable to move '\(source)' to '\(destination)'."
            )
        }
    }

    static func copyItem(from source: FilePath, to destination: FilePath) throws {
        if (try? self.exists(at: destination)) == true {
            throw FileSystemError(
                code: .alreadyExists,
                message: "Destination '\(destination)' already exists.",
                path: destination
            )
        }

        do {
            let attributes = try self.attributes(of: source)
            let isDirectory = attributes.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0
            let isReparsePoint = attributes.dwFileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) != 0

            if isDirectory, !isReparsePoint {
                try self.createDirectory(at: destination, withIntermediateDirectories: false)
                let entries = try self.enumerateDirectory(source)
                for entry in entries {
                    try self.copyItem(
                        from: entry.path,
                        to: destination.appending(entry.name)
                    )
                }
            } else {
                let copied: Bool = try self.withWidePathPair(source, destination) { sourcePointer, destinationPointer in
                    CopyFileW(
                        sourcePointer,
                        destinationPointer,
                        true /* fail if exists */
                    )
                }

                if !copied {
                    throw Win32Error(function: #function)
                }
            }
        } catch let error as FileSystemError {
            throw error
        } catch let error as Win32Error {
            throw FileSystemError.win32(
                error,
                path: source,
                message: "Unable to copy '\(source)' to '\(destination)'."
            )
        }
    }

    static func readFile(at path: FilePath) throws -> Data {
        do {
            let handle = try self.openFileHandle(
                at: path,
                access: DWORD(GENERIC_READ),
                shareMode: DWORD(FILE_SHARE_READ),
                creationDisposition: DWORD(OPEN_EXISTING),
                flags: DWORD(FILE_ATTRIBUTE_NORMAL | FILE_FLAG_SEQUENTIAL_SCAN)
            )
            defer { handle.close() }

            var buffer = Data()
            let chunkSize: Int = 64 * 1024
            var temp = [UInt8](repeating: 0, count: chunkSize)

            while true {
                var bytesRead: DWORD = 0
                let success = temp.withUnsafeMutableBytes { pointer -> Bool in
                    guard let baseAddress = pointer.baseAddress else {
                        return true
                    }
                    return ReadFile(
                        handle.rawValue,
                        baseAddress,
                        DWORD(pointer.count),
                        &bytesRead,
                        nil
                    )
                }

                if !success {
                    throw Win32Error(function: #function)
                }

                if bytesRead == 0 {
                    break
                }

                buffer.append(contentsOf: temp.prefix(Int(bytesRead)))
            }

            return buffer
        } catch let error as FileSystemError {
            throw error
        } catch let error as Win32Error {
            throw FileSystemError.win32(
                error,
                path: path,
                message: "Unable to read file '\(path)'."
            )
        }
    }

    static func writeFile(_ data: Data, to path: FilePath) throws {
        do {
            let handle = try self.openFileHandle(
                at: path,
                access: DWORD(GENERIC_WRITE),
                shareMode: DWORD(FILE_SHARE_READ),
                creationDisposition: DWORD(CREATE_ALWAYS),
                flags: DWORD(FILE_ATTRIBUTE_NORMAL)
            )
            defer { handle.close() }

            try data.withUnsafeBytes { buffer in
                guard let baseAddress = buffer.baseAddress else { return }
                var offset = 0
                var remaining = buffer.count

                while remaining > 0 {
                    let chunk = min(remaining, Int(DWORD.max))
                    var bytesWritten: DWORD = 0

                    let success = WriteFile(
                        handle.rawValue,
                        baseAddress.advanced(by: offset),
                        DWORD(chunk),
                        &bytesWritten,
                        nil
                    )

                    if !success {
                        throw Win32Error(function: #function)
                    }

                    if bytesWritten == 0 {
                        throw Win32Error(function: #function)
                    }

                    remaining -= Int(bytesWritten)
                    offset += Int(bytesWritten)
                }
            }
        } catch let error as FileSystemError {
            throw error
        } catch let error as Win32Error {
            throw FileSystemError.win32(
                error,
                path: path,
                message: "Unable to write file '\(path)'."
            )
        }
    }
}

private extension Win32FileSystemShim {
    static func attributes(of path: FilePath) throws -> WIN32_FILE_ATTRIBUTE_DATA {
        try self.withWidePath(path) { widePointer in
            var data = WIN32_FILE_ATTRIBUTE_DATA()
            let result = GetFileAttributesExW(
                widePointer,
                GetFileExInfoStandard,
                &data
            )

            guard result else {
                throw Win32Error(function: #function)
            }

            return data
        }
    }

    static func enumerateDirectory(_ path: FilePath) throws -> [DirectoryEntry] {
        let searchPattern = self.searchPattern(for: path)
        return try self.withWideString(searchPattern) { widePattern in
            var findData = WIN32_FIND_DATAW()
            let handle = FindFirstFileW(widePattern, &findData)

            guard handle != INVALID_HANDLE_VALUE else {
                throw Win32Error(function: #function)
            }

            defer { FindClose(handle) }

            var results: [DirectoryEntry] = []

            var shouldContinue = true
            while shouldContinue {
                let name = withUnsafePointer(to: &findData.cFileName.0) {
                    String(decodingCString: $0, as: UTF16.self)
                }

                if name != "." && name != ".." {
                    let childPath = path.appending(name)
                    let info = self.makeFileInfo(path: childPath, findData: findData)
                    results.append(
                        DirectoryEntry(name: name, path: childPath, info: info)
                    )
                }

                let next = FindNextFileW(handle, &findData)
                if !next {
                    let error = GetLastError()
                    if error == ERROR_NO_MORE_FILES {
                        shouldContinue = false
                    } else {
                        throw Win32Error(function: #function, code: error)
                    }
                }
            }

            return results
        }
    }

    static func makeFileInfo(path: FilePath, attributes: WIN32_FILE_ATTRIBUTE_DATA) -> FileInfo {
        let type = self.fileType(from: attributes.dwFileAttributes)
        let size = self.combinedSize(
            high: attributes.nFileSizeHigh,
            low: attributes.nFileSizeLow
        )
        let creation = self.date(from: attributes.ftCreationTime)
        let modification = self.date(from: attributes.ftLastWriteTime)
        let lastAccess = self.date(from: attributes.ftLastAccessTime)
        let hidden = (attributes.dwFileAttributes & DWORD(FILE_ATTRIBUTE_HIDDEN)) != 0

        return FileInfo(
            path: path,
            type: type,
            size: size,
            creationDate: creation,
            modificationDate: modification,
            lastAccessDate: lastAccess,
            isHidden: hidden
        )
    }

    static func makeFileInfo(path: FilePath, findData: WIN32_FIND_DATAW) -> FileInfo {
        let type = self.fileType(from: findData.dwFileAttributes)
        let size = self.combinedSize(
            high: findData.nFileSizeHigh,
            low: findData.nFileSizeLow
        )
        let creation = self.date(from: findData.ftCreationTime)
        let modification = self.date(from: findData.ftLastWriteTime)
        let lastAccess = self.date(from: findData.ftLastAccessTime)
        let hidden = (findData.dwFileAttributes & DWORD(FILE_ATTRIBUTE_HIDDEN)) != 0

        return FileInfo(
            path: path,
            type: type,
            size: size,
            creationDate: creation,
            modificationDate: modification,
            lastAccessDate: lastAccess,
            isHidden: hidden
        )
    }

    static func combinedSize(high: DWORD, low: DWORD) -> UInt64 {
        (UInt64(high) << 32) | UInt64(low)
    }

    static func date(from fileTime: FILETIME) -> Date? {
        let ticks = UInt64(fileTime.dwHighDateTime) << 32 | UInt64(fileTime.dwLowDateTime)
        guard ticks != 0 else { return nil }

        let seconds = Double(ticks) / 10_000_000.0
        return Date(timeIntervalSince1970: seconds - 11_644_473_600.0)
    }

    static func fileType(from attributes: DWORD) -> FileType {
        if (attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT)) != 0 {
            return .symbolicLink
        }
        if (attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY)) != 0 {
            return .directory
        }
        return .regular
    }

    static func withWidePath<R>(
        _ path: FilePath,
        _ body: (UnsafePointer<WCHAR>) throws -> R
    ) throws -> R {
        try self.withWideString(self.systemRepresentation(of: path), body)
    }

    static func withWideString<R>(
        _ string: String,
        _ body: (UnsafePointer<WCHAR>) throws -> R
    ) throws -> R {
        var utf16 = Array(string.utf16)
        utf16.append(0)
        return try utf16.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                throw Win32Error(function: #function, code: DWORD(ERROR_INVALID_PARAMETER))
            }
            return try body(baseAddress)
        }
    }

    static func searchPattern(for path: FilePath) -> String {
        var base = self.systemRepresentation(of: path)
        if base.isEmpty {
            base = "."
        }
        if !base.hasSuffix("\\") && !base.hasSuffix("/") {
            base.append("\\")
        }
        base.append("*")
        return base
    }

    static func systemRepresentation(of path: FilePath) -> String {
        path.description.replacingOccurrences(of: "/", with: "\\")
    }

    static func stat(at path: FilePath) -> Result<_stat64, Errno> {
        Result {
            try self.withWidePath(path) { widePointer in
                var status = _stat64()
                let result = _wstat64(widePointer, &status)
                if result == 0 {
                    return status
                } else {
                    throw Errno(rawValue: _errno().pointee)
                }
            }
        }.mapError { error in
            error as? Errno ?? Errno(rawValue: _errno().pointee)
        }
    }

    static func withWidePathPair<R>(
        _ first: FilePath,
        _ second: FilePath,
        _ body: (UnsafePointer<WCHAR>, UnsafePointer<WCHAR>) throws -> R
    ) throws -> R {
        try self.withWidePath(first) { firstPointer in
            try self.withWidePath(second) { secondPointer in
                try body(firstPointer, secondPointer)
            }
        }
    }

    static func openFileHandle(
        at path: FilePath,
        access: DWORD,
        shareMode: DWORD,
        creationDisposition: DWORD,
        flags: DWORD
    ) throws -> Win32FileHandle {
        let handle: HANDLE? = try self.withWidePath(path) { widePointer in
            CreateFileW(
                widePointer,
                access,
                shareMode,
                nil,
                creationDisposition,
                flags,
                nil
            )
        }

        guard let handle, handle != INVALID_HANDLE_VALUE else {
            throw Win32Error(function: #function)
        }

        return Win32FileHandle(rawValue: handle)
    }
}

private struct Win32FileHandle {
    let rawValue: HANDLE

    func close() {
        CloseHandle(self.rawValue)
    }
}

#endif
