import Foundation
import Darwin

/// The lock is retained until process exit. Never unlink a live flock inode.
final class MonitorInstance {
    let lockFD: Int32
    let attempt: Int
    let ticket: URL

    init?(directory: URL, arguments: [String]) {
        // A read-only directory descriptor needs no writable lock file.
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return nil }
        ticket = directory.appendingPathComponent("watchdog.ticket")
        if arguments.first == "--watchdog-recovery" {
            guard arguments.count == 3, let incoming = UUID(uuidString: arguments[1]),
                  let saved = try? String(contentsOf: ticket, encoding: .utf8), saved == incoming.uuidString,
                  let retry = Int(arguments[2]), (1...3).contains(retry) else { close(fd); return nil }
            attempt = retry
        } else {
            attempt = 0
        }
        // An active owner has the lock. Old recovery tickets cannot start a later
        // instance after a manual launch followed by a clean exit.
        try? FileManager.default.removeItem(at: ticket)
        lockFD = fd
    }
    deinit { close(lockFD) }
}

final class CrashWatchdog {
    private var helper: Process?
    private var writer: FileHandle?
    var armed: Bool { helper?.isRunning == true }

    func configure(enabled: Bool, instance: MonitorInstance, executable: URL) throws {
        guard enabled else { disarm(instance); return }
        guard !armed else { return }
        // Rotate the ticket on every re-arm so a disabled helper cannot race a new one.
        let token = UUID().uuidString
        try token.write(to: instance.ticket, atomically: true, encoding: .utf8)
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw POSIXError(.EIO) }
        let reader = FileHandle(fileDescriptor: pair[0], closeOnDealloc: true)
        let writer = FileHandle(fileDescriptor: pair[1], closeOnDealloc: true)
        var one: Int32 = 1
        guard fcntl(pair[0], F_SETFD, FD_CLOEXEC) == 0,
              fcntl(pair[1], F_SETFD, FD_CLOEXEC) == 0,
              setsockopt(pair[1], SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one))) == 0 else {
            throw POSIXError(.EIO)
        }
        let child = Process()
        child.executableURL = executable.deletingLastPathComponent().appendingPathComponent("dozor-watchdog")
        var st = stat()
        guard lstat(executable.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { throw POSIXError(.ENOENT) }
        child.arguments = [instance.ticket.path, token, String(instance.attempt), String(st.st_dev), String(st.st_ino),
                           String(st.st_ctimespec.tv_sec), String(st.st_ctimespec.tv_nsec)]
        child.standardInput = reader
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        self.helper = child
        self.writer = writer
        try? reader.close()
    }

    func disarm(_ instance: MonitorInstance) {
        // A byte means deliberate exit, EOF alone means abrupt termination.
        // MSG_NOSIGNAL is unavailable on macOS; the socket has SO_NOSIGPIPE.
        if let writer {
            var byte: UInt8 = 1
            while send(writer.fileDescriptor, &byte, 1, 0) < 0 && errno == EINTR {}
        }
        try? FileManager.default.removeItem(at: instance.ticket)
        try? writer?.close()
        writer = nil
        helper = nil
    }
}
