// What Aperature hands the player (the same link as Aperature Player for Windows):
// aperature-player:<base64url JSON> — { v, n, t, items: [{ u, s, t, c }], sl, al }
import Foundation
import CryptoKit

struct PlayJob: Decodable {
    struct Item: Decodable {
        let u: String           // the file's address
        let s: Double?          // where to start (seconds; the first file only)
        let t: String?          // title ("Show · S1E2")
        let c: String?          // episode code ("S1E2")
    }
    let v: Int?
    let n: String               // the hand-back's id (Aperature matches the answer to it)
    let t: String?
    let items: [Item]
    let sl: String?             // subtitle languages ("eng", "-" = off)
    let al: String?             // audio languages
    let sk: Int?                // v1.9.6: the profile's skip amount (seconds a press)
    let sd: Double?             // v1.9.6: the show's subtitle timing (seconds, + = later)
    let sc: String?             // v1.9.8: subtitle colour (#RRGGBB)
    let sb: String?             // v1.9.8: subtitle background (box / none / solid)
    let ss: String?             // v1.9.8: subtitle size (s / m / l / xl)
    var so: Int? = nil          // v1.12.5: subtitle opacity (%; missing = solid)
    var an: Int? = nil          // v1.12.5: autoplay (0 = off; missing = on)
    var vb: Int? = nil          // v1.12.12: volume boost (%: 100 = normal, up to 300)
    var be: String? = nil       // v1.17.4: the profile's own Boost ("b1,…,b7,detail,even"; missing = Theater; MPV.tunedFilter)
    var sa: String? = nil       // v1.14.0: the only subtitle languages to offer (eng,jpn…; missing = all)
    var aa: String? = nil       // v1.14.0: the only audio languages to offer
    let rb: String?             // v1.10.1: this account's PC on the home network ("http://<ip>:<port>/b/<key>"): files come through it
    var ml: Int? = nil          // v1.16.22: the longest an episode's file can be (seconds): a far longer one is another video
    var sm: Int? = nil          // v1.17.23: subtitles in the audio's language, following it (1)

    // v1.10.1: the same job with every file coming through the PC (when it answers on this Wi-Fi, within a second and a half)
    func throughPC(_ done: @escaping (PlayJob) -> Void) {
        guard let rb, rb.range(of: "^http://(10|192\\.168|172\\.(1[6-9]|2[0-9]|3[01]))(\\.[0-9]{1,3}){2,3}:[0-9]{2,5}/b/[A-Za-z0-9]{16,64}$", options: .regularExpression) != nil,
              let ping = URL(string: rb + "/ping") else { done(self); return }
        var req = URLRequest(url: ping)
        req.timeoutInterval = 1.5
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200 && (data.flatMap { String(data: $0, encoding: .utf8) } ?? "").contains("Aperature")
            guard ok else { DispatchQueue.main.async { done(self) }; return }
            var allowed = CharacterSet.urlQueryAllowed
            allowed.remove(charactersIn: "&=?+#")
            let items = self.items.map { it -> Item in
                guard it.u.hasPrefix("http") else { return it }          // a file on this iPhone stays as it is
                let enc = it.u.addingPercentEncoding(withAllowedCharacters: allowed) ?? it.u
                return Item(u: rb + "/f/" + PlayJob.relayId(it.u) + "?u=" + enc, s: it.s, t: it.t, c: it.c)
            }
            var j = PlayJob(v: self.v, n: self.n, t: self.t, items: items, sl: self.sl, al: self.al, sk: self.sk, sd: self.sd, sc: self.sc, sb: self.sb, ss: self.ss, so: self.so, an: self.an, rb: self.rb)
            j.vb = self.vb; j.be = self.be; j.sa = self.sa; j.aa = self.aa; j.ml = self.ml
            DispatchQueue.main.async { done(j) }
        }.resume()
    }
    // the PC's name for a file: SHA-1 of its address, the first 24 hex digits (Relay.IdOf)
    static func relayId(_ url: String) -> String {
        let d = Insecure.SHA1.hash(data: Data(url.utf8))
        return String(d.map { String(format: "%02x", $0) }.joined().prefix(24))
    }

    // v1.12.10: what the website handed over about the title (r: the show, its episodes) as JSON text for the page, or nil
    static func carriedRun(link: String) -> String? {
        var s = link
        guard s.hasPrefix("aperature-player:") else { return nil }
        s.removeFirst("aperature-player:".count)
        while s.hasPrefix("/") { s.removeFirst() }
        while s.hasSuffix("/") { s.removeLast() }
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        guard let data = Data(base64Encoded: b), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let r = obj["r"] as? [String: Any], let out = try? JSONSerialization.data(withJSONObject: r), let txt = String(data: out, encoding: .utf8) else { return nil }
        return txt
    }
    static func jsString(_ v: String) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: [v]), let t = String(data: d, encoding: .utf8) else { return "\"\"" }
        return String(t.dropFirst().dropLast())
    }

    static func decode(link: String) -> PlayJob? {
        var s = link
        guard s.hasPrefix("aperature-player:") else { return nil }
        s.removeFirst("aperature-player:".count)
        while s.hasPrefix("/") { s.removeFirst() }
        while s.hasSuffix("/") { s.removeLast() }
        guard s.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { return nil }
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        guard let data = Data(base64Encoded: b), var job = try? JSONDecoder().decode(PlayJob.self, from: data) else { return nil }
        // v1.12: "apdl:<id>" is a download saved by this app: the file on this iPhone
        let orig = job
        job = PlayJob(v: job.v, n: job.n, t: job.t, items: job.items.compactMap { item -> Item? in
            if item.u.hasPrefix("apdl:") {
                // (gone: kept in its place so the playlist still matches Aperature's; it just won't play)
                let f = Downloads.file(id: String(item.u.dropFirst(5)))
                return Item(u: f?.path ?? item.u, s: item.s, t: item.t, c: item.c)
            }
            guard let u = URL(string: item.u), let sch = u.scheme?.lowercased(), sch == "http" || sch == "https" else { return nil }
            return item
        }, sl: job.sl, al: job.al, sk: job.sk, sd: job.sd, sc: job.sc, sb: job.sb, ss: job.ss, so: job.so, an: job.an, rb: job.rb)
        job.vb = orig.vb; job.be = orig.be; job.sa = orig.sa; job.aa = orig.aa   // (v1.14.0: Boost and the languages came through too; v1.17.4: and the tuned Boost)
        job.sm = orig.sm   // v1.17.23
        job.ml = orig.ml   // v1.0.71 (iOS): the longest an episode can be was dropped here, so v1.16.22's "another video" check never ran
        return job.items.isEmpty ? nil : job
    }
}

