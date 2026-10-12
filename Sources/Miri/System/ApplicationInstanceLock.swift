import Darwin
import Foundation

/// The kernel releases this lock on exit, including crashes. Keep the file in
/// place: unlinking it could let another process lock a different inode.
final class ApplicationInstanceLock {
    private let descriptor: Int32

    init?(url: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Miri/instance.lock")) throws
    {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        self.descriptor = descriptor
    }

    deinit {
        close(descriptor)
    }
}
