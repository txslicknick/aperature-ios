// Saved manga / comic chapters, kept by the app itself (v1.0.58). The page used to keep them in the web view's Cache
// Storage, which iOS may empty when the phone is short of space. Here they are files in Application Support, which iOS
// never clears; they go only when you remove them (or delete the app). Not backed up to iCloud (they can be saved again).
//
//   page → app:  await window.webkit.messageHandlers.apStore.postMessage({ op, url, type, data })
//     put { url, type, data (base64) } → true      match { url } → { type, data } | null
//     keys → [url]                                 delete { url } → true if it was there
//     free → bytes the phone can still take
// Only Aperature's own page (its main frame) is answered.
import Foundation
import WebKit
import CryptoKit

final class ChapterStore: NSObject, WKScriptMessageHandlerWithReply {
    static let shared = ChapterStore()
    private let q = DispatchQueue(label: "aperature.chapters", qos: .userInitiated)
    private var index: [String: String]?      // url → type, read from the folder once
    private let maxEntry = 40 * 1024 * 1024

    private lazy var dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var d = base.appendingPathComponent("offline-manga", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        var v = URLResourceValues()
        v.isExcludedFromBackup = true
        try? d.setResourceValues(v)
        return d
    }()

    private func name(_ url: String) -> String { SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func dataFile(_ url: String) -> URL { dir.appendingPathComponent(name(url) + ".bin") }
    private func metaFile(_ url: String) -> URL { dir.appendingPathComponent(name(url) + ".json") }

    // (an entry counts once its .json is there: it's written after the bytes, so a save cut off half way leaves nothing)
    private func loaded() -> [String: String] {
        if let i = index { return i }
        var out: [String: String] = [:]
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "json" {
            guard let d = try? Data(contentsOf: f), let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: String], let u = j["url"] else { continue }
            if FileManager.default.fileExists(atPath: dataFile(u).path) { out[u] = j["type"] ?? "" }
        }
        index = out
        return out
    }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        let origin = message.frameInfo.securityOrigin
        guard message.frameInfo.isMainFrame, origin.protocol == "https", origin.host == siteURL.host,
              let body = message.body as? [String: Any], let op = body["op"] as? String else { replyHandler(nil, "not allowed"); return }
        q.async {
            let (value, error) = self.handle(op, body)
            DispatchQueue.main.async { replyHandler(value, error) }
        }
    }

    private func handle(_ op: String, _ body: [String: Any]) -> (Any?, String?) {
        var all = loaded()
        if op == "keys" { return (Array(all.keys), nil) }
        if op == "free" {
            let v = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return (NSNumber(value: v?.volumeAvailableCapacityForImportantUsage ?? 0), nil)
        }
        guard let url = body["url"] as? String, !url.isEmpty, url.count < 4096 else { return (nil, "no address") }
        switch op {
        case "put":
            guard let b64 = body["data"] as? String, let bytes = Data(base64Encoded: b64), bytes.count <= maxEntry else { return (nil, "bad page") }
            let type = body["type"] as? String ?? ""
            do {
                try? FileManager.default.removeItem(at: metaFile(url))
                try bytes.write(to: dataFile(url), options: .atomic)
                try JSONSerialization.data(withJSONObject: ["url": url, "type": type]).write(to: metaFile(url), options: .atomic)
            } catch {
                try? FileManager.default.removeItem(at: dataFile(url))
                all[url] = nil; index = all
                return (nil, "The iPhone couldn’t save it (is it full?)")
            }
            all[url] = type; index = all
            return (true, nil)
        case "match":
            guard let type = all[url], let bytes = try? Data(contentsOf: dataFile(url)) else { return (NSNull(), nil) }
            return (["type": type, "data": bytes.base64EncodedString()], nil)
        case "delete":
            let had = all[url] != nil
            try? FileManager.default.removeItem(at: metaFile(url))
            try? FileManager.default.removeItem(at: dataFile(url))
            all[url] = nil; index = all
            return (had, nil)
        default:
            return (nil, "unknown")
        }
    }
}
