import Foundation
import NetworkExtension
import Network
import Darwin
import Security

@objc(DozorFilterProvider)
final class DozorFilterProvider: NEFilterDataProvider {
    var policy = FlowPolicy(port: 0)
    var bundles = [String]()
    var cli = true
    let lock = NSLock()
    var seen = Set<ProcessIdentity>()
    var monitorExecutable = ""
    func isMonitor(_ data: Data?) -> Bool {
        guard let data, data.count == MemoryLayout<audit_token_t>.size, !monitorExecutable.isEmpty else { return false }
        var token = data.withUnsafeBytes { $0.loadUnaligned(as: audit_token_t.self) }
        var buf = [CChar](repeating:0,count:Int(MAXPATHLEN)*4)
        return proc_pidpath_audittoken(&token,&buf,UInt32(buf.count)) > 0 && String(cString:buf) == monitorExecutable
    }
    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        let config = filterConfiguration.vendorConfiguration
        guard let port = config?["port"] as? Int, (1...65535).contains(port),
              let paths = config?["bundles"] as? [String], let selectedCLI = config?["cli"] as? Bool else {
            completionHandler(NSError(domain:"DozorFilter",code:1)); return
        }
        monitorExecutable = config?["monitor"] as? String ?? ""
        policy = FlowPolicy(port: port); bundles = paths; cli = selectedCLI
        completionHandler(nil)
    }
    func protected(_ data: Data?) -> Bool? {
        guard let data, data.count == MemoryLayout<audit_token_t>.size else { return nil }
        var token = data.withUnsafeBytes { $0.loadUnaligned(as: audit_token_t.self) }
        var buf = [CChar](repeating:0,count:Int(MAXPATHLEN)*4)
        guard proc_pidpath_audittoken(&token,&buf,UInt32(buf.count)) > 0 else { return nil }
        var pid = pid_t(token.val.5), path = String(cString:buf), visited = Set<pid_t>()
        var lineage = [ProcessIdentity]()
        while pid > 1, visited.insert(pid).inserted {
            var b = proc_bsdinfo()
            guard proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&b,Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size else { return nil }
            let id = ProcessIdentity(pid: pid, seconds: b.pbi_start_tvsec, microseconds:b.pbi_start_tvusec)
            lineage.append(id)
            if lineage.count == 1 && proc_pidpath_audittoken(&token,&buf,UInt32(buf.count)) <= 0 { return nil }
            if bundles.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) ||
                (cli && LocalProcess.isClaudeCLI(path:path,arguments: {
                    let exe = URL(fileURLWithPath:path).lastPathComponent.lowercased()
                    return ["node","nodejs","bun"].contains(exe) ? LocalProcess.arguments(pid) : []
                }())) || seen.contains(id) {
                seen.formUnion(lineage); return true
            }
            pid = pid_t(b.pbi_ppid)
            if pid <= 1 { break }
            guard proc_pidpath(pid,&buf,UInt32(buf.count)) > 0 else { return nil }
            path = String(cString:buf)
        }
        return false
    }

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        guard let f = flow as? NEFilterSocketFlow else { return .drop() }
        // Only IP egress; never break local IPC or unrelated inbound services.
        guard f.direction != .inbound, f.socketFamily == AF_INET || f.socketFamily == AF_INET6 else { return .allow() }
        if isMonitor(flow.sourceProcessAuditToken) { return .allow() } // Direct egress probes from the host itself.
        lock.lock(); defer { lock.unlock() }
        if seen.count > 4096 { seen = seen.filter { id in
            var b = proc_bsdinfo()
            return proc_pidinfo(id.pid,PROC_PIDTBSDINFO,0,&b,Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size &&
                b.pbi_start_tvsec == id.seconds && b.pbi_start_tvusec == id.microseconds
        } }
        let source = protected(flow.sourceProcessAuditToken), app = protected(flow.sourceAppAuditToken)
        // If macOS can't identify either a process or its responsible application, fail closed.
        let unresolved = source == nil || app == nil
        let guarded = source == true || app == true || unresolved
        let dest = f.remoteEndpoint as? NWHostEndpoint
        return policy.permits(protected:guarded, hostname:f.remoteHostname, tcp:f.socketProtocol == IPPROTO_TCP,
                              address:dest?.hostname, destinationPort:dest.flatMap { Int($0.port) }) ? .allow() : .drop()
    }
}

autoreleasepool { NEProvider.startSystemExtensionMode() }
dispatchMain()