// v1.0.71 (iOS): read leniently — a number field sent as 2160.5 (or "10", or true) failed the whole decode, and the
// file silently didn't play. Whole-number fields take a fractional number (rounded), a numeric string or a bool; an
// optional field of the wrong type is left out. Only n and items must be right.
extension PlayJob {
    private enum CodingKeys: String, CodingKey { case v, n, t, items, sl, al, sk, sd, sc, sb, ss, so, an, vb, be, sa, aa, rb, ml, sm }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func int(_ k: CodingKeys) -> Int? {
            if let i = try? c.decodeIfPresent(Int.self, forKey: k) { return i }
            if let d = try? c.decodeIfPresent(Double.self, forKey: k) { return d.isFinite && abs(d) < 1e12 ? Int(d.rounded()) : nil }
            if let s = try? c.decodeIfPresent(String.self, forKey: k) {
                guard let d = Double(s.trimmingCharacters(in: .whitespaces)), d.isFinite, abs(d) < 1e12 else { return nil }
                return Int(d.rounded())
            }
            if let b = try? c.decodeIfPresent(Bool.self, forKey: k) { return b ? 1 : 0 }
            return nil
        }
        func dbl(_ k: CodingKeys) -> Double? {
            if let d = try? c.decodeIfPresent(Double.self, forKey: k) { return d.isFinite ? d : nil }
            if let s = try? c.decodeIfPresent(String.self, forKey: k), let d = Double(s.trimmingCharacters(in: .whitespaces)), d.isFinite { return d }
            return nil
        }
        func str(_ k: CodingKeys) -> String? { try? c.decodeIfPresent(String.self, forKey: k) }
        let n = try c.decode(String.self, forKey: .n)
        let items = try c.decode([Item].self, forKey: .items)
        self.init(v: int(.v), n: n, t: str(.t), items: items, sl: str(.sl), al: str(.al), sk: int(.sk), sd: dbl(.sd),
                  sc: str(.sc), sb: str(.sb), ss: str(.ss), so: int(.so), an: int(.an), vb: int(.vb), be: str(.be),
                  sa: str(.sa), aa: str(.aa), rb: str(.rb), ml: int(.ml))
        self.sm = int(.sm)
    }
}

// Where you stopped, for Aperature: the playlist entry, the position and its length (seconds), e = 1 when nothing played.
struct PlayResult: Encodable {
    let n: String
    let i: Int
    let p: Int
    let d: Int
    let e: Int
    let sd: Double              // the subtitle timing when it closed (kept for the show)
    let sk: Int                 // the skip amount (kept for the profile)
    let bw: Int                 // v1.9.6: how fast files loaded (bytes a second; 0 = not measured)
    let st: Int                 // v1.9.6: how often this file stopped to load
    let pa: String?             // v1.9.7: audio picked by hand (a language code): the show's from now on
    let ps: String?             // v1.9.7: subtitles picked by hand (a code; "-" = off)
    var nx: Int = 0
    var an: Int? = nil          // v1.12.5: changed in the player's Settings (nil = not changed): autoplay 0 / 1
    var vb: Int? = nil          // v1.12.12: volume boost picked in the player (%; nil = not changed)
    var so: Int? = nil          //          and subtitle opacity (%)             // v1.12.3: 1 = Next pressed on the last one, 2 = the last one ended: Aperature plays the next episode
    var sl: Int = 0             // v1.16.12: this device couldn't keep up with the file (its height, e.g. 2160; 0 = fine)
    var cm: Int = 0             // v1.16.15: the buffer's limit (MiB), free space when it opened (GB), times it filled up
    var cf: Int = 0
    var ch: Int = 0
    var zz: Int = 0
    var wl: Int = 0             // v1.16.22: 1 = file i was far longer than the episode (another video): the page plays the next file             // v1.16.15: 1 = the sleep timer's "Still watching?" went unanswered: file i from its start
    var w: [Int] = []           // v1.0.55: the episodes played to the end (their places in the list)
    // v1.0.58: how the loading went (the site's play log; no addresses): ms to the first picture (-1: never), seconds
    // spent stopped to load, the file's video / audio codec, kind, size and height, and the way it came
    var ms: Int = -1
    var bs: Int = 0
    var vc: String = ""
    var ac: String = ""
    var fm: String = ""
    var fs: Int = 0
    var vh: Int = 0
    var rt: String = "direct"
}
