import AppKit
import Foundation

// Expose only a synthetic permit issuer for the isolated socket suite.
if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "issue-permit",
   let port = Int(CommandLine.arguments[2]) {
    setLaunchPermit(port, Date().addingTimeInterval(9.9))
    print("ready"); fflush(stdout)
    while readLine() != nil { setLaunchPermit(port, Date().addingTimeInterval(9.9)); print("ready"); fflush(stdout) }
    exit(0)
}

func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    precondition(condition(), label)
    print("PASS: \(label)")
}
let fm = FileManager.default
try fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
let dir = supportDir.appendingPathComponent(UUID().uuidString)
try fm.createDirectory(at: dir, withIntermediateDirectories: true)
try testServices()
let fixture = Process()
fixture.executableURL = supportDir.deletingLastPathComponent().appendingPathComponent("dozor-test-worker")
fixture.arguments = [dir.path]
try fixture.run()
var fixturePIDs: [pid_t] = [fixture.processIdentifier]
defer {
    for pid in fixturePIDs { kill(pid, SIGKILL) }
    fixture.waitUntilExit()
}
for _ in 0..<100 {
    if (0...2).allSatisfy({ fm.fileExists(atPath: dir.appendingPathComponent("level\($0).pid").path) }) { break }
    usleep(20000)
}
fixturePIDs = try (0...2).map { pid_t(try String(contentsOf: dir.appendingPathComponent("level\($0).pid")))! }
let processes = fixturePIDs.compactMap(LocalProcess.read)
expect(processes.count == 3, "real parent, child and grandchild discovered")
let root = processes[0]
let cliRoot = LocalProcess(identity:root.identity,parent:root.parent,path:"/synthetic/bin/claude",stopped:root.stopped)
expect(cliRoot.isClaudeCLI, "native CLI detected by executable path")
expect(!LocalProcess.isClaudeCLI(path: "/Applications/Claude.app/Contents/MacOS/Claude"), "CLI selection does not accidentally include Claude Desktop")
expect(LocalProcess.isClaudeCLI(path: "/Users/test/.local/share/claude/versions/2.2.0"), "versioned native install detected")
expect(LocalProcess.isClaudeCLI(path: "/opt/homebrew/bin/node", arguments: ["node", "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"]), "npm CLI script detected")
expect(!LocalProcess.isClaudeCLI(path: "/opt/homebrew/bin/node", arguments: ["node", "/tmp/other.js", "claude"]), "unrelated Node process not matched")
expect(!LocalProcess.isClaudeCLI(path: "/bin/zsh", arguments: ["zsh", "-c", "claude"]), "terminal shell not matched")
expect(!LocalProcess.isClaudeCLI(path: "/opt/homebrew/bin/node", arguments: ["node", "-e", "/x/@anthropic-ai/claude-code/cli.js"]), "Node eval text not matched")
expect(isValidIP("2001:db8::1") && !isValidIP("::::") && !isValidIP("999.2.3.4"), "IPv4 and IPv6 validation")
expect(ipMatches("2001:db8::123", rule: "2001:db8::/32"), "IPv6 CIDR matching")
expect(ipMatches("2001:db8::1", rule: "2001:0db8:0:0:0:0:0:1"), "equivalent IPv6 spelling")
expect(!ipMatches("2001:db9::1", rule: "2001:db8::/32") && !ipMatches("192.0.2.1", rule: "2001:db8::/0"), "different IPv6 subnet and address family rejected")
expect(ipMatches("192.0.2.5", rule: "192.0.2.0/24") && !ipMatches("192.0.3.5", rule: "192.0.2.0/24"), "IPv4 CIDR still works")
let monitor = Monitor()
monitor.readIncyTunnel = { nil }
monitor.cfg.notifications = false
monitor.cfg.guard.enabled = true
monitor.cfg.guard.apps = [claudeCLITarget]
monitor.cfg.guard.allow.ips = ["192.0.2.1"]
monitor.cfg.guard.allow.countries = ["AT"]
let snapshot = Dictionary(([cliRoot] + Array(processes.dropFirst())).map { ($0.identity.pid, $0) }, uniquingKeysWith: { a, _ in a })
expect(monitor.matchedRoots(snapshot: snapshot).contains { $0.0.identity == root.identity }, "monitor targets CLI independently of GUI")
monitor.cfg.guard.apps = ["com.anthropic.claude-code-url-handler"]
expect(monitor.matchedRoots(snapshot: snapshot).contains { $0.0.identity == root.identity }, "existing URL-handler selection also protects CLI")
monitor.cfg.guard.apps = ["dozor.test.uninstalled"] // Do not target any real application.
let ip = "192.0.2.1", other = "192.0.2.2"
var proxyUp = true
monitor.proxyAcceptsConnections = { _ in proxyUp }
monitor.countryCache = [ip:"AT", other:"AT", "2001:db8::1":"AT"]
let controller = monitor.processGuard
controller.onError = { preconditionFailure($0) }
var continues = 0
func observe(_ c: ProcessGuard) {
    c.sendContinue = { identity in
        precondition(fixturePIDs.contains(identity.pid), "signal outside fixture")
        continues += 1
        return identity.send(SIGCONT)
    }
}
observe(controller)
func waitForStopped(_ expected: Bool) {
    for _ in 0..<100 {
        if fixturePIDs.allSatisfy({ LocalProcess.read($0)?.stopped == expected }) { return }
        usleep(10000)
    }
    preconditionFailure("kernel stop state != \(expected)")
}
func beats() -> [Data] { (0...2).map { try! Data(contentsOf: dir.appendingPathComponent("level\($0).beat")) } }
func begin(_ m: Monitor) -> Int {
    m.beginRouteRound()
}
func reply(_ m: Monitor, _ g: Int, _ direct: [String]? = nil, _ secondary: [String]? = nil,
           _ traces: [String:String]? = nil, _ system: Bool = true, _ require6: Bool = false, _ verified6: Bool = false) {
    m.handleAnswers(direct ?? [ip,ip], additionalRoutes: secondary ?? [ip], ipv6Confirmed: verified6, generation:g,
        traceRoutes: traces ?? Dictionary(uniqueKeysWithValues: Monitor.claudeHosts.map { ($0,ip) }), systemSeen:system, requireV6:require6)
}
expect(Monitor.traceIP("ip=192.0.2.1\nloc=AT") == ip && Monitor.traceIP("ip=broken") == nil &&
       Monitor.traceIP("ip=192.0.2.1\nip=192.0.2.2") == nil, "Claude trace requires one valid IP")
