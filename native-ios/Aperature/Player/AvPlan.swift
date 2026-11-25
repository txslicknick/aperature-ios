// AvPlan.swift — the audio/subtitle plan (one for every device; the owner: subtitles that never fail, every user's audio
// and subtitle languages truly honoured). The page sends the server's checked plan for each episode ({type:'avplan'}):
// the audio by the file's own track, the subtitles in order (the file's own tracks by their index, the addons' as
// signed links already converted and timed). This follows it, quietly, once the episode is loaded; your own pick in the
// menus always wins. After start: the chosen subtitles judged by their data every 5 s of playing (none, past the end,
// not the plan's language, or none around now while another of the plan's tracks has dialogue right there) -> the next
// one, at most once a minute; a quiet scene is never a reason.
// (The same rules as Aperature for Windows' AvPlan.cs and the server's netlify/lib/avplan.mjs.)
import Foundation

final class AvPlanner {
    private var plans: [Int: [String: Any]] = [:]
    private var applied = Set<Int>()
    private var curPos = -1, switches = 0
    private var curK: String?, curSid: String?
    private var lastPos = -1.0, played = 0.0, sinceCheck = 0.0, switchedAt = -Double.infinity, pickedAt = 0.0
    var event: ((String, Bool) -> Void)?   // (code, ok): totals on the page (no names)

    func set(index: Int, plan: [String: Any]) { plans[index] = plan; applied.remove(index) }
    func has(_ i: Int) -> Bool { plans[i] != nil }

    // every second
    func tick(_ m: MPV, paused: Bool, userSub: Bool, userAudio: Bool) {
        let i = m.playlistPos
        guard i >= 0, m.duration > 0, let plan = plans[i] else { return }
        if i != curPos { curPos = i; curK = nil; curSid = nil; lastPos = -1; switches = 0; played = 0; sinceCheck = 0; pickedAt = 0; switchedAt = -Double.infinity }
        if !applied.contains(i) { applied.insert(i); apply(m, plan, userSub: userSub, userAudio: userAudio); return }
        watch(m, plan, paused: paused, userSub: userSub)
    }

    private struct T { let id: String; let type: String; let file: String; let ff: Int; let selected: Bool }
    private func tracks(_ m: MPV) -> [T] {
        let n = min(200, max(0, m.getInt("track-list/count")))
        return (0..<n).map { k in
            let p = "track-list/\(k)/"
            return T(id: m.getString(p + "id") ?? "", type: m.getString(p + "type") ?? "", file: m.getString(p + "external-filename") ?? "",
                     ff: Int(m.getString(p + "ff-index") ?? "") ?? -1, selected: m.getString(p + "selected") == "yes")
        }
    }
    private static func order(_ plan: [String: Any]) -> [[String: Any]] { ((plan["subs"] as? [String: Any])?["order"] as? [[String: Any]]) ?? [] }
    private static func int(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue }

    private func apply(_ m: MPV, _ plan: [String: Any], userSub: Bool, userAudio: Bool) {
        let all = tracks(m)
        if !userAudio, let a = plan["audio"] as? [String: Any], let ff = Self.int(a["ff"]),
           let t = all.first(where: { $0.type == "audio" && $0.ff == ff }), !t.selected { m.setString("aid", t.id) }
        let order = Self.order(plan)
        // the plan's addon subtitles go in once each (they're in the menu too) — six at most, the best first
        var added = 0
        for e in order {
            guard e["src"] as? String == "addon", let u = e["url"] as? String, u.hasPrefix("https://"), !all.contains(where: { $0.type == "sub" && $0.file == u }) else { continue }
            added += 1
            if added > 6 { break }
            m.command(["sub-add", u, "auto", (e["t"] as? String) ?? "Subtitles", (e["lang"] as? String) ?? ""])
        }
        if userSub { return }
        if ((plan["subs"] as? [String: Any])?["off"] as? Bool) == true { m.setString("sid", "no"); curK = nil; curSid = nil; return }
        _ = pick(m, order, from: 0, why: "plan")
    }

