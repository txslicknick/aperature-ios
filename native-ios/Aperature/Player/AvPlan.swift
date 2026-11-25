// AvPlan.swift — the audio/subtitle plan (one for every device; the owner: subtitles that never fail, every user's audio
// and subtitle languages truly honoured). The page sends the server's checked plan for each episode ({type:'avplan'}):
// the audio by the file's own track, the subtitles in order (the file's own tracks by their index, the addons' as
// signed links already converted and timed). This follows it, quietly, once the episode is loaded; your own pick in the
// menus always wins. After start: the chosen subtitles silent for a minute while the episode talks -> the next one.
// (The same rules as Aperature for Windows' AvPlan.cs and the server's netlify/lib/avplan.mjs.)
import Foundation

final class AvPlanner {
    private var plans: [Int: [String: Any]] = [:]
    private var applied = Set<Int>()
    private var curPos = -1, switches = 0
    private var curK: String?, curSid: String?
    private var silent = 0.0, lastPos = -1.0
    var event: ((String, Bool) -> Void)?   // (code, ok): totals on the page (no names)

    func set(index: Int, plan: [String: Any]) { plans[index] = plan; applied.remove(index) }
    func has(_ i: Int) -> Bool { plans[i] != nil }

    // every second
    func tick(_ m: MPV, paused: Bool, userSub: Bool, userAudio: Bool) {
        let i = m.playlistPos
        guard i >= 0, m.duration > 0, let plan = plans[i] else { return }
        if i != curPos { curPos = i; curK = nil; curSid = nil; silent = 0; lastPos = -1; switches = 0 }
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

    // the entries from `from` on until one is there (an addon one that didn't load never became a track); why: plan | silent
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
            curK = e["k"] as? String; curSid = t.id; silent = 0
            if why != "plan" { event?(why, true) }
            return true
        }
        return false
    }

    private static let textCodecs: Set<String> = ["subrip", "srt", "ass", "ssa", "webvtt", "mov_text", "text"]
    private func watch(_ m: MPV, _ plan: [String: Any], paused: Bool, userSub: Bool) {
        guard !userSub, let k = curK, switches < 3 else { return }
        if m.getString("sid") != curSid { curK = nil; return }   // (changed some other way: left alone)
        let pos = m.position, dt = pos - lastPos
        lastPos = pos
        guard !paused, dt > 0, dt < 2 else { return }
        guard Self.textCodecs.contains((m.getString("current-tracks/sub/codec") ?? "").lowercased()) else { return }   // (a picture track can't say what it shows)
        if let text = m.getString("sub-text"), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { silent = 0; return }
        silent += dt
        let order = Self.order(plan)
        let delay = Double(m.getString("sub-delay") ?? "") ?? 0
        guard Self.subSilent(silent, pos - delay, Self.talkMins(order, k)) else { return }
        switches += 1
        silent = 0
        let at = order.firstIndex(where: { $0["k"] as? String == k }) ?? -1
        _ = pick(m, order, from: at + 1, why: "silent")
    }

    // ---- the same rule as the server's netlify/lib/avplan.mjs
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
    static func subSilent(_ silentS: Double, _ atS: Double, _ mins: [Double]?) -> Bool {
        guard silentS >= 60 else { return false }
        return linesBetween(mins, atS - min(silentS, 120), atS) >= 3
    }
    static func talkMins(_ order: [[String: Any]], _ k: String) -> [Double]? {
        var best: [Double]? = nil, n = 0.0
        for e in order {
            guard let raw = e["mins"] as? [Any] else { continue }
            let mins = raw.map { ($0 as? NSNumber)?.doubleValue ?? 0 }
            let sum = mins.reduce(0, +)
            if e["k"] as? String == k { if sum > 0 { return mins }; continue }
            if e["kind"] as? String != "signs" && sum > n { n = sum; best = mins }
        }
        return best
    }
}