monitor.enforce()
controller.freeze(roots: [(root, "Fixture")]); waitForStopped(true)
expect(controller.records.count == 3, "three fixture processes frozen")
let heldBeats = beats()
func held(_ name: String) {
    waitForStopped(true); usleep(80000)
    expect(continues == 0 && heldBeats == beats(), name)
}
let old = begin(monitor)
proxyUp = false; monitor.enforce()
reply(monitor, old)
for _ in 0..<4 { monitor.enforce() }
held("proxy off: delayed positive response and repeated enforcement send zero SIGCONT")
monitor.state = .ok(ip:ip,country:"AT"); monitor.verifiedAt = ProcessInfo.processInfo.systemUptime; monitor.confirmedRoutes = [ip]
monitor.enforce(); held("cached approved IP cannot release tree with VPN off")
monitor.togglePause(); held("pause sends zero SIGCONT")
expect(monitor.protectionStatus == .holding && monitor.paused && monitor.pauseActionTitle == "Возобновить блокировку",
       "paused controls still report the actual held processes")
monitor.cfg.guard.enabled = false; monitor.enforce(); held("disabling sends zero SIGCONT")
monitor.cfg.guard.apps = []; monitor.enforce(); held("deselecting sends zero SIGCONT")
monitor.prepareForExit(); held("quit sends zero SIGCONT")
let m = Monitor() // reads the same isolated persisted registry
m.cfg.notifications = false; m.cfg.guard.enabled = true; m.cfg.guard.apps = ["dozor.test.uninstalled"]
m.cfg.guard.allow.ips = [ip]; m.cfg.guard.allow.countries = ["AT"]
m.proxyAcceptsConnections = { _ in proxyUp }; m.countryCache = monitor.countryCache
m.readIncyTunnel = { nil }
observe(m.processGuard)
m.resumeLeftovers(); m.enforce()
expect(m.processGuard.records.count == 3, "recovery retains PID + birth time")
held("restart with VPN down sends zero SIGCONT")
proxyUp = true; m.enforce(); held("local listener returning is insufficient to thaw")
reply(m, begin(m), nil,nil,[:]); held("listener up / tunnel down: missing Claude proofs")
expect(m.state == .error("Не подтверждён маршрут к Claude"), "failed round preserves the reason instead of checking forever")
reply(m, begin(m), nil,nil,["api.anthropic.com":ip]); held("missing second Claude proof")
reply(m, begin(m), nil,nil,nil,false); held("missing system route")
reply(m, begin(m), nil,nil,nil,true,true,false); held("unverified available IPv6")
reply(m, begin(m), [ip]); held("insufficient direct quorum")
reply(m, begin(m), [ip,other]); held("inconsistent direct answers")
reply(m, begin(m), nil,[other]); held("same country / wrong egress IP")
reply(m, begin(m), nil,[ip,"2001:db8::1"],nil,true,true,true); held("unexpected IPv6 remains blocked")
let late = begin(m); m.proofStarted = Date().addingTimeInterval(-30); reply(m,late); held("expired round")
m.cfgError = "bad configuration"; reply(m,begin(m)); held("invalid configuration")
m.cfgError = nil; m.online = false; reply(m,begin(m)); held("OS path offline")
m.online = true
// Even a valid cached result must never release an already-held process from a timer.
m.state = .ok(ip:ip,country:nil); m.confirmedRoutes = [ip]; m.verifiedAt = ProcessInfo.processInfo.systemUptime
m.enforce(); held("cached success alone cannot thaw")
reply(m,begin(m)); held("proxy-only: complete current IP proofs without a system VPN can never thaw")
m.cfg.guard.vpn_service_id = "fixture-vpn"
var vpnUp = false
m.vpnConnected = { id in id == "fixture-vpn" && vpnUp }
reply(m,begin(m)); held("selected VPN off, listener up, ALL probes positive: zero SIGCONT")
vpnUp = true; m.enforce(); held("VPN reconnected but no new probe: zero SIGCONT")
reply(m,begin(m)); waitForStopped(false); usleep(180000)
expect(continues == 3 && zip(heldBeats,beats()).allSatisfy { $0 != $1 }, "fresh full proof resumes all three; each heartbeat advances")
expect(m.protectionStatus == .watching, "fresh guard decision is shown as active")
m.state = .offline
expect(m.protectionStatus == .blocked, "old positive verdict cannot mask an offline UI state")
m.state = .ok(ip:ip,country:"AT")
let stale = ProcessIdentity(pid:root.identity.pid,seconds:root.identity.seconds,microseconds:root.identity.microseconds+1)
expect(!stale.send(SIGSTOP), "stale PID identity rejected")
m.processGuard.records[root.identity.pid] = FrozenProcess(identity:stale,name:"stale",depth:0)
m.processGuard.save(); m.resumeLeftovers(); expect(m.processGuard.records.isEmpty,"restart ignores reused PID")
// A proxied listener is neither necessary nor sufficient for the independent incy TUN path.
m.cfg.guard.vpn_service_id = ""
let first = IncyTunnel(pid:101, started:1, microseconds:0, index:71, name:"utun7", address:"198.18.0.2")
let second = IncyTunnel(pid:102, started:2, microseconds:0, index:71, name:"utun7", address:"198.18.0.2")
var fixtureTunnel: IncyTunnel? = first
m.readIncyTunnel = { fixtureTunnel }
m.processGuard.freeze(roots:[(root,"Fixture")]); waitForStopped(true)
let restart = begin(m)
fixtureTunnel = second
reply(m,restart); waitForStopped(true)
expect(continues == 3, "restarted Xray cannot use the previous tunnel's replies")
let disconnect = begin(m)
fixtureTunnel = nil
reply(m,disconnect); waitForStopped(true)
expect(continues == 3, "tunnel lost without OS network notification stays frozen")
fixtureTunnel = first
reply(m,begin(m),nil,[other]); waitForStopped(true)
expect(continues == 3, "direct route outside allowlist prevents TUN recovery")
proxyUp = false
reply(m,begin(m)); waitForStopped(false)
expect(continues == 6 && m.verifiedTunnel == first && m.mayThaw, "fresh incy TUN round releases all three without an HTTP proxy")
m.processGuard.freeze(roots:[(root,"Fixture")]); waitForStopped(true)
m.processGuard.sendContinue = { identity in
    precondition(fixturePIDs.contains(identity.pid)); continues += 1
    let sent = identity.send(SIGCONT); fixtureTunnel = nil; return sent
}
reply(m,begin(m)); waitForStopped(true)
expect(continues == 7, "incy lost between signals stops remaining releases and recaptures the tree")
m.cfg.guard.vpn_service_id = "fixture-vpn"; proxyUp = true
// Deterministically simulate the proxy disappearing BETWEEN two candidate SIGCONT signals.
m.processGuard.freeze(roots:[(root,"Fixture")]); waitForStopped(true)
m.processGuard.sendContinue = { identity in
    precondition(fixturePIDs.contains(identity.pid)); continues += 1
    let sent = identity.send(SIGCONT); proxyUp = false; return sent
}
reply(m,begin(m)); waitForStopped(true)
expect(continues == 8, "mid-release loss stops remaining signals and re-freezes released descendant")
// Exercise the actual grace-timeout branch with VPN off, without an intermediate SIGCONT.
let beforeKill = continues
m.cfg.guard.grace = 1; m.blockedSince = Date(timeIntervalSinceNow:-10); m.enforce()
fixture.waitUntilExit()
for _ in 0..<100 {
    if fixturePIDs.allSatisfy({ pid in var i = proc_bsdinfo(); return proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&i,Int32(MemoryLayout<proc_bsdinfo>.size)) <= 0 || i.pbi_status == 5 }) { break }
    usleep(10000)
}
expect(continues == beforeKill && fixture.terminationReason == .uncaughtSignal && fixture.terminationStatus == SIGKILL, "grace timeout kills stopped fixture without SIGCONT")
expect(fixturePIDs.allSatisfy({ pid in var i = proc_bsdinfo(); return proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&i,Int32(MemoryLayout<proc_bsdinfo>.size)) <= 0 || i.pbi_status == 5 }), "entire timed-out tree exited")
expect(AppCatalog.scan().contains { $0.id == claudeCLITarget }, "CLI available in picker")
let policy = FlowPolicy(port:10808)
for host in ["api.anthropic.com", "CLAUDE.AI.", "claude.com", "files.claudeusercontent.com"] {
    expect(!policy.permits(protected:false,hostname:host,tcp:true,address:"192.0.2.9",destinationPort:443),"known vendor host blocked independently of process")
}
expect(policy.permits(protected:false,hostname:"notanthropic.com",tcp:true,address:"192.0.2.9",destinationPort:443),"unrelated unprotected host")
expect(!policy.permits(protected:true,hostname:nil,tcp:true,address:"192.0.2.9",destinationPort:443),"protected raw IP blocked without hostname")
expect(!policy.permits(protected:true,hostname:nil,tcp:true,address:nil,destinationPort:nil),"unknown protected endpoint fails closed")
expect(!policy.permits(protected:true,hostname:nil,tcp:false,address:"127.0.0.1",destinationPort:10808),"UDP not admitted on proxy port")
expect(policy.permits(protected:true,hostname:nil,tcp:true,address:"127.0.0.1",destinationPort:10808),"system filter policy accepts only configured proxy endpoint")
print("ALL PROCESS AND FLOW-POLICY CHECKS PASSED")
