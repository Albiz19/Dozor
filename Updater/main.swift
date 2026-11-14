import AppKit
import Darwin

// The app has verified the new package and exchanged the bundles on disk.
// Wait for normal termination (including watchdog disarm) before relaunching.
let args = CommandLine.arguments
guard args.count == 4, let pid = pid_t(args[1]), pid > 1 else { exit(1) }
let app = URL(fileURLWithPath: args[2]).standardizedFileURL
let backup = URL(fileURLWithPath: args[3]).standardizedFileURL
let folder = backup.deletingLastPathComponent()
guard app.lastPathComponent == "Dozor.app", backup.lastPathComponent == "Dozor.app",
      folder.lastPathComponent.hasPrefix(".dozor-update-"),
      folder.deletingLastPathComponent().path == app.deletingLastPathComponent().path,
      FileHandle.standardInput.readData(ofLength: 1) == Data([1]) else { exit(1) }
for _ in 0..<300 where kill(pid, 0) == 0 { usleep(100000) }
guard kill(pid, 0) != 0 && errno == ESRCH else { exit(1) }
func launch() -> Bool {
    let opener = Process()
    opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    opener.arguments = [app.path]
    do { try opener.run(); opener.waitUntilExit(); return opener.terminationStatus == 0 }
    catch { return false }
}
if !launch() {
    guard renamex_np(app.path, backup.path, UInt32(RENAME_SWAP)) == 0, launch() else { exit(2) }
}
try? FileManager.default.removeItem(at: folder)
