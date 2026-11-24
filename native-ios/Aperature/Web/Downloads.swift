// v1.12: "Save in Aperature" downloads made by the app itself. The page can't save most streams (their hosts don't
// allow web pages to read them: "This stream's host doesn't allow saving inside apps"); the app has no such limit.
//   web → app:  { type: 'download', id, url, name } · { type: 'download-cancel', id } · { type: 'download-delete', id }
//               { type: 'download-keep', ids: [...] }   (files not on this list and not downloading are deleted)
//   app → web:  window.__apDl({ id, got, total }) while saving, then { id, done: true, size } or { id, error } or { id, cancelled: true }
// A saved file plays as "apdl:<id>" in a play job (PlayJob turns it into the file on this iPhone).
// One source body. Many apertures. No compulsory simultaneity.
import Foundation
import UIKit

final class Downloads: NSObject, URLSessionDownloadDelegate {
    static let shared = Downloads()
    static let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        var v = URLResourceValues(); v.isExcludedFromBackup = true
        var dd = d; try? dd.setResourceValues(v)
        return d
    }()

    static func validId(_ id: String) -> Bool { id.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil }

    // the saved file for an id (any extension)
    static func file(id: String) -> URL? {
        guard validId(id), let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        return files.first { $0.lastPathComponent.hasPrefix(id + ".") && !$0.lastPathComponent.hasSuffix(".part") }
    }

    var send: (([String: Any]) -> Void)?
    private var session: URLSession!
    private let lock = NSLock()
    private var byId: [String: URLSessionDownloadTask] = [:]
    private var byTask: [Int: (id: String, ext: String)] = [:]
    private var reported: Set<Int> = []       // tasks that already said how they ended
    private var lastSent: [Int: Date] = [:]
    private var bg: UIBackgroundTaskIdentifier = .invalid

    override init() {
        super.init()
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 24 * 3600
        c.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: c, delegate: self, delegateQueue: OperationQueue())
    }

    private func post(_ m: [String: Any]) { DispatchQueue.main.async { self.send?(m) } }

    func start(id: String, url: String, name: String) {
        guard Downloads.validId(id), let u = URL(string: url), let sch = u.scheme?.lowercased(), sch == "http" || sch == "https" else {
            post(["id": id, "error": "That stream can't be saved."]); return
        }
        var ext = (name as NSString).pathExtension.lowercased()
        if ext.isEmpty || ext.count > 5 || ext.range(of: "^[a-z0-9]+$", options: .regularExpression) == nil { ext = u.pathExtension.lowercased() }
        if ext.isEmpty || ext.count > 5 || ext.range(of: "^[a-z0-9]+$", options: .regularExpression) == nil { ext = "mkv" }
        let t = session.downloadTask(with: u)
        lock.lock(); byId[id] = t; byTask[t.taskIdentifier] = (id, ext); lock.unlock()
        holdBackground()
        t.resume()
    }

    func cancel(id: String) {
        lock.lock(); let t = byId[id]; lock.unlock()
        t?.cancel()
    }

    func delete(id: String) {
        cancel(id: id)
        if let f = Downloads.file(id: id) { try? FileManager.default.removeItem(at: f) }
    }

    // everything the page no longer knows about (and isn't downloading) goes
    func keep(ids: [String]) {
        let keep = Set(ids)
        lock.lock(); let running = Set(byId.keys); lock.unlock()
        guard let files = try? FileManager.default.contentsOfDirectory(at: Downloads.dir, includingPropertiesForKeys: nil) else { return }
        for f in files {
            let id = String(f.lastPathComponent.split(separator: ".").first ?? "")
            if !keep.contains(id) && !running.contains(id) { try? FileManager.default.removeItem(at: f) }
        }
    }

    // a few more minutes when Aperature goes to the background mid-download
    private func holdBackground() {
        DispatchQueue.main.async {
            guard self.bg == .invalid else { return }
            self.bg = UIApplication.shared.beginBackgroundTask(withName: "Aperature downloads") { [weak self] in self?.releaseBackground() }
        }
    }
    private func releaseBackground() {
        DispatchQueue.main.async {
            guard self.bg != .invalid else { return }
            UIApplication.shared.endBackgroundTask(self.bg)
            self.bg = .invalid
        }
    }

    private func finish(_ task: URLSessionTask, _ msg: [String: Any]) {
        lock.lock()
        let first = reported.insert(task.taskIdentifier).inserted
        if let e = byTask[task.taskIdentifier] { byId[e.id] = nil }
        let none = byId.isEmpty
        lock.unlock()
        if first { post(msg) }
        if none { releaseBackground() }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        lock.lock(); let e = byTask[downloadTask.taskIdentifier]; let last = lastSent[downloadTask.taskIdentifier]; lock.unlock()
        guard let e else { return }
        if totalBytesWritten == bytesWritten, totalBytesExpectedToWrite > 0, Prefetch.freeBytes() < totalBytesExpectedToWrite + (1 << 30) {
            finish(downloadTask, ["id": e.id, "error": "Not enough free space on this iPhone for that download (\(ByteCountFormatter.string(fromByteCount: totalBytesExpectedToWrite, countStyle: .file)))."])
            downloadTask.cancel()
            return
        }
        if let last, Date().timeIntervalSince(last) < 0.5 { return }
        lock.lock(); lastSent[downloadTask.taskIdentifier] = Date(); lock.unlock()
        post(["id": e.id, "got": totalBytesWritten, "total": max(totalBytesExpectedToWrite, 0)])
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        lock.lock(); let e = byTask[downloadTask.taskIdentifier]; lock.unlock()
        guard let e else { return }
        let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            finish(downloadTask, ["id": e.id, "error": code == 401 || code == 403 ? "The stream's host refused the download (HTTP \(code))." : "Download failed (HTTP \(code))."])
            return
        }
        let dest = Downloads.dir.appendingPathComponent("\(e.id).\(e.ext)")
        try? FileManager.default.removeItem(at: dest)
        do { try FileManager.default.moveItem(at: location, to: dest) } catch {
            finish(downloadTask, ["id": e.id, "error": "Not enough free space on this iPhone for that download."]); return
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.int64Value ?? 0
        let expected = downloadTask.countOfBytesExpectedToReceive
        if expected > 0 && size < expected {
            try? FileManager.default.removeItem(at: dest)
            finish(downloadTask, ["id": e.id, "error": "The download was cut off. Try again."]); return
        }
        finish(downloadTask, ["id": e.id, "done": true, "size": size, "ext": e.ext])
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let e = byTask[task.taskIdentifier]; lock.unlock()
        guard let e else { return }
        if let err = error as NSError? {
            if err.code == NSURLErrorCancelled { finish(task, ["id": e.id, "cancelled": true]) }
            else if err.code == NSURLErrorNotConnectedToInternet { finish(task, ["id": e.id, "error": "You're offline."]) }
            else { finish(task, ["id": e.id, "error": "The download stopped before it finished. Try again."]) }
        } else {
            finish(task, ["id": e.id, "error": "The download stopped before it finished. Try again."])   // only if nothing above answered
        }
        lock.lock(); byTask[task.taskIdentifier] = nil; lastSent[task.taskIdentifier] = nil; lock.unlock()
    }
}
