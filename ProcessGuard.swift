import Foundation
import Darwin

let claudeCLITarget = "dozor.cli.claude"

struct ProcessIdentity: Codable, Hashable {
    let pid: pid_t
    let seconds: UInt64
    let microseconds: UInt64

    static func read(_ pid: pid_t) -> ProcessIdentity? {
        guard pid > 1 else { return nil }
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
              info.pbi_uid == getuid() else { return nil }
        return ProcessIdentity(pid: pid, seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
    }
    var isCurrent: Bool { Self.read(pid) == self }
    @discardableResult func send(_ signal: Int32) -> Bool {
        guard isCurrent else { return false }
        return kill(pid, signal) == 0
    }
}

struct LocalProcess {
    let identity: ProcessIdentity
    let parent: pid_t
    let path: String
    let stopped: Bool

    static func read(_ pid: pid_t) -> LocalProcess? {
        var info = proc_bsdinfo()
        guard pid > 1, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
              info.pbi_uid == getuid() else { return nil }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        _ = proc_pidpath(pid, &path, UInt32(path.count))
        return LocalProcess(identity: ProcessIdentity(pid: pid, seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec),
                            parent: pid_t(info.pbi_ppid), path: String(cString: path), stopped: info.pbi_status == 4)
    }

    static func snapshot() -> [pid_t: LocalProcess] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [:] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 1024)
        let found = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard found > 0 else { return [:] }
        return Dictionary(pids.prefix(min(Int(found), pids.count)).compactMap { pid in
            Self.read(pid).map { (pid, $0) }
        }, uniquingKeysWith: { first, _ in first })
    }

    static func arguments(_ pid: pid_t) -> [String] {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0 else { return [] }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc < 65536 else { return [] }
        var index = MemoryLayout<Int32>.size
        while index < size && bytes[index] != 0 { index += 1 } // executable path
        while index < size && bytes[index] == 0 { index += 1 }
        var args: [String] = []
        while index < size && args.count < Int(argc) {
            let start = index
            while index < size && bytes[index] != 0 { index += 1 }
            args.append(String(decoding: bytes[start..<index], as: UTF8.self))
            index += 1
        }
        return args // environment is deliberately not parsed
    }

    static func isClaudeCLI(path: String, arguments: [String] = []) -> Bool {
        let p = path.lowercased()
        let name = URL(fileURLWithPath: p).lastPathComponent
        if (name == "claude" || name == "claude.exe") && !p.contains(".app/") { return true }
        if p.contains("/.local/share/claude/versions/") { return true }
        guard name == "node" || name == "nodejs" || name == "bun" else { return false }
        // Match the interpreter's script, never prompts or arbitrary command arguments.
        guard arguments.count > 1 else { return false }
        var i = 1
        let paired: Set<String> = ["-r", "--require", "--import", "--loader", "--conditions", "-C"]
        while i < arguments.count && arguments[i].hasPrefix("-") {
            let a = arguments[i]
            if a == "--" { i += 1; break }
            if a == "-e" || a == "-p" || a.hasPrefix("--eval") || a.hasPrefix("--print") || a == "-" { return false }
            i += paired.contains(a) ? 2 : 1
        }
        guard i < arguments.count else { return false }
        let script = URL(fileURLWithPath: arguments[i]).resolvingSymlinksInPath().path.lowercased()
        return !script.hasPrefix("-") && script.contains("/@anthropic-ai/claude-code/") &&
            ["cli.js", "claude.js"].contains(URL(fileURLWithPath: script).lastPathComponent)
    }
    var isClaudeCLI: Bool {
        if Self.isClaudeCLI(path: path) { return true }
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        guard ["node", "nodejs", "bun"].contains(name) else { return false }
        return Self.isClaudeCLI(path: path, arguments: Self.arguments(identity.pid))
    }
}

struct FrozenProcess: Codable {
    let identity: ProcessIdentity
    let name: String
    let depth: Int
    var target: String? = nil
}

