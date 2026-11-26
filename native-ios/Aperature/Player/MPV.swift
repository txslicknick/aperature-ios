// A thin, thread-safe wrapper around libmpv (from MPVKit): options, the playlist, commands, and the properties the
// player screen follows (time, length, paused, loading, which file, tracks).
import Foundation
import UIKit
import Libmpv

final class MetalLayer: CAMetalLayer {
    // MoltenVK sometimes asks for a 1×1 drawable to finish presenting: ignore it (flicker / stuck 1×1)
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set { if Int(newValue.width) > 1 && Int(newValue.height) > 1 { super.drawableSize = newValue } }
    }
    // EDR (HDR) mode can only be switched on the main thread
    override var wantsExtendedDynamicRangeContent: Bool {
        get { super.wantsExtendedDynamicRangeContent }
        set {
            if Thread.isMainThread { super.wantsExtendedDynamicRangeContent = newValue }
            else { DispatchQueue.main.sync { super.wantsExtendedDynamicRangeContent = newValue } }
        }
    }
}

struct Track {
    let id: Int
    let type: String        // "audio" / "sub"
    let title: String
    let lang: String
    let selected: Bool
    var label: String {
        let l = Locale.current.localizedString(forLanguageCode: lang) ?? lang.uppercased()
        let parts = [lang.isEmpty ? "" : l, title].filter { !$0.isEmpty }
        return parts.isEmpty ? (type == "sub" ? "Subtitles \(id)" : "Track \(id)") : parts.joined(separator: " · ")
    }
}

protocol MPVDelegate: AnyObject {
    func mpvTime(_ position: Double, _ duration: Double)
    func mpvPaused(_ paused: Bool)
    func mpvBuffering(_ buffering: Bool)
    func mpvFile(_ index: Int)
    func mpvEnded(error: Bool)
}

final class MPV {
    private(set) var handle: OpaquePointer?
    private let queue = DispatchQueue(label: "aperature.mpv", qos: .userInitiated)
    weak var delegate: MPVDelegate?
    private var layerRef: MetalLayer

    // what the screen shows
    private(set) var position: Double = 0
    // v1.16.15: the buffer's size limit (bytes) and the free space when the player opened
    var maxBytes: Int64 = 0
    var freeAtStart: Int64 = 0
    private(set) var duration: Double = 0
    private(set) var playlistPos: Int = 0
    private(set) var everPlayed = false
    // v1.0.71 (iOS): per playlist entry (as Windows v1.0.66/67) — this entry has shown its time; and, after an entry that
    // wouldn't load, nothing more is taken from mpv (it had raced on through the rest of the list, nothing playing).
    // Both are only touched on `queue`.
    private var entryPlayed = false
    private var halted = false

    // v1.0.80 (iOS): files through the several-connections loader (FastLoad), as Windows v1.0.76: an episode that won't
    // start through it (an error before it shows, or nothing for 20 s) plays from its own address instead — and after two
    // of those this session, every file does (the loader steps aside by itself). Files that come through the PC on this
    // Wi-Fi (job.rb) are left as they are. `directTried` / `startedAt` are only touched on `queue`.
    private let job: PlayJob
    private let mapUrl: ((String) -> String)?
    private var directTried: [Bool]
    private var startedAt: Date?
    private var startWatch: DispatchSourceTimer?
    private static let loaderLock = NSLock()
    private static var fallbacks = 0
    private static var loaderOffNow = false
    static var loaderOff: Bool { loaderLock.lock(); defer { loaderLock.unlock() }; return loaderOffNow }

