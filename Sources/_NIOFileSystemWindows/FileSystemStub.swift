#if os(Windows)

/// Placeholder error type used while the Windows implementation is under construction.
public enum FileSystemError: Error, Sendable {
    case unsupported(String = "NIOFileSystem is not yet available on Windows.")
}

/// Minimal stand-in for the cross-platform `FileSystem`.
public struct FileSystem: Sendable {
    public static let shared = FileSystem()

    public init() {}
}

/// Marker protocol retained so higher level modules continue to compile.
public protocol FileSystemProtocol: Sendable {}

#endif
