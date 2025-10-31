# Windows FileSystem TODO

## Current state
- First pass implementation (`Sources/_NIOFileSystemWindows/FileSystem.swift`) provides async helpers for file info, directory listing, creation/removal, copy, and simple read/write by delegating to `FileManager`.
- API surface mirrors a subset of the POSIX variant so `NIOFS` users can start experimenting on Windows without compiler errors.
- Package wiring keeps the Windows targets in place while re-exporting the shared modules (`NIOFSWindows`, `_NIOFileSystemWindows`, etc.).

## Known gaps
- File operations currently run on Foundation’s `FileManager` rather than the shared `NIOThreadPool`, so there is no reuse of the thread-pool infrastructure or descriptor-level control. This means:
  - No coalescing of blocking syscalls under `NIOThreadPool.runIfActive`.
  - Limited insight into error domains (Foundation wraps Win32 errors into `NSError`).
- Missing low-level Win32 syscall layer:
  - Need wrappers for `_wstat64`, `_wopen`, `CreateFileW`, `FindFirstFileW`/`FindNextFileW`, `DeviceIoControl`, etc., to drive a bespoke `SystemFileHandle` equivalent.
  - No translation for Win32 file attributes into `FileInfo` beyond what `FileManager` exposes.
- Advanced functionality not yet implemented:
  - Descriptor-backed handles for read/write/seek, including async scatter/gather support.
  - Recursive traversal via an `fts`-style walker; today `listDirectory` is non-recursive.
  - Symlink creation/resolution (`symlink`, `readlink`, `lstat`) and reparse-point handling.
  - Permission mapping (`chmod`, ACL translation, default masks) and ownership metadata.
  - Hard-link support, rename with rich options, atomic replace semantics.
  - Eventual reactivation of `NIOPerformanceTester`, `NIOCrashTester`, and filesystem tests on Windows once feature parity approaches POSIX.
- Error taxonomy remains coarse; most failures surface as `.unknown` with an `NSError` payload. Need more granular mapping to `FileSystemError.Code`.

## Follow-up ideas
1. **Introduce Win32 syscall shim:** build a small module that:
   - Converts Swift `FilePath` to UTF-16 and calls Win32 APIs directly.
   - Maps Win32 errors to `Errno`/`FileSystemError.SystemCallError`.
   - Produces `CInterop.Stat` data for reuse by the shared higher-level helpers.
2. **Thread-pool integration:** once the shim exists, port `SystemFileHandle`-like types to Windows and ensure blocking work happens on `NIOThreadPool`.
3. **Directory traversal:** implement iterator types for `FindFirstFileW`/`FindNextFileW`, plus higher-level recursive traversal approximating `fts`.
4. **Symbolic links and reparse points:** detect link types, expose APIs to create/inspect them, and gate functionality on privilege availability.
5. **Permissions story:** decide how much of the POSIX permission API is meaningful on NTFS; consider bridging to ACLs or providing Windows-specific policy.
6. **Testing & tooling:** add dedicated Windows integration tests, re-enable suspended targets, and expand the TODO file with discovered edge cases as the implementation matures.

Feel free to append additional findings or experiments here to keep the roadmap visible alongside the branch.
