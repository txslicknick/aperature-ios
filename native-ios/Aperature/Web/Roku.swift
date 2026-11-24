// "Open Aperature on Roku" in the iPhone app: finds a Roku on this Wi-Fi and starts the Aperature channel on it
// (Roku's External Control: POST :8060/launch/dev — the channel you installed yourself is "dev").
// Apple keeps network announcements (multicast) for apps it approves, so the app asks each address on this
// Wi-Fi instead (iOS asks once for "Local Network" permission). The last Roku found is tried first.
// One source body. Many apertures. No compulsory simultaneity.
import Foundation

enum RokuLauncher {
    struct Result: Encodable { let ok: Bool; let name: String?; let ip: String?; let error: String?; let found: Int }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 1.6
        c.timeoutIntervalForResource = 3
        c.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: c)
    }()

    static func open(typed: String? = nil, done: @escaping (Result) -> Void) {
        Task {
            var hosts: [String] = []
            if let t = clean(typed) { hosts.append(t) }
            else if let last = UserDefaults.standard.string(forKey: "rokuLast") { hosts.append(last) }
            var name: String? = nil, ip: String? = nil
            if let h = hosts.first, let n = await deviceName(h) { name = n; ip = h }
            if ip == nil && typed != nil {
                done(Result(ok: false, name: nil, ip: nil, error: "unreachable", found: 0)); return
            }
            if ip == nil {
                let found = await scan()
                if let first = found.first { ip = first.0; name = first.1 }
                hosts = found.map { $0.0 }
            }
            guard let ip else { done(Result(ok: false, name: nil, ip: nil, error: "none", found: 0)); return }
            var req = URLRequest(url: URL(string: "http://\(ip):8060/launch/dev")!)
            req.httpMethod = "POST"
            req.timeoutInterval = 4
            do {
                let (_, resp) = try await session.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<300).contains(code) {
                    UserDefaults.standard.set(ip, forKey: "rokuLast")
                    done(Result(ok: true, name: name, ip: ip, error: nil, found: max(1, hosts.count)))
                } else {
                    done(Result(ok: false, name: name, ip: ip, error: code == 404 ? "notinstalled" : code == 403 ? "control" : "launch", found: max(1, hosts.count)))
                }
            } catch {
                done(Result(ok: false, name: name, ip: ip, error: "launch", found: max(1, hosts.count)))
            }
        }
    }

    private static func clean(_ h: String?) -> String? {
        guard var v = h?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return nil }
        if let r = v.range(of: "://") { v = String(v[r.upperBound...]) }
        while v.hasSuffix("/") { v.removeLast() }
        if let c = v.lastIndex(of: ":") { v = String(v[..<c]) }
        return v.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil ? v : nil
    }

    private static func deviceName(_ host: String) async -> String? {
        guard let url = URL(string: "http://\(host):8060/query/device-info") else { return nil }
        guard let got = try? await session.data(from: url) else { return nil }
        let (data, resp) = got
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let xml = String(data: data, encoding: .utf8), xml.contains("<device-info") else { return nil }
        for tag in ["user-device-name", "friendly-device-name"] {
            if let r = xml.range(of: "<\(tag)>"), let e = xml.range(of: "</\(tag)>", range: r.upperBound..<xml.endIndex) {
                let v = String(xml[r.upperBound..<e.lowerBound]).trimmingCharacters(in: .whitespaces)
                if !v.isEmpty { return v }
            }
        }
        return "your Roku"
    }

    // every address on this Wi-Fi (the phone's /24), 32 at a time
    private static func scan() async -> [(String, String)] {
        guard let me = wifiAddress() else { return [] }
        let parts = me.split(separator: ".")
        guard parts.count == 4 else { return [] }
        let base = parts[0...2].joined(separator: ".")
        let all = (1...254).map { "\(base).\($0)" }.filter { $0 != me }
        var found: [(String, String)] = []
        var i = 0
        while i < all.count && found.isEmpty {
            let batch = Array(all[i..<min(i + 32, all.count)])
            i += 32
            let hits = await withTaskGroup(of: (String, String?).self, returning: [(String, String)].self) { g in
                for h in batch { g.addTask { (h, await deviceName(h)) } }
                var out: [(String, String)] = []
                for await (h, n) in g { if let n { out.append((h, n)) } }
                return out
            }
            found.append(contentsOf: hits)
        }
        return found
    }

    private static func wifiAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let a = p {
            let ifa = a.pointee
            if ifa.ifa_addr.pointee.sa_family == UInt8(AF_INET), String(cString: ifa.ifa_name) == "en0" {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(ifa.ifa_addr, socklen_t(ifa.ifa_addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                return String(cString: host)
            }
            p = ifa.ifa_next
        }
        return nil
    }
}
