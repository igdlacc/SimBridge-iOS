import Darwin
import Foundation

/// Authenticated encrypted UDP LAN discovery complementing Bonjour (`_simbridge._tcp`).
/// Ensures two paired phones find each other across changing Wi-Fi/Hotspot networks without re-scanning QR.
enum LanDiscovery {
    struct LanInterface: Sendable {
        let name: String
        let addrHostOrder: UInt32
        let maskHostOrder: UInt32
        let broadcastHostOrder: UInt32
    }

    struct DiscoveryResult: Sendable {
        let ips: [String]
        let wsPort: Int?
        let udpPort: Int?

        static let empty = DiscoveryResult(ips: [], wsPort: nil, udpPort: nil)
    }

    private static let excludedPrefixes = ["lo", "pdp_ip", "utun", "ipsec", "awdl", "llw", "anpi", "ap_"]

    static func activeLanInterfaces() -> [LanInterface] {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else {
            return []
        }
        defer { freeifaddrs(firstAddr) }

        var results: [LanInterface] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let flags = current.pointee.ifa_flags
            guard (flags & UInt32(IFF_UP)) != 0,
                  (flags & UInt32(IFF_LOOPBACK)) == 0,
                  (flags & UInt32(IFF_POINTOPOINT)) == 0,
                  let sa = current.pointee.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }

            let name = String(cString: current.pointee.ifa_name).lowercased()
            if excludedPrefixes.contains(where: { name.hasPrefix($0) }) {
                continue
            }

            let addrIn = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            let ip = UInt32(bigEndian: addrIn.sin_addr.s_addr)
            // Skip link-local (169.254.0.0/16) and loopback (127.0.0.0/8).
            if (ip & 0xFFFF0000) == 0xA9FE0000 || (ip & 0xFF000000) == 0x7F000000 {
                continue
            }

            let mask: UInt32
            if let maskPtr = current.pointee.ifa_netmask,
               maskPtr.pointee.sa_family == UInt8(AF_INET) {
                let maskIn = maskPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                let m = UInt32(bigEndian: maskIn.sin_addr.s_addr)
                mask = m != 0 ? m : 0xFFFFFF00
            } else {
                mask = 0xFFFFFF00
            }

            let bcast: UInt32
            if (flags & UInt32(IFF_BROADCAST)) != 0,
               let bcastPtr = current.pointee.ifa_dstaddr,
               bcastPtr.pointee.sa_family == UInt8(AF_INET) {
                let bIn = bcastPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                let b = UInt32(bigEndian: bIn.sin_addr.s_addr)
                bcast = (b != 0 && b != ip) ? b : ((ip & mask) | ~mask)
            } else {
                bcast = (ip & mask) | ~mask
            }

