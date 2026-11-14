import Foundation
import Darwin

/// Identity of a running incy Xray TUN, sampled both before a round and before each resume.
struct IncyTunnel: Equatable, Codable {
    let pid: pid_t
    let started: Int
    let microseconds: Int32
    let index: UInt32
    let name: String
    let address: String

    static func current() -> IncyTunnel? {
        let pidFile = "/var/tmp/incy-xray/pid"
        var file = stat()
        guard lstat(pidFile, &file) == 0, file.st_mode & S_IFMT == S_IFREG,
              file.st_uid == 0, file.st_mode & 0o022 == 0, file.st_size <= 32,
              let value = try? String(contentsOfFile: pidFile, encoding: .utf8),
              let pid = pid_t(value.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return nil }
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var proc = kinfo_proc(), size = MemoryLayout<kinfo_proc>.size
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard sysctl(&mib, 4, &proc, &size, nil, 0) == 0, size == MemoryLayout<kinfo_proc>.size,
              proc.kp_proc.p_pid == pid, proc.kp_eproc.e_ucred.cr_uid == 0,
              proc.kp_proc.p_stat != SSTOP, proc.kp_proc.p_stat != SZOMB,
              proc_pidpath(pid, &path, UInt32(path.count)) > 0,
              String(cString: path) == "/Applications/incy.app/Contents/app/resources/bin/xray",
              case .interface(let index) = defaultRoute(AF_INET) else { return nil }
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }; defer { freeifaddrs(head) }
        var node = head
        while let entry = node {
            let item = entry.pointee
            node = item.ifa_next
            let flags = Int32(item.ifa_flags)
            guard let sa = item.ifa_addr, Int32(sa.pointee.sa_family) == AF_INET,
                  flags & (IFF_UP | IFF_RUNNING | IFF_POINTOPOINT) == (IFF_UP | IFF_RUNNING | IFF_POINTOPOINT),
                  if_nametoindex(item.ifa_name) == index else { continue }
            let name = String(cString: item.ifa_name)
            var numeric = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard name.hasPrefix("utun"), getnameinfo(sa, socklen_t(sa.pointee.sa_len), &numeric, socklen_t(numeric.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(cString: numeric)
            guard ["198.18.0.2", "169.254.10.2"].contains(address) else { continue }
            let birth = proc.kp_proc.p_starttime
            return Self(pid: pid, started: birth.tv_sec, microseconds: birth.tv_usec, index: index, name: name, address: address)
        }
        return nil
    }

    /// Read the unscoped default route. A scoped Wi-Fi gateway or link-local utun alone is insufficient.
    enum DefaultRoute: Equatable {
        case absent
        case interface(UInt32)
        case unknown
    }

    // With only link-local addresses macOS can still have scoped utun defaults.
    // A usable unicast source (including ULA) makes their absence as an
    // unscoped default insufficient evidence for IPv4-only operation.
    static func hasRoutableIPv6Address() -> Bool? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var node: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = node {
            let item = entry.pointee
            node = item.ifa_next
            guard Int32(item.ifa_flags) & IFF_UP != 0, let sa = item.ifa_addr,
                  Int32(sa.pointee.sa_family) == AF_INET6 else { continue }
            guard sa.pointee.sa_len >= MemoryLayout<sockaddr_in6>.size else { return nil }
            var address = UnsafeRawPointer(sa).load(as: sockaddr_in6.self).sin6_addr
            if withUnsafeBytes(of: &address, { !isLocalIPv6($0) }) { return true }
        }
        return false
    }

    private static func isLocalIPv6(_ bytes: UnsafeRawBufferPointer) -> Bool {
        let loopback = bytes.prefix(15).allSatisfy { $0 == 0 } && bytes[15] == 1
        return loopback || bytes[0] == 0xff || (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80)
    }

    static func defaultRoute(_ family: Int32) -> DefaultRoute {
        var mib = [CTL_NET, PF_ROUTE, 0, family, NET_RT_DUMP2, 0]
        var size = 0
        guard family == AF_INET || family == AF_INET6,
              sysctl(&mib, 6, nil, &size, nil, 0) == 0 else { return .unknown }
        guard size > 0 else { return .unknown }
        var data = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 6, &data, &size, nil, 0) == 0 else { return .unknown }
        guard size <= data.count else { return .unknown }
        let route = parseDefaultRoute(data.prefix(size), family: family)
        if family == AF_INET6 && route == .absent && hasRoutableIPv6Address() != false { return .unknown }
        return route
    }

    static func parseDefaultRoute(_ data: ArraySlice<UInt8>, family: Int32) -> DefaultRoute {
        let size = data.count
        return data.withUnsafeBytes { buf in
            var offset = 0
            let headerSize = MemoryLayout<rt_msghdr2>.size
            var candidates = Set<UInt32>()
            var specificInterfaces = Set<UInt32>()
            while offset + headerSize <= size {
                let h = buf.loadUnaligned(fromByteOffset: offset, as: rt_msghdr2.self)
                let end = offset + Int(h.rtm_msglen)
                guard end >= offset + headerSize, end <= size else { return .unknown }
                defer { offset = end }
                guard h.rtm_flags & RTF_UP != 0,
                      h.rtm_flags & (RTF_REJECT | RTF_BLACKHOLE) == 0 else { continue }
                var cursor = offset + headerSize
                var zeroDestination = false
                var localDestination = false
                var zeroMask = false
                guard h.rtm_addrs & RTA_DST != 0 else { return .unknown }
                for i in 0...Int(RTAX_NETMASK) where h.rtm_addrs & (1 << i) != 0 {
                    guard cursor + 2 <= end else { return .unknown }
                    let length = Int(buf[cursor])
                    guard cursor + length <= end else { return .unknown }
                    if i == Int(RTAX_DST) {
                        let start = family == AF_INET ? 4 : 8
                        let count = family == AF_INET ? 4 : 16
                        guard buf[cursor+1] == UInt8(family), length >= start + count else { return .unknown }
                        let address = UnsafeRawBufferPointer(rebasing: buf[(cursor+start)..<(cursor+start+count)])
                        zeroDestination = address.allSatisfy { $0 == 0 }
                        localDestination = family == AF_INET6 && isLocalIPv6(address)
                    } else if i == Int(RTAX_NETMASK) {
                        zeroMask = length <= 2 || buf[(cursor+2)..<(cursor+length)].allSatisfy { $0 == 0 }
                    }
                    cursor += max(4, (length + 3) & ~3)
                }
                if zeroDestination && zeroMask && h.rtm_flags & RTF_HOST == 0 {
                    if h.rtm_flags & RTF_IFSCOPE == 0 { candidates.insert(UInt32(h.rtm_index)) }
                } else if family == AF_INET6 && !localDestination && h.rtm_flags & RTF_LOCAL == 0 {
                    // A host or split route (including ::/1) may exist without ::/0.
                    specificInterfaces.insert(UInt32(h.rtm_index))
                }
            }
            guard offset == size, candidates.count <= 1 else { return .unknown }
            guard let index = candidates.first else { return specificInterfaces.isEmpty ? .absent : .unknown }
            guard specificInterfaces.subtracting([index]).isEmpty else { return .unknown }
            return index == 0 ? .unknown : .interface(index)
        }
    }
}
