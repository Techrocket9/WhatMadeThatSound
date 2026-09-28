import Darwin
import Foundation

/// Ensures only one agent records at a time, and lets the viewer find out —
/// without polling or talking to launchd — whether an agent is running.
///
/// The agent holds a POSIX write lock on `agent.lock` for as long as it runs;
/// the kernel drops it the moment the process exits, even if it crashes. The
/// file also describes the holder. Other processes query the lock with
/// `F_GETLK`, which reports the holder's PID without taking the lock.
public final class AgentInstanceLock: @unchecked Sendable {
    public struct Owner: Codable, Sendable, Equatable {
        public var pid: Int32
        public var executablePath: String
        public var version: String
        public var startedAt: Date

        public init(pid: Int32, executablePath: String, version: String, startedAt: Date) {
            self.pid = pid
            self.executablePath = executablePath
            self.version = version
            self.startedAt = startedAt
        }
    }

    public enum Error: Swift.Error, CustomStringConvertible {
        case posix(operation: String, code: Int32)

        public var description: String {
            switch self {
            case let .posix(operation, code):
                "\(operation) failed: \(String(cString: strerror(code)))"
            }
        }
    }

    private var fd: Int32

    private init(fd: Int32) {
        self.fd = fd
    }

    deinit {
        release()
    }

    /// Takes the lock and records `owner` in the lock file.
    ///
    /// If another agent holds the lock, either waits for it to exit (`wait`) or
    /// returns `nil` immediately.
    public static func acquire(at url: URL, owner: Owner, wait: Bool) throws -> AgentInstanceLock? {
        let fd = url.withUnsafeFileSystemRepresentation { open($0!, O_RDWR | O_CREAT | O_CLOEXEC, 0o644) }
        guard fd >= 0 else { throw Error.posix(operation: "open", code: errno) }

        var lock = wholeFileLock(type: F_WRLCK)
        while fcntl(fd, wait ? F_SETLKW : F_SETLK, &lock) != 0 {
            let code = errno
            if code == EINTR { continue }
            close(fd)
            if !wait, code == EAGAIN || code == EACCES { return nil }
            throw Error.posix(operation: "fcntl(F_SETLK)", code: code)
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = (try? encoder.encode(owner)) ?? Data()
        ftruncate(fd, 0)
        _ = data.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
        return AgentInstanceLock(fd: fd)
    }

    /// The agent currently holding the lock, or `nil` if no agent is running.
    ///
    /// Must not be called from the process holding the lock: closing any
    /// descriptor for the file would release that process's lock.
    public static func currentOwner(at url: URL) -> Owner? {
        let fd = url.withUnsafeFileSystemRepresentation { open($0!, O_RDONLY | O_CLOEXEC) }
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var lock = wholeFileLock(type: F_WRLCK)
        guard fcntl(fd, F_GETLK, &lock) == 0, lock.l_type != Int16(F_UNLCK) else { return nil }

        var contents = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        var offset: off_t = 0
        while true {
            let count = pread(fd, &buffer, buffer.count, offset)
            guard count > 0 else { break }
            contents.append(contentsOf: buffer.prefix(count))
            offset += off_t(count)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var owner = (try? decoder.decode(Owner.self, from: contents))
            ?? Owner(pid: lock.l_pid, executablePath: "", version: "", startedAt: .distantPast)
        owner.pid = lock.l_pid
        return owner
    }

    /// Releases the lock (also happens automatically when the process exits).
    public func release() {
        guard fd >= 0 else { return }
        close(fd)
        fd = -1
    }

    private static func wholeFileLock(type: Int32) -> flock {
        var lock = flock()
        lock.l_type = Int16(type)
        lock.l_whence = Int16(SEEK_SET)
        lock.l_start = 0
        lock.l_len = 0
        return lock
    }
}
