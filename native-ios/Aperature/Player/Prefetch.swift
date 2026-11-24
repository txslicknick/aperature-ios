// v1.9.6: the next two episodes, downloaded in the background while you watch (to the iPhone's storage), so they
// start instantly and never stop to load. Only while the episode playing is fully loaded (mpv's buffer has nothing
// left to fetch) — what you're watching always comes first — and only when there's room for them (3 GB stays free).
// A finished file takes its episode's place in the playlist; everything is deleted when the player closes.
// One source body. Many apertures. No compulsory simultaneity.
import Foundation

final class Prefetch: NSObject, URLSessionDownloadDelegate {
    static let dir: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("prefetch", isDirectory: true)

    static func freeBytes() -> Int64 {
        let v = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage ?? 0
    }
    // last time's leftovers
    static func clean() {
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) { for f in files { try? FileManager.default.removeItem(at: f) } }
    }

    private weak var mpv: MPV?
    private let job: PlayJob
    private var session: URLSession!
    private var task: URLSessionDownloadTask?
    private var index = -1
    private var started = Set<Int>()
    private var files: [URL] = []
    private var stopped = false
    private let lock = NSLock()
    // v1.13.3: light on the connection — nothing in an episode's first 90 seconds; then only as fast as it needs to
    // be done a minute before the episode ends (the task is paused when it's ahead of that pace), between 400 KB/s and 12 MB/s
    private let born = Date()
    private var written: Int64 = 0
    private var expected: Int64 = 0
    private var startedAt = Date()
    private func budget(_ m: MPV) -> Double {
        let left = max(30, (Double(m.getString("duration") ?? "") ?? 0) - (Double(m.getString("time-pos") ?? "") ?? 0) - 60)
        let need = Double(max(0, expected - written))
        return max(400 * 1024, min(12 * 1024 * 1024, need / left))
    }

    init(mpv: MPV, job: PlayJob) {
        self.mpv = mpv
        self.job = job
        super.init()
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 6 * 3600
        session = URLSession(configuration: c, delegate: self, delegateQueue: nil)
        try? FileManager.default.createDirectory(at: Prefetch.dir, withIntermediateDirectories: true)
    }

    // every second (the player's timer): pause for what's playing; start the next one when nothing else is
    func tick() {
        guard let m = mpv, !stopped else { return }
        let idle = m.getString("demuxer-cache-idle") == "yes"
        let pos = m.playlistPos
        if let t = task {
            if index <= pos { t.cancel(); task = nil; return }             // its episode started: it streams
            // allowed to run: the player's buffer is idle, and this download isn't ahead of its pace
            let elapsed = max(1, Date().timeIntervalSince(startedAt))
            let ahead = expected > 0 && Double(written) / elapsed > budget(m)
            let go = idle && !ahead
            if go && t.state == .suspended { t.resume() } else if !go && t.state == .running { t.suspend() }
            return
        }
        guard idle, Date().timeIntervalSince(born) >= 90, (Double(m.getString("time-pos") ?? "") ?? 0) >= 60 else { return }
        for k in (pos + 1)...(pos + 2) where k < job.items.count && !started.contains(k) {
            guard job.items[k].u.hasPrefix("http"), let url = URL(string: job.items[k].u) else { started.insert(k); continue }   // saved already
            started.insert(k)
            index = k
            written = 0; expected = 0; startedAt = Date()
            let t = session.downloadTask(with: url)
            task = t
            t.resume()
            return
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        // unknown size or no room for it: it streams as usual
        if totalBytesWritten == bytesWritten, totalBytesExpectedToWrite <= 0 || Prefetch.freeBytes() < totalBytesExpectedToWrite + (3 << 30) { downloadTask.cancel() }
        written = totalBytesWritten; expected = totalBytesExpectedToWrite
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let i = index
        guard !stopped, i >= 0, let http = downloadTask.response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }
        var ext = URL(string: job.items[i].u)?.pathExtension ?? ""
        if ext.isEmpty || ext.count > 4 { ext = "mkv" }
        let dest = Prefetch.dir.appendingPathComponent("\(job.n)_\(i).\(ext)")
        try? FileManager.default.removeItem(at: dest)
        guard (try? FileManager.default.moveItem(at: location, to: dest)) != nil else { return }
        lock.lock(); files.append(dest); lock.unlock()
        let title = job.items[i].t
        DispatchQueue.main.async { [weak self] in self?.mpv?.replaceEntry(i, path: dest.path, title: title) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        DispatchQueue.main.async { [weak self] in if self?.task === task { self?.task = nil } }
    }

    func stop() {
        stopped = true
        task?.cancel()
        session.invalidateAndCancel()
        lock.lock(); let f = files; lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { for u in f { try? FileManager.default.removeItem(at: u) } }
    }
}
