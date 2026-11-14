import Foundation
import Darwin

// This executable can only relaunch its sibling in the same app bundle.
let args = CommandLine.arguments
guard args.count == 8, let token = UUID(uuidString: args[2]),
      let attempt = Int(args[3]), (0...3).contains(attempt),
      let helperURL = Bundle.main.executableURL else { exit(1) }
let directory = helperURL.resolvingSymlinksInPath().deletingLastPathComponent()
guard directory.lastPathComponent == "MacOS",
      directory.deletingLastPathComponent().lastPathComponent == "Contents",
      directory.deletingLastPathComponent().deletingLastPathComponent().pathExtension == "app" else { exit(1) }
let target = directory.appendingPathComponent("Dozor")
let ticket = URL(fileURLWithPath: args[1])
func sameTicket() -> Bool { (try? String(contentsOf: ticket, encoding: .utf8)) == token.uuidString }
func fileIdentity(_ url: URL) -> [String]? {
    var st = stat()
    guard lstat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
    return [String(st.st_dev), String(st.st_ino), String(st.st_ctimespec.tv_sec), String(st.st_ctimespec.tv_nsec)]
}
let image = Array(args[4...7])
guard image == fileIdentity(target), sameTicket() else { exit(1) }
let started = ProcessInfo.processInfo.systemUptime
// Monitor owns the only writable end. EOF means its descriptors were closed.
var byte: UInt8 = 0
var count: Int
repeat { count = read(STDIN_FILENO, &byte, 1) } while count < 0 && errno == EINTR
guard count == 0 && sameTicket() else { exit(0) }
let next = (ProcessInfo.processInfo.systemUptime - started >= 60 ? 0 : attempt) + 1
guard next <= 3 else { exit(0) }
Thread.sleep(forTimeInterval: Double(1 << (next - 1)))
guard sameTicket(), image == fileIdentity(target) else { exit(0) }
let child = Process()
child.executableURL = target
child.arguments = ["--watchdog-recovery", token.uuidString, String(next)]
child.standardInput = FileHandle.nullDevice
child.standardOutput = FileHandle.nullDevice
child.standardError = FileHandle.nullDevice
do { try child.run() } catch { exit(1) }