    init(layer: MetalLayer, job: PlayJob) {
        layerRef = layer
        self.job = job
        directTried = Array(repeating: false, count: job.items.count)
        let rb = job.rb
        if MPV.loaderOff {
            mapUrl = nil
        } else {
            mapUrl = { (u: String) -> String in
                if let rb, !rb.isEmpty, u.hasPrefix(rb) { return u }
                return FastLoad.map(u)
            }
        }
        guard let h = mpv_create() else { return }
        handle = h
        set("wid", int64: &layerRef)
        // the picture: Metal through MoltenVK, the phone's hardware decoder (HEVC, HDR, AV1 on new iPhones)
        opt("vo", "gpu-next"); opt("gpu-api", "vulkan"); opt("gpu-context", "moltenvk")
        // the phone's decoder when it can (HEVC, HDR, AV1), FFmpeg's own decoders for everything else (VC-1, MPEG-2,
        // 10-bit H.264, old DivX/XviD…) — the same FFmpeg Outplayer and VLC are built on
        opt("hwdec", "videotoolbox,videotoolbox-copy,no"); opt("hwdec-codecs", "all"); opt("vd-lavc-threads", "0"); opt("video-rotate", "no")
        opt("tone-mapping", "auto"); opt("target-colorspace-hint", "yes")    // HDR / Dolby Vision on the phone's screen
        // every audio format plays (TrueHD, DTS-HD MA, FLAC, Opus…): decoded here, mixed for the speakers or AirPods
        opt("audio-channels", "auto-safe"); opt("audio-fallback-to-null", "yes")
        // odd files: look further into them before deciding what's in them
        // v1.16.35: not 50 MB / 20 s any more — that made every file read that much before it started (Outplayer starts
        // at once with FFmpeg's usual look); 5 MB / 3 s still finds every track in odd files
        opt("demuxer-lavf-probesize", "5000000"); opt("demuxer-lavf-analyzeduration", "3")
        // v1.9.6 (what Outplayer-class players do on top of the same FFmpeg): let the phone's decoder try every profile
        // (10-bit H.264, odd HEVC levels) and fall back to FFmpeg's own decoder mid-file if it gives up; mend broken
        // timestamps / damaged packets instead of stopping; read subtitles in any text encoding; a browser's
        // User-Agent for hosts that turn players away
        opt("vd-lavc-check-hw-profile", "no"); opt("vd-lavc-software-fallback", "yes"); opt("hwdec-software-fallback", "yes")
        opt("demuxer-lavf-o", "fflags=+genpts+discardcorrupt"); opt("vd-lavc-skiploopfilter", "default")
        opt("sub-codepage", "auto"); opt("sub-fix-timing", "yes"); opt("embeddedfonts", "yes"); opt("sub-ass-override", "scale")
        opt("user-agent", "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1")
        opt("demuxer-mkv-subtitle-preroll", "index")   // (v1.16.35: seeks don't re-read from far back)
        // big files shouldn't stop to load (a phone's memory: ~0.5 GB ahead)
        // the buffer: on the iPhone's storage (not in memory), big enough for 5 minutes of a 4K remux, reading
        // 10 minutes ahead of where you are
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("player", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        opt("cache", "yes"); opt("cache-on-disk", "yes"); opt("cache-dir", cacheDir.path)
        opt("demuxer-cache-dir", cacheDir.path)   // (v1.17.26: newer mpv names it this — without it the buffer couldn't go on the disk)
        // v1.9.6: the whole episode loads while you watch, as much as the iPhone has room for (leaving 3 GB free)
        let gib: Int64 = 1 << 30
        let free = Prefetch.freeBytes()
        let maxBytes = max(gib, min(24 * gib, free - 3 * gib))
        self.maxBytes = maxBytes; self.freeAtStart = free
        opt("demuxer-max-bytes", "\(maxBytes >> 20)MiB"); opt("demuxer-max-back-bytes", "512MiB")
        opt("demuxer-readahead-secs", "86400"); opt("cache-secs", "86400"); opt("network-timeout", "60")
        // v1.9.6: fewer stops to load — bigger network reads, and after a stop it gathers 8 s before going on
        opt("stream-buffer-size", "4MiB"); opt("cache-pause-wait", "2")   // (v1.16.35: a stall waits 2 s, not 8)
        opt("stream-lavf-o", "reconnect=1,reconnect_streamed=1,reconnect_on_network_error=1,reconnect_on_http_error=5xx,reconnect_delay_max=5,multiple_requests=1")
        // subtitles and audio in your languages (Aperature's settings for this profile and show)
        if let sl = job.sl, sl == "-" { opt("sid", "no") }
        else if let sl = job.sl, !sl.isEmpty { opt("slang", sl + ((job.sa ?? "").isEmpty || (job.sa ?? "").contains("eng") ? ",en,eng" : "")) }   // (v1.14.0: English fallback only when it's one of the profile's)
        if let al = job.al, !al.isEmpty { opt("alang", al) }
        opt("subs-with-matching-audio", "yes")   // (v1.17.23: English subtitles with English audio — mpv left them off, or showed only signs)
        opt("subs-fallback", "yes"); opt("sub-font-size", "46"); opt("sub-border-size", "2.5")
        // v1.9.8: the profile's subtitle look (Aperature › Profile)
        if let ss = job.ss, let fs = ["s": "38", "m": "46", "l": "54", "xl": "64"][ss] { opt("sub-font-size", fs) }
        for (k, v) in MPV.subLook(sc: job.sc, sb: job.sb, so: job.so ?? 100) { opt(k, v) }
        opt("volume-max", "400"); if let vb = job.vb, vb > 100, vb <= 400 { opt("volume", String(vb)); opt("af", MPV.theaterFilter(vb, eq: job.be)) }   // v1.13.2: Boost's theater sound (v1.17.4: or the profile's own)
        opt("keep-open", job.an == 0 ? "always" : "yes");   // (v1.12.5: autoplay off: each episode stops at its end) opt("idle", "yes"); opt("ytdl", "no"); opt("input-default-bindings", "no")
        opt("audio-client-name", "Aperature")
        mpv_request_log_messages(h, "no")
        mpv_initialize(h)
        mpv_observe_property(h, 1, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(h, 2, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(h, 3, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(h, 4, "paused-for-cache", MPV_FORMAT_FLAG)
        mpv_observe_property(h, 5, "playlist-pos", MPV_FORMAT_INT64)
        mpv_observe_property(h, 6, "eof-reached", MPV_FORMAT_FLAG)
        mpv_observe_property(h, 7, "video-params/sig-peak", MPV_FORMAT_DOUBLE)
        mpv_set_wakeup_callback(h, { ctx in
            guard let ctx else { return }
            Unmanaged<MPV>.fromOpaque(ctx).takeUnretainedValue().drain()
        }, Unmanaged.passUnretained(self).toOpaque())

        // the playlist: the file, then the next episodes; each with its own title and start
        for (i, it) in job.items.enumerated() {
            var o: [String] = []
            if let s = it.s, s > 0 { o.append("start=\(Int(s))") }
            if let t = it.t, !t.isEmpty { o.append("force-media-title=%\(t.utf8.count)%\(t)") }
            command(["loadfile", mapUrl?(it.u) ?? it.u, i == 0 ? "replace" : "append", "-1", o.joined(separator: ",")])   // (v1.0.80 (iOS): through FastLoad)
        }
        // v1.0.80 (iOS): nothing shown 20 s after an entry started through the loader: from its own address instead
        if mapUrl != nil {
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 5, repeating: 5)
            t.setEventHandler { [weak self] in
                guard let self, self.handle != nil, !self.halted, !self.entryPlayed, let s = self.startedAt, Date().timeIntervalSince(s) > 20 else { return }
                self.startedAt = nil
                _ = self.direct(self.playlistPos)
            }
            t.resume()
            startWatch = t
        }
    }

    // v1.0.80 (iOS): entry i once more, straight from its own address, where it is in the playlist (on `queue`)
    private func direct(_ i: Int) -> Bool {
        guard mapUrl != nil, i >= 0, i < job.items.count, i < directTried.count, !directTried[i] else { return false }
        directTried[i] = true
        MPV.loaderLock.lock()
        MPV.fallbacks += 1
        if MPV.fallbacks >= 2 { MPV.loaderOffNow = true }
        MPV.loaderLock.unlock()
        let it = job.items[i]
        var o: [String] = []
        let pos = position
        if i == 0, let s = it.s, s > 0, pos < 1 { o.append("start=\(Int(s))") }
        else if pos > 1 { o.append("start=\(Int(pos))") }
        if let t = it.t, !t.isEmpty { o.append("force-media-title=%\(t.utf8.count)%\(t)") }
        command(["loadfile", it.u, "insert-at-play", String(i), o.joined(separator: ",")])
        command(["playlist-remove", String(i + 1)])
        return true
    }

    // v1.0.58: entry i from another address (this account's PC, or back to the source), where it is — also after mpv gave
    // up on it. `direct` addresses go through the several-connections loader, as at the start.
    func reroute(_ i: Int, url: String, viaPC: Bool, at pos: Double) {
        queue.async { [weak self] in
            guard let self, self.handle != nil, i >= 0, i < self.job.items.count else { return }
            self.halted = false
            self.entryPlayed = false
            var o: [String] = []
            if pos > 1 { o.append("start=\(Int(pos))") }
            if let t = self.job.items[i].t, !t.isEmpty { o.append("force-media-title=%\(t.utf8.count)%\(t)") }
            let u = viaPC ? url : (self.mapUrl?(url) ?? url)
            self.command(["loadfile", u, "insert-at-play", String(i), o.joined(separator: ",")])
            self.command(["playlist-remove", String(i + 1)])
        }
    }
    // when the last jump was (a load right after one is the jump, not a stop to load)
    private(set) var seekedAt = Date.distantPast

    // ---- options and properties
    private func opt(_ name: String, _ value: String) { if let h = handle { mpv_set_option_string(h, name, value) } }
    private func set<T>(_ name: String, int64 ref: inout T) { if let h = handle { withUnsafeMutablePointer(to: &ref) { mpv_set_option(h, name, MPV_FORMAT_INT64, $0) } } }

    func setFlag(_ name: String, _ on: Bool) {
        guard let h = handle else { return }
        var v: Int32 = on ? 1 : 0
        mpv_set_property(h, name, MPV_FORMAT_FLAG, &v)
    }
    // v1.12.5: the profile's subtitle look as mpv options: colour, box / outline, and opacity (every colour's alpha)
    // v1.13.2: Boost's theater sound at a level (101–400): deep bass, clearer voices, a compressor that lifts quiet
    // dialogue and holds the loud parts, a limiter — more of each the further past 100 it goes. "" = the file as it is.
    static func theaterFilter(_ level: Int, eq: String? = nil) -> String {
        if level <= 100 { return "" }
        if let tuned = tunedFilter(level, eq) { return tuned }   // v1.17.4
        let t = min(1.0, Double(level - 100) / 300.0)
        func f(_ v: Double) -> String { String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), v) }
        // v1.17.2: this app's player (MPVKit 1.0.0) is built with only FFmpeg's equalizer filters — lowshelf, bass, treble,
        // acompressor and alimiter aren't in it, so the theater chain before this never ran here (mpv dropped it and Boost
        // was just louder). What it can do: the detail — where a chain's clink or glass sits (6 kHz) and the air above
        // 9.5 kHz — with firequalizer, which it has. Measured on a test clip at 300%: the small high sounds ~3 dB clearer.
        let d = f(1 + 3 * t), a = f(1.5 + 2.25 * t)
        return "lavfi=[firequalizer=gain_entry='entry(0,0);entry(4000,0);entry(6000,\(d));entry(9500,\(a));entry(20000,\(a))']"
    }

    // v1.17.4: the profile's own Boost (Settings › Sound › Tune your Boost), from the job's be: "b1,…,b7,detail,even" —
    // the seven bands (dB, ±12) as they play at 300%, then Detail and Even out (0–100). At a level every band is
    // × (level − 100) / 200 (±15 dB at most), so 200% is half and 400% one and a half times; Detail the same way. This
    // player has no compressor (see above), so Even out isn't heard here: the bands and the detail (more at 6 kHz and in
    // the air above 9.5 kHz, 3 dB at 50 like Theater at 300%) are one firequalizer. nil = no tuning we can read: Theater.
    static func tunedFilter(_ level: Int, _ be: String?) -> String? {
        guard level > 100, let be else { return nil }
        let p = be.split(separator: ",", omittingEmptySubsequences: false).map { Double($0) }
        guard p.count == 9, p.allSatisfy({ ($0 ?? .nan).isFinite }) else { return nil }
        let v = p.map { $0 ?? 0 }
        let k = min(1.5, Double(level - 100) / 200)
        func f(_ x: Double) -> String { String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), x + 0) }
        let g = (0..<7).map { max(-15, min(15, max(-12, min(12, v[$0])) * k)) }
        let d = max(0, min(100, v[7])) * k / 100 * 6
        let air = g[5] + (g[6] - g[5]) * 3500 / 9000   // (the bands' line at 9.5 kHz, between 6 and 15 kHz)
        let pts: [(Int, Double)] = [(0, g[0]), (60, g[0]), (150, g[1]), (400, g[2]), (1000, g[3]), (2400, g[4]), (6000, g[5] + d), (9500, air + d), (15000, g[6] + d), (20000, g[6] + d)]
        return "lavfi=[firequalizer=gain_entry='" + pts.map { "entry(\($0.0),\(f($0.1)))" }.joined(separator: ";") + "']"
    }

    static func subLook(sc: String?, sb: String?, so: Int) -> [(String, String)] {
        let op = so >= 25 && so <= 100 ? Double(so) / 100 : 1
        func a(_ full: Int) -> String { String(format: "%02X", Int((Double(full) * op).rounded())) }
        var rgb = "FFFFFF"
        if let sc, sc.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil { rgb = String(sc.dropFirst()).uppercased() }
        var o: [(String, String)] = [("sub-color", "#" + a(255) + rgb)]
        switch sb ?? "box" {
        case "solid": o += [("sub-border-style", "opaque-box"), ("sub-border-color", "#" + a(255) + "000000"), ("sub-shadow-offset", "0")]
        case "plain": o += [("sub-border-style", "outline-and-shadow"), ("sub-border-size", "0"), ("sub-shadow-offset", "1"), ("sub-shadow-color", "#" + a(0x80) + "000000")]   // v1.13.4: just the words
        case "none": o += [("sub-border-style", "outline-and-shadow"), ("sub-border-size", "3"), ("sub-shadow-offset", "1.5"), ("sub-border-color", "#" + a(255) + "000000"), ("sub-shadow-color", "#" + a(0xC0) + "000000")]
        default: o += [("sub-border-style", "background-box"), ("sub-back-color", "#" + a(0x9E) + "000000"), ("sub-border-size", "2")]
        }
        return o
    }
    func setString(_ name: String, _ value: String) { if let h = handle { mpv_set_property_string(h, name, value) } }
    func getString(_ name: String) -> String? {
        guard let h = handle, let c = mpv_get_property_string(h, name) else { return nil }
        defer { mpv_free(c) }
        return String(cString: c)
    }
    func getInt(_ name: String) -> Int { Int(getString(name) ?? "") ?? 0 }

    func command(_ args: [String]) {
        guard let h = handle else { return }
        var cargs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) }
        cargs.append(nil)
        defer { for p in cargs where p != nil { free(UnsafeMutablePointer(mutating: p!)) } }
        mpv_command(h, &cargs)
    }

    // ---- what the screen does
    func togglePause() { setFlag("pause", !(getString("pause") == "yes")) }
    func seek(by s: Double) { command(["seek", String(s), "relative+exact"]) }
    func seek(to s: Double) { command(["seek", String(s), "absolute+keyframes"]) }
    func next() { command(["playlist-next", "force"]) }
    // v1.9.6: a downloaded episode takes its place in the playlist (append, move into place, drop the address it replaces)
    func replaceEntry(_ index: Int, path: String, title: String?) {
        let count = getInt("playlist-count")
        guard index > playlistPos, index < count else { return }
        var o = ""
        if let t = title, !t.isEmpty { o = "force-media-title=%\(t.utf8.count)%\(t)" }
        command(["loadfile", path, "append", "-1", o])
        command(["playlist-move", String(count), String(index)])
        command(["playlist-remove", String(index + 1)])
    }

    var hasNext: Bool { playlistPos + 1 < getInt("playlist-count") }

    func tracks() -> [Track] {
        let n = getInt("track-list/count")
        return (0..<max(0, n)).compactMap { i in
            let type = getString("track-list/\(i)/type") ?? ""
            guard type == "audio" || type == "sub" else { return nil }
            return Track(id: getInt("track-list/\(i)/id"), type: type, title: getString("track-list/\(i)/title") ?? "",
                         lang: getString("track-list/\(i)/lang") ?? "", selected: getString("track-list/\(i)/selected") == "yes")
        }
    }
    func select(_ t: Track?, type: String) { setString(type == "sub" ? "sid" : "aid", t.map { String($0.id) } ?? "no") }

    // ---- events (mpv's thread → ours → the screen's)
    private func drain() {
        queue.async { [weak self] in
            guard let self, let h = self.handle else { return }
            while true {
                guard let ev = mpv_wait_event(h, 0) else { break }
                let e = ev.pointee
                if e.event_id == MPV_EVENT_NONE { break }
                switch e.event_id {
                case MPV_EVENT_PROPERTY_CHANGE:
                    guard let raw = e.data else { continue }
                    let prop = raw.assumingMemoryBound(to: mpv_event_property.self).pointee
                    let name = String(cString: prop.name)
                    let data = prop.data
                    switch (name, prop.format) {
                    case ("time-pos", MPV_FORMAT_DOUBLE):
                        if !self.halted {
                            if let d = data { self.position = d.assumingMemoryBound(to: Double.self).pointee; self.everPlayed = true; self.entryPlayed = true }
                            let p = self.position, du = self.duration
                            DispatchQueue.main.async { self.delegate?.mpvTime(p, du) }
                        }
                    case ("duration", MPV_FORMAT_DOUBLE):
                        if let d = data { self.duration = d.assumingMemoryBound(to: Double.self).pointee }
                    case ("pause", MPV_FORMAT_FLAG):
                        let v = data.map { $0.assumingMemoryBound(to: Int32.self).pointee != 0 } ?? false
                        DispatchQueue.main.async { self.delegate?.mpvPaused(v) }
                    case ("paused-for-cache", MPV_FORMAT_FLAG):
                        let v = data.map { $0.assumingMemoryBound(to: Int32.self).pointee != 0 } ?? false
                        DispatchQueue.main.async { self.delegate?.mpvBuffering(v) }
                    case ("playlist-pos", MPV_FORMAT_INT64):
                        // v1.0.71 (iOS): a new entry starts from nothing — the last one's time and length stayed until the
                        // new file's first time-pos (closing then saved the new episode at the old one's position; the
                        // stuck-loading check "kicked" the new file to the old one's time)
                        if let d = data, !self.halted {
                            let i = Int(d.assumingMemoryBound(to: Int64.self).pointee)
                            if i >= 0 {
                                if i != self.playlistPos { self.position = 0; self.duration = 0 }
                                self.playlistPos = i
                                DispatchQueue.main.async { self.delegate?.mpvFile(i) }
                            }
                        }
                    case ("eof-reached", MPV_FORMAT_FLAG):
                        let v = data.map { $0.assumingMemoryBound(to: Int32.self).pointee != 0 } ?? false
                        // the last file played to its end (keep-open holds it): done
                        if v && !self.hasNext { DispatchQueue.main.async { self.delegate?.mpvEnded(error: false) } }
                    case ("video-params/sig-peak", MPV_FORMAT_DOUBLE):
                        // HDR on a screen that shows it: let the picture through as HDR
                        if let d = data, d.assumingMemoryBound(to: Double.self).pointee > 1.0 {
                            DispatchQueue.main.async { if (UIScreen.main.potentialEDRHeadroom) > 1.0 { self.layerRef.wantsExtendedDynamicRangeContent = true } }
                        }
                    default: break
                    }
                case MPV_EVENT_SEEK:
                    self.seekedAt = Date()
                case MPV_EVENT_START_FILE:
                    // v1.0.71 (iOS): each entry starts unplayed the moment mpv starts it (the playlist-pos change can land
                    // after this entry has already ended)
                    if self.halted { break }
                    self.entryPlayed = false
                    self.startedAt = Date()   // v1.0.80 (iOS)
                    if let s = self.getString("playlist-pos"), let i = Int(s), i >= 0, i != self.playlistPos {
                        self.playlistPos = i; self.position = 0; self.duration = 0
                    }
                case MPV_EVENT_END_FILE:
                    if let raw = e.data, !self.halted {
                        let end = raw.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                        // v1.0.71 (iOS): an entry that won't load stops here with its error. Before, only when nothing had
                        // ever played and it was the last: a later episode that failed was skipped silently (mpv went on
                        // to the next, and the next), and a failed last one left a black screen with nothing reported.
                        // v1.0.80 (iOS): …but first once more, straight from its own address (it may be the loader that
                        // couldn't start it)
                        if end.reason == MPV_END_FILE_REASON_ERROR && !self.entryPlayed && self.direct(self.playlistPos) {
                            // (playing again from its own address)
                        } else if end.reason == MPV_END_FILE_REASON_ERROR && !self.entryPlayed {
                            self.halted = true
                            self.command(["stop"])
                            DispatchQueue.main.async { self.delegate?.mpvEnded(error: true) }
                        }
                    }
                case MPV_EVENT_SHUTDOWN:
                    return
                default:
                    break
                }
            }
        }
    }

    // v1.16.34: back from another app (Messages, say) after a while: iOS has closed the connection the file came
    // over, so it never started again — it's opened again right where you were (still paused)
    private var bgPos: Double = -1
    private var bgAt: Date?
    func pauseForBackground(_ bg: Bool) {
        if bg {
            bgPos = position; bgAt = Date()
            setFlag("pause", true); setString("vid", "no")
        } else {
            // v1.0.80 (iOS): the loader keeps serving while the app plays in the background (nothing closes it there); if
            // iOS took its socket away while the app was suspended, it's open again (same port) before mpv reads on
            if mapUrl != nil { FastLoad.wake() }
            setString("vid", "auto")
            let away = bgAt.map { Date().timeIntervalSince($0) } ?? 0
            bgAt = nil
            // v1.0.71 (iOS): where it is now, not where it was when the app went away — played on from the lock screen /
            // AirPods in the background, coming back jumped back to the spot it was left at
            if away > 10 && bgPos > 0 && position > 0 { command(["seek", String(format: "%.3f", position), "absolute+exact"]) }
        }
    }
    // v1.16.34: playing but stuck loading: the same spot asked for again (a fresh connection)
    func kick() { if position > 0 { command(["seek", String(format: "%.3f", position), "absolute+exact"]) } }

    // stop and free it (on its own thread, after the last events)
    func destroy() {
        guard let h = handle else { return }
        handle = nil
        startWatch?.cancel(); startWatch = nil   // v1.0.80 (iOS)
        // v1.0.71 (iOS): mpv holds this object unretained (its wakeup callback) and the layer as a raw pointer (wid). The
        // player let go of this object straight after destroy(), so a time-pos wakeup before mpv_terminate_destroy ran
        // reached freed memory (a crash on close / Next), and the picture could still draw into a freed layer. Now: no
        // more wakeups, and this object (with its layer) lives until mpv has let go, then is released on the main thread.
        mpv_set_wakeup_callback(h, nil, nil)
        queue.async { [self] in
            mpv_terminate_destroy(h)
            DispatchQueue.main.async { withExtendedLifetime(self) {} }
        }
    }
}