/// Store PID together with kernel start time, so PID reuse cannot target an unrelated process.
final class ProcessGuard {
    let stateURL: URL
    var records: [pid_t: FrozenProcess] = [:]
    var snapshotProcesses: () -> [pid_t: LocalProcess] = LocalProcess.snapshot
    var onError: ((String) -> Void)?
    init(stateURL: URL) { self.stateURL = stateURL }
    var names: [pid_t: String] { records.mapValues(\.name) }

    @discardableResult func save() -> Bool {
        do {
            let data = try JSONEncoder().encode(Array(records.values))
            try data.write(to: stateURL, options: .atomic)
            return true
        } catch { onError?("Не удалось сохранить состояние заморозки: \(error.localizedDescription)"); return false }
    }

    func recover() {
        guard let data = try? Data(contentsOf: stateURL) else { return }
        guard let stored = try? JSONDecoder().decode([FrozenProcess].self, from: data) else {
            onError?("Старый frozen.json не содержит времени запуска процессов; сигналы по непроверенным PID не отправлены")
            return
        }
        records = Dictionary(stored.filter { $0.identity.isCurrent }.map { ($0.identity.pid, $0) }, uniquingKeysWith: { a, _ in a })
        // Loading persisted ownership never releases a process.
    }

    func freeze(roots: [(LocalProcess, String)], targets: [pid_t: String] = [:]) {
        let previous = Set(records.keys)
        for record in Array(records.values) {
            guard let current = LocalProcess.read(record.identity.pid), current.identity == record.identity else {
                records.removeValue(forKey: record.identity.pid)
                continue
            }
            if !current.stopped && !record.identity.send(SIGSTOP) {
                onError?("Не удалось восстановить заморозку: \(record.name)")
            }
        }
        if roots.isEmpty && records.isEmpty { if !previous.isEmpty { _ = save() }; return }
        let me = getpid()
        func stop(_ process: LocalProcess, name: String, depth: Int, target: String?) {
            let pid = process.identity.pid
            guard pid != me, records[pid] == nil, !process.stopped, process.identity.isCurrent else { return }
            records[pid] = FrozenProcess(identity: process.identity, name: name, depth: depth, target: target)
            // Persist before SIGSTOP to make crash recovery possible.
            _ = save() // Persistence failure must not prevent an in-memory stop.
            if !process.identity.send(SIGSTOP) {
                records.removeValue(forKey: pid); _ = save()
                onError?("Не удалось заморозить \(name), PID \(pid)")
            }
        }
        for (root, name) in roots { stop(root, name: name, depth: 0, target: targets[root.identity.pid]) }
        // Roots are already stopped; now scan their children, stopping each parent before its children.
        // Previously frozen descendants remain roots here even after being reparented.
        for _ in 0..<2 {
            let snapshot = snapshotProcesses()
            var queue = records.values.map { ($0.identity, $0.name, $0.depth, $0.target) }
            queue += roots.map { ($0.0.identity, $0.1, 0, targets[$0.0.identity.pid]) }
            var visited = Set<pid_t>()
            var children: [pid_t: [LocalProcess]] = [:]
            for p in snapshot.values { children[p.parent, default: []].append(p) }
            var index = 0
            while index < queue.count {
                let (identity, name, depth, target) = queue[index]; index += 1
                let pid = identity.pid
                // Parentage by PID is meaningful only for the same process instance.
                guard snapshot[pid]?.identity == identity, identity.isCurrent,
                      visited.insert(pid).inserted else { continue }
                for child in children[pid] ?? [] where child.identity.pid != me {
                    stop(child, name: name, depth: depth + 1, target: target)
                    queue.append((child.identity, name, depth + 1, target))
                }
            }
        }
        if Set(records.keys) != previous { _ = save() }
    }

    var sendContinue: (ProcessIdentity) -> Bool = { $0.send(SIGCONT) }
    func resumeVerified(while permitted: () -> Bool) {
        let entries = Array(records.values)
        // Children first: the parent cannot immediately issue work to a still-stopped helper.
        for entry in entries.sorted(by: { $0.depth > $1.depth }) {
            guard permitted() else { break }
            if entry.identity.isCurrent && !sendContinue(entry.identity) {
                onError?("Не удалось разморозить \(entry.name), PID \(entry.identity.pid)")
                continue
            }
            records.removeValue(forKey: entry.identity.pid)
        }
        _ = save()
    }
}