            results.append(
                LanInterface(
                    name: name,
                    addrHostOrder: ip,
                    maskHostOrder: mask,
                    broadcastHostOrder: bcast
                )
            )
        }
        return results
    }

    static func currentLanSignature() -> String {
        activeLanInterfaces()
            .map { "\($0.name):\(ipv4String($0.addrHostOrder))/\(ipv4String($0.maskHostOrder))" }
            .sorted()
            .joined(separator: ",")
    }

    static func probe(
        bridgeId: String,
        udpPort: Int,
        key: Data,
        includeSubnetSweep: Bool
    ) async -> DiscoveryResult {
        guard udpPort > 0, udpPort <= Int(UInt16.max) else { return .empty }
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                cont.resume(
                    returning: probeSync(
                        bridgeId: bridgeId,
                        udpPort: UInt16(udpPort),
                        key: key,
                        includeSubnetSweep: includeSubnetSweep
                    )
                )
            }
        }
    }

    private static func probeSync(
        bridgeId: String,
        udpPort: UInt16,
        key: Data,
        includeSubnetSweep: Bool
    ) -> DiscoveryResult {
        let ifaces = activeLanInterfaces()
        guard !ifaces.isEmpty else { return .empty }

        let seq = UInt16.random(in: 1...UInt16.max)
        let salt = UInt32.random(in: 1...UInt32.max)
        guard let reqWire = UdpAudioPacket.encode(
            type: UdpAudioPacket.typeDiscoverReq,
            direction: UdpAudioPacket.dirIosToAndroid,
            seq: seq,
            timestampSamples: 0,
            callHash: 0,
            payload: Data(bridgeId.utf8),
            key: key,
            salt: salt,
            nonceCounter: UInt64(Date().timeIntervalSince1970 * 1000)
        ) else {
            return .empty
        }

        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return .empty }
        defer { Darwin.close(fd) }

        var on: Int32 = 1
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        var nosig: Int32 = 1
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))

        var bindAddr = sockaddr_in()
        bindAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        bindAddr.sin_family = sa_family_t(AF_INET)
        bindAddr.sin_port = 0
        bindAddr.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)
        let bindRes = withUnsafePointer(to: &bindAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRes == 0 else { return .empty }

        var fastTargets: [UInt32] = []
        func appendUniqueTarget(_ ip: UInt32, into arr: inout [UInt32]) {
            if ip != 0 && !arr.contains(ip) {
                arr.append(ip)
            }
        }
        for iface in ifaces {
            appendUniqueTarget(iface.broadcastHostOrder, into: &fastTargets)
            let gw = (iface.addrHostOrder & iface.maskHostOrder) | 1
            if gw != iface.addrHostOrder {
                appendUniqueTarget(gw, into: &fastTargets)
            }
        }
        appendUniqueTarget(0xFFFFFFFF, into: &fastTargets)

        sendProbe(fd: fd, targets: fastTargets, port: udpPort, packet: reqWire)

        var sweepTargets: [UInt32] = []
        if includeSubnetSweep {
            var seen = Set(fastTargets)
            for iface in ifaces {
                seen.insert(iface.addrHostOrder)
                let net = iface.addrHostOrder & iface.maskHostOrder
                let bcast = net | ~iface.maskHostOrder
                let hostCount = bcast > (net + 1) ? (bcast - net - 1) : 0
                guard hostCount >= 1, hostCount <= 510 else { continue }
                for host in (net + 1)..<bcast where !seen.contains(host) {
                    seen.insert(host)
                    sweepTargets.append(host)
                }
            }
        }

        let startTime = Date()
        let totalWindowSec = includeSubnetSweep ? 0.70 : 0.45
        var secondBurstSent = false
        var buf = [UInt8](repeating: 0, count: 2048)

        while true {
            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed >= totalWindowSec { break }
            if !secondBurstSent && elapsed >= 0.12 {
                secondBurstSent = true
                if !sweepTargets.isEmpty {
                    sendProbe(fd: fd, targets: sweepTargets, port: udpPort, packet: reqWire)
                } else {
                    sendProbe(fd: fd, targets: fastTargets, port: udpPort, packet: reqWire)
                }
            }

            let stepMs: Int32
            if !secondBurstSent {
                stepMs = max(20, Int32((0.12 - elapsed) * 1000))
            } else {
                stepMs = max(20, Int32((totalWindowSec - elapsed) * 1000))
            }

            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&pfd, 1, stepMs)
            if ready <= 0 { continue }

            var srcAddr = sockaddr_in()
            var srcLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = buf.withUnsafeMutableBytes { rawBuf -> Int in
                guard let base = rawBuf.baseAddress else { return -1 }
                let cap = rawBuf.count
                return withUnsafeMutablePointer(to: &srcAddr) { addrPtr in
                    addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                        Darwin.recvfrom(fd, base, cap, 0, saPtr, &srcLen)
                    }
                }
            }
            guard n > 0 else { continue }

            let pktData = Data(buf.prefix(n))
            guard let decoded = UdpAudioPacket.decode(data: pktData, key: key),
                  decoded.type == UdpAudioPacket.typeDiscoverResp,
                  let parsed = try? JSONDecoder().decode(LanDiscoveryPayload.self, from: decoded.payload),
                  parsed.bridgeId == bridgeId else {
                continue
            }

            let senderIp = ipv4String(UInt32(bigEndian: srcAddr.sin_addr.s_addr))
            var discoveredIps: [String] = []
            if !senderIp.isEmpty && senderIp != "0.0.0.0" {
                discoveredIps.append(senderIp)
            }
            for ip in parsed.ips where !ip.isEmpty && !discoveredIps.contains(ip) {
                discoveredIps.append(ip)
            }
            if !discoveredIps.isEmpty {
                return DiscoveryResult(
                    ips: discoveredIps,
                    wsPort: parsed.wsPort > 0 ? parsed.wsPort : nil,
                    udpPort: parsed.udpPort > 0 ? parsed.udpPort : nil
                )
            }
        }

        return .empty
    }

    private static func sendProbe(fd: Int32, targets: [UInt32], port: UInt16, packet: Data) {
        packet.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            let count = rawBuf.count
            for target in targets {
                var dst = sockaddr_in()
                dst.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                dst.sin_family = sa_family_t(AF_INET)
                dst.sin_port = port.bigEndian
                dst.sin_addr = in_addr(s_addr: target.bigEndian)
                _ = withUnsafePointer(to: &dst) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.sendto(fd, base, count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
    }

    private static func ipv4String(_ ipHostOrder: UInt32) -> String {
        var addr = in_addr(s_addr: ipHostOrder.bigEndian)
        var cBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &addr, &cBuf, socklen_t(INET_ADDRSTRLEN)) != nil else {
            return ""
        }
        return String(cString: cBuf)
    }
}
