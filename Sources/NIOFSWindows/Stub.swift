#if os(Windows)

@_exported import _NIOFileSystem
import NIOCore
import NIOPosix

/// Windows placeholder for the high level `FileSystem` API.
public enum FileSystemSupport {
    /// Helper to surface a consistent unsupported error.
    public static func unsupportedError(function: StaticString = #function) -> FileSystemError {
        FileSystemError.unsupported("\(function) is not available on Windows yet.")
    }
}

public extension FileSystem {
    func shutdownGracefully() {
        // no-op placeholder
    }

    func withFileSystem<T>(_ body: (FileSystem) throws -> T) rethrows -> T {
        try body(self)
    }
}

#endif