    // the entries from `from` on until one is there (an addon one that didn't load never became a track); why: plan, or
    // what was wrong (empty, range, lang, sparse)
    private func pick(_ m: MPV, _ order: [[String: Any]], from: Int, why: String) -> Bool {
        let all = tracks(m)
        var j = max(0, from)
        while j < order.count && j < from + 6 {
            let e = order[j]
            j += 1
            let file = e["src"] as? String == "file"
            let t = file ? all.first(where: { $0.type == "sub" && $0.ff == (Self.int(e["ff"]) ?? -2) })
                         : all.first(where: { $0.type == "sub" && !$0.file.isEmpty && $0.file == (e["url"] as? String ?? "") })
            guard let t else { if !file { event?("load", false) }; continue }
            if !t.selected { m.setString("sid", t.id) }
            curK = e["k"] as? String; curSid = t.id; pickedAt = played
            if why != "plan" { event?(why, true) }
            return true
        }
        return false
    }

    private func watch(_ m: MPV, _ plan: [String: Any], paused: Bool, userSub: Bool) {
        guard !userSub, let k = curK, switches < 3 else { return }
        if m.getString("sid") != curSid { curK = nil; return }   // (changed some other way: left alone)
        let pos = m.position, dt = pos - lastPos
        lastPos = pos
        guard !paused, dt > 0, dt < 2 else { return }   // (paused, or a seek)
        played += dt; sinceCheck += dt
        guard sinceCheck >= 5 else { return }
        sinceCheck = 0
        guard played - switchedAt >= 60, played - pickedAt >= 10 else { return }
        let order = Self.order(plan)
        guard let cur = order.first(where: { $0["k"] as? String == k }) else { return }
        let want = ((plan["subs"] as? [String: Any])?["want"] as? String) ?? ""
        var lang = m.getString("current-tracks/sub/lang") ?? ""
        if lang.isEmpty { lang = (cur["lang"] as? String) ?? "" }
        let delay = Double(m.getString("sub-delay") ?? "") ?? 0
        let why = Self.health(cur, durS: m.duration, atS: pos - delay, ref: Self.refMins(order, k), langOk: want.isEmpty || Self.sameLang(lang, want))
        guard !why.isEmpty else { return }
        switches += 1
        switchedAt = played
        let at = order.firstIndex(where: { $0["k"] as? String == k }) ?? -1
        _ = pick(m, order, from: at + 1, why: why)
    }

    // ---- the same rules as the server's netlify/lib/avplan.mjs (subHealth, refMins) and the page's js/logic.js
    private static func nums(_ v: Any?) -> [Double]? { (v as? [Any]).map { $0.map { ($0 as? NSNumber)?.doubleValue ?? 0 } } }
    private static func sameLang(_ a: String, _ b: String) -> Bool {
        let two = ["eng": "en", "jpn": "ja", "spa": "es", "fre": "fr", "fra": "fr", "ger": "de", "deu": "de", "ita": "it", "por": "pt", "kor": "ko", "chi": "zh", "zho": "zh", "rus": "ru", "ara": "ar", "hin": "hi"]
        let base = { (x: String) -> String in let l = x.lowercased(); return two[l] ?? String(l.prefix(2)) }
        return !a.isEmpty && !b.isEmpty && base(a) == base(b)
    }
    static func linesBetween(_ mins: [Double]?, _ fromS: Double, _ toS: Double) -> Double {
        guard let mins, toS > fromS else { return 0 }
        var sum = 0.0
        var i = max(0, Int(floor(fromS / 60)))
        while i < mins.count && Double(i * 60) < toS {
            let a = max(fromS, Double(i * 60)), b = min(toS, Double(i * 60 + 60))
            if b > a { sum += mins[i] * (b - a) / 60 }
            i += 1
        }
        return sum
    }
    // "" = fine; empty | range | lang | sparse (none around now while another track has dialogue right there)
    static func health(_ e: [String: Any], durS: Double, atS: Double, ref: [Double]?, langOk: Bool) -> String {
        if let n = e["lines"] as? NSNumber, n.doubleValue <= 0 { return "empty" }
        let lastS = ((e["last"] as? NSNumber)?.doubleValue ?? 0) / 1000
        if durS > 0 && lastS > durS + 20 { return "range" }
        if !langOk { return "lang" }
        if let mins = nums(e["mins"]), mins.reduce(0, +) > 0, linesBetween(mins, atS - 150, atS + 150) == 0, linesBetween(ref, atS - 150, atS + 150) >= 3 { return "sparse" }
        return ""
    }
    static func refMins(_ order: [[String: Any]], _ k: String) -> [Double]? {
        var best: [Double]? = nil, n = 0.0
        for e in order where e["k"] as? String != k && e["kind"] as? String != "signs" {
            guard let mins = nums(e["mins"]) else { continue }
            let sum = mins.reduce(0, +)
            if sum > n { n = sum; best = mins }
        }
        return best
    }
}
