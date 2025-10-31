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

import Foundation
import SystemPackage

/// Describes high-level failure reasons for Windows filesystem operations.
public struct FileSystemError: Error, Sendable {
    public enum Code: Sendable {
        case notFound
        case alreadyExists
        case permissionDenied
        case directoryNotEmpty
        case unsupported
        case io
        case unknown
    }

    public var code: Code
    public var message: String
    public var path: FilePath
    public var cause: Error?

    public init(code: Code, message: String, path: FilePath, cause: Error? = nil) {
        self.code = code
        self.message = message
        self.path = path
        self.cause = cause
    }
}

extension FileSystemError {
    fileprivate static func wrap(
        _ error: Error,
        path: FilePath,
        defaultCode: Code = .unknown,
        message: String
    ) -> FileSystemError {
        if let cocoa = error as? CocoaError {
            switch cocoa.code {
            case .fileNoSuchFile, .fileReadNoSuchFile:
                return FileSystemError(code: .notFound, message: message, path: path, cause: error)
            case .fileWriteFileExists:
                return FileSystemError(code: .alreadyExists, message: message, path: path, cause: error)
            case .fileReadNoPermission, .fileWriteNoPermission:
                return FileSystemError(code: .permissionDenied, message: message, path: path, cause: error)
            case .fileWriteUnknown, .fileReadUnknown:
                return FileSystemError(code: .io, message: message, path: path, cause: error)
            default:
                break
            }
        }

        return FileSystemError(code: defaultCode, message: message, path: path, cause: error)
    }
}

public extension FileSystemError {
    static func unsupported(
        _ message: String,
        path: FilePath = FilePath(".")
    ) -> FileSystemError {
        FileSystemError(code: .unsupported, message: message, path: path)
    }
}

/// Classification of filesystem entries.
public enum FileType: Sendable {
    case regular
    case directory
    case symbolicLink
    case characterSpecial
    case blockSpecial
    case socket
    case fifo
    case unknown

    fileprivate init(attributeType: FileAttributeType) {
        switch attributeType {
        case .typeRegular:
            self = .regular
        case .typeDirectory:
            self = .directory
        case .typeSymbolicLink:
            self = .symbolicLink
        case .typeSocket:
            self = .socket
        case .typeCharacterSpecial:
            self = .characterSpecial
        case .typeBlockSpecial:
            self = .blockSpecial
        default:
            self = .unknown
        }
    }
}

/// Basic metadata describing a filesystem object.
public struct FileInfo: Sendable {
    public let path: FilePath
    public let type: FileType
    public let size: UInt64
    public let creationDate: Date?
    public let modificationDate: Date?
    public let lastAccessDate: Date?
    public let isHidden: Bool

    fileprivate init(
        path: FilePath,
        type: FileType,
        size: UInt64,
        creationDate: Date?,
        modificationDate: Date?,
        lastAccessDate: Date?,
        isHidden: Bool
    ) {
        self.path = path
        self.type = type
        self.size = size
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.lastAccessDate = lastAccessDate
        self.isHidden = isHidden
    }
}

/// A directory entry surfaced by ``FileSystem/listDirectory(at:)``.
public struct DirectoryEntry: Sendable {
    public let name: String
    public let path: FilePath
    public let info: FileInfo
}

/// Minimal stand-in for the cross-platform `FileSystem`.
public struct FileSystem: Sendable {
    public static let shared = FileSystem()

    private init() {}

    /// Returns metadata describing the file or directory at `path`.
    public func info(at path: FilePath) async throws -> FileInfo {
        try await Task.detached(priority: .utility) {
            try loadInfo(at: path)
        }.value
    }

    /// Indicates whether an item exists at `path`.
    public func exists(at path: FilePath) async -> Bool {
        await Task.detached(priority: .utility) {
            FileManager.default.fileExists(atPath: path.stringValue)
        }.value
    }

    /// Lists the immediate children of the directory located at `path`.
    public func listDirectory(at path: FilePath) async throws -> [DirectoryEntry] {
        try await Task.detached(priority: .utility) {
            let url = path.fileURL
            do {
                let names = try FileManager.default.contentsOfDirectory(atPath: url.path)
                return try names.compactMap { name in
                    let childPath = path.appending(name)
                    let info = try loadInfo(at: childPath)
                    return DirectoryEntry(name: name, path: childPath, info: info)
                }
            } catch {
                throw FileSystemError.wrap(
                    error,
                    path: path,
                    message: "Unable to list directory '\(path)'."
                )
            }
        }.value
    }

