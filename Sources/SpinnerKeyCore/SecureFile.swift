import Foundation

/// File helpers that never leave secrets readable by other users, even briefly.
enum SecureFile {
    static func ensureDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw SpinnerKeyError.io("\(url.path) exists and is not a directory.")
            }
            return
        }
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// Writes to a temp file created with mode 0600 (O_EXCL, so it can't be pre-planted),
    /// fsyncs it, then renames it over the destination. Readers see either the old file
    /// or the new one, never a partial write.
    static func atomicWrite(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try ensureDirectory(directory)
        let temp = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")

        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else {
            throw SpinnerKeyError.io("Could not create \(temp.path): \(String(cString: strerror(errno)))")
        }
        var renamed = false
        defer { if !renamed { unlink(temp.path) } }

        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()

        guard rename(temp.path, url.path) == 0 else {
            throw SpinnerKeyError.io("Could not replace \(url.path): \(String(cString: strerror(errno)))")
        }
        renamed = true
    }
}

/// Exclusive, non-blocking advisory lock so a scheduled run and a manual
/// "Rotate now" can never rotate the same key at the same time.
public final class FileLock {
    private let fd: Int32

    private init(fd: Int32) { self.fd = fd }

    /// Returns nil if another process holds the lock.
    public static func acquire(at url: URL) throws -> FileLock? {
        try SecureFile.ensureDirectory(url.deletingLastPathComponent())
        let fd = open(url.path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else {
            throw SpinnerKeyError.io("Could not open lock file: \(String(cString: strerror(errno)))")
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK { return nil }
            throw SpinnerKeyError.io("Could not lock: \(String(cString: strerror(code)))")
        }
        return FileLock(fd: fd)
    }

    deinit {
        flock(fd, LOCK_UN)
        close(fd)
    }
}