    /// Creates a directory at `path`.
    public func createDirectory(
        at path: FilePath,
        withIntermediateDirectories: Bool = false
    ) async throws {
        try await Task.detached(priority: .utility) {
            do {
                try FileManager.default.createDirectory(
                    at: path.fileURL,
                    withIntermediateDirectories: withIntermediateDirectories
                )
            } catch {
                throw FileSystemError.wrap(
                    error,
                    path: path,
                    message: "Unable to create directory '\(path)'."
                )
            }
        }.value
    }

    /// Removes the item at `path`.
    public func removeItem(at path: FilePath, recursively: Bool = true) async throws {
        try await Task.detached(priority: .utility) {
            let fm = FileManager.default
            let url = path.fileURL

            guard recursively || !isDirectory(url) else {
                // When recursive removal is disallowed, ensure any directory is empty.
                do {
                    let contents = try fm.contentsOfDirectory(atPath: url.path)
                    guard contents.isEmpty else {
                        throw FileSystemError(
                            code: .directoryNotEmpty,
                            message: "Directory '\(path)' is not empty.",
                            path: path
                        )
                    }
                } catch let error as FileSystemError {
                    throw error
                } catch {
                    throw FileSystemError.wrap(
                        error,
                        path: path,
                        message: "Unable to verify contents of '\(path)'."
                    )
                }
                do {
                    try fm.removeItem(at: url)
                } catch {
                    throw FileSystemError.wrap(
                        error,
                        path: path,
                        message: "Unable to remove '\(path)'."
                    )
                }
                return
            }

            do {
                if fm.fileExists(atPath: url.path) {
                    try fm.removeItem(at: url)
                }
            } catch {
                throw FileSystemError.wrap(
                    error,
                    path: path,
                    message: "Unable to remove '\(path)'."
                )
            }
        }.value
    }

    /// Copies the item at `source` to `destination`.
    public func copyItem(
        at source: FilePath,
        to destination: FilePath,
        replaceExisting: Bool = false
    ) async throws {
        try await Task.detached(priority: .utility) {
            let fm = FileManager.default
            let destinationURL = destination.fileURL

            if replaceExisting, fm.fileExists(atPath: destinationURL.path) {
                try fm.removeItem(at: destinationURL)
            }

            do {
                try fm.copyItem(at: source.fileURL, to: destinationURL)
            } catch {
                throw FileSystemError.wrap(
                    error,
                    path: source,
                    message: "Unable to copy '\(source)' to '\(destination)'."
                )
            }
        }.value
    }

    /// Reads the data stored at `path`.
    public func readFile(at path: FilePath) async throws -> Data {
        try await Task.detached(priority: .utility) {
            do {
                return try Data(contentsOf: path.fileURL)
            } catch {
                throw FileSystemError.wrap(
                    error,
                    path: path,
                    message: "Unable to read file '\(path)'."
                )
            }
        }.value
    }

    /// Writes `data` to `path`, optionally creating intermediate directories.
    public func writeFile(
        _ data: Data,
        to path: FilePath,
        createDirectories: Bool = true
    ) async throws {
        try await Task.detached(priority: .utility) {
            let url = path.fileURL
            if createDirectories {
                let directory = url.deletingLastPathComponent()
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
            }

            do {
                try data.write(to: url, options: .atomic)
            } catch {
                throw FileSystemError.wrap(
                    error,
                    path: path,
                    message: "Unable to write file '\(path)'."
                )
            }
        }.value
    }

    /// Placeholder retained for compatibility with the POSIX implementation.
    public func shutdownGracefully() {}
}

// MARK: - Helpers

private extension FilePath {
    var stringValue: String {
        String(describing: self)
    }

    var fileURL: URL {
        URL(fileURLWithPath: self.stringValue)
    }

    init(_ url: URL) {
        self.init(url.path)
    }
}

private func loadInfo(at path: FilePath) throws -> FileInfo {
    let url = path.fileURL
    let attributes: [FileAttributeKey: Any]
    do {
        attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    } catch {
        throw FileSystemError.wrap(
            error,
            path: path,
            message: "Unable to read attributes for '\(path)'."
        )
    }

    let type: FileType
    if let attributeType = attributes[.type] as? FileAttributeType {
        type = FileType(attributeType: attributeType)
    } else {
        type = .unknown
    }

    let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    let creationDate = attributes[.creationDate] as? Date
    let modificationDate = attributes[.modificationDate] as? Date
    let resourceValues = try? url.resourceValues(forKeys: [.contentAccessDateKey, .isHiddenKey])
    let lastAccessDate = resourceValues?.contentAccessDate
    let isHidden = resourceValues?.isHidden ?? false

    return FileInfo(
        path: path,
        type: type,
        size: size,
        creationDate: creationDate,
        modificationDate: modificationDate,
        lastAccessDate: lastAccessDate,
        isHidden: isHidden
    )
}

private func isDirectory(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
}

#endif
