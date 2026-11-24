// v1.0.80 (iOS): files over several connections at once — the Windows app's FastLoad (v1.0.76 / v1.0.80), ported.
// A file's server often sends each connection slowly (debrid services cap one connection), so a fast line still "only
// gave" a few Mbps and the player kept stopping to load. This hands mpv the file from 127.0.0.1, in order, while 4
// connections fetch the next pieces of it side by side — the way download managers do. Nothing is written to disk: a
// few pieces ahead are kept in memory. A server that doesn't take ranges is passed straight through on one connection.
//
// Only Foundation + Network (no UIKit), so the same file is built into the app and into the Mac test
// (../../FastLoadTest, run by the iOS workflow before the app is built).
//
// Threads: everything here — the listener, every player connection, every URLSession callback — runs on one serial
// queue (`FLCore.q`). Only map / isMapped / wake are called from outside, and they hop onto it.
//
// In the background: the listener lives for as long as the app does — nothing here tears it down when the app leaves
// the screen, so while the app plays (the audio background mode) mpv keeps reading through it. If iOS takes its socket
// away while the app was suspended, it opens again by itself on the same port (and `wake()` on coming back to the front
// makes sure), so the addresses already in mpv's playlist keep working.
// One source body. Many apertures. No compulsory simultaneity.
import Foundation
import Network

enum FastLoad {
    static let connections = 4
    static let piece = 2 * 1024 * 1024        // (2 MB pieces; the first one 512 KB, to start quickly)
    static let firstPiece = 512 * 1024
    static let ahead = 12                      // (pieces kept ahead of the player: about 24 MB)

    /// The address mpv is given for a file: the same file through here (http(s) only; anything else is returned as it is,
    /// and so is the address itself if the loader can't start). Never call from FastLoad's own queue.
    static func map(_ url: String) -> String { core.map(url) }
    static func isMapped(_ url: String) -> Bool { core.isMapped(url) }
    /// The app is back in front: the listener is open again if iOS took it away (same port when it can).
    static func wake() { core.wake() }

    fileprivate static let core = FLCore()
}

// ---- a file mpv was given
fileprivate final class FLSource {
    let url: URL
    var length: Int64 = -1          // -1: not known yet
    var ranges = false              // the server sends pieces (206)
    var type = "application/octet-stream"
    var conns = FastLoad.connections   // (fewer when the server says too many)
    var probed = false
    var probing = false
    var waiters: [(String?) -> Void] = []
    var head: Data?                 // (the file's first piece, fetched with the first look at it)
    var failure: String?            // (the server wouldn't answer: why)
    init(url: URL) { self.url = url }
}

// ---- one request to a file's server (URLSession, streamed through FLCore's delegate)
fileprivate final class FLFetch {
    let task: URLSessionDataTask
    let slot: Int
    // (false from onResponse / onData: the fetch is let go, and onDone isn't called — the owner has already acted)
    var onResponse: (HTTPURLResponse?) -> Bool
    var onData: (Data) -> Bool
    var onDone: (Error?) -> Void
    var seen = false, cancelled = false, suspended = false
    init(task: URLSessionDataTask, slot: Int, onResponse: @escaping (HTTPURLResponse?) -> Bool, onData: @escaping (Data) -> Bool, onDone: @escaping (Error?) -> Void) {
        self.task = task; self.slot = slot; self.onResponse = onResponse; self.onData = onData; self.onDone = onDone
    }
    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        if suspended { suspended = false; task.resume() }
        task.cancel()
    }
    func suspend() { if !suspended && !cancelled { suspended = true; task.suspend() } }
    func resume() { if suspended { suspended = false; task.resume() } }
}

fileprivate final class FLProbe {
    var buf = Data()
    var want = 0
    var done = false
    var fetch: FLFetch?
}

fileprivate final class FLAttempt {
    let want: Int
    var buf = Data()
    var settled = false
    var fetch: FLFetch?
    init(want: Int) { self.want = want; buf.reserveCapacity(want) }
}

// ---- a request from the player
fileprivate struct FLRequest {
    var method = "", path = ""
    var from: Int64 = -1, to: Int64 = -1
    var close = false
    init?(_ head: String) {
        let lines = head.components(separatedBy: "\r\n")
        guard let line0 = lines.first else { return nil }
        let first = line0.split(separator: " ")
        guard first.count >= 2 else { return nil }
        method = first[0].uppercased()
        path = String(first[1])
        for ln in lines.dropFirst() {
            guard let colon = ln.firstIndex(of: ":"), colon != ln.startIndex else { continue }
            let name = ln[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let val = ln[ln.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name == "range" && val.lowercased().hasPrefix("bytes=") {
                let spec = val.dropFirst(6).split(separator: ",", omittingEmptySubsequences: false).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                if let dash = spec.firstIndex(of: "-"), dash != spec.startIndex {
                    if let a = Int64(spec[..<dash]) { from = a }
                    let rest = spec[spec.index(after: dash)...]
                    if !rest.isEmpty, let b = Int64(rest) { to = b }
                }
            } else if name == "connection" && val.lowercased() == "close" {
                close = true
            }
        }
    }
}

// ---- one connection from the player (it may ask for several ranges, one after another)
fileprivate final class FLClient {
    let core: FLCore
    let conn: NWConnection
    var inbuf = Data()
    var busy = false        // answering a request
    var closed = false      // no more requests are taken
    var dead = false        // the connection is gone
    var onGone: (() -> Void)?
    var onDrain: (() -> Void)?
    var pump: FLPump?
    var passFetch: FLFetch?
    var inflight = 0        // bytes handed to the connection and not yet taken by it

    init(core: FLCore, conn: NWConnection) { self.core = core; self.conn = conn }

    // always one read waiting: the next request — and, while a file goes out, the player going away (it jumped, or
    // closed: its connection reads as finished)
    func read() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, !self.dead else { return }
            if let data, !data.isEmpty { self.inbuf.append(data) }
            if isComplete || error != nil { self.gone(); return }
            if self.inbuf.count > 1 << 20 { self.gone(); return }
            if !self.busy && !self.closed { self.next() }
            if !self.dead { self.read() }
        }
    }

    func next() {
        guard !busy, !closed, !dead else { return }
        guard let r = inbuf.range(of: Data([13, 10, 13, 10])) else {
            if inbuf.count >= 16384 { gone() }
            return
        }
        let head = String(decoding: inbuf[inbuf.startIndex..<r.lowerBound], as: UTF8.self)
        inbuf = Data(inbuf[r.upperBound...])
        guard let req = FLRequest(head) else { gone(); return }
        busy = true
        core.answer(req, self)
    }

    func send(_ d: Data, _ done: ((Bool) -> Void)? = nil) {
        guard !dead else { done?(false); return }
        inflight += d.count
        let n = d.count
        conn.send(content: d, completion: .contentProcessed { [weak self] err in
            guard let self else { done?(false); return }
            self.inflight -= n
            if err != nil { done?(false); self.gone(); return }
            done?(!self.dead)
            if self.inflight < 1 << 20, let dr = self.onDrain { dr() }
        })
    }

    // this answer is done: the next request on the same connection, or a clean close
    func finish(keep: Bool) {
        busy = false
        onGone = nil; onDrain = nil; pump = nil; passFetch = nil
        if closed || dead { return }
        if keep { next() } else { end() }
    }

    // a clean close: what was sent goes out first
    func end() {
        guard !closed, !dead else { return }
        closed = true
        conn.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.conn.cancel()
        })
        // (a player that never reads the rest: let go after a while anyway)
        core.q.asyncAfter(deadline: .now() + 30) { [weak self] in self?.conn.cancel() }
    }

    // the player went away (or the connection failed): everything for it is let go at once
    func gone() {
        let first = !dead
        dead = true; closed = true
        if first {
            let g = onGone
            onGone = nil; onDrain = nil
            g?()   // (before the pump is let go: it cancels its pieces)
            pump = nil
            passFetch?.cancel(); passFetch = nil
        }
        conn.cancel()
    }
}

// ---- the pieces: fetched side by side, handed over in order
fileprivate enum FLPieceState { case queued, active, ready(Data) }

fileprivate final class FLPump {
    let core: FLCore
    let src: FLSource
    let client: FLClient
    let from: Int64, to: Int64
    let count: Int
    var i = 0, next = 0, active = 0
    var pieces: [Int: FLPieceState] = [:]
    var attempts: [Int: FLAttempt] = [:]
    var writing = false, finished = false
    let done: (Bool) -> Void

    init(core: FLCore, src: FLSource, client: FLClient, from: Int64, to: Int64, done: @escaping (Bool) -> Void) {
        self.core = core; self.src = src; self.client = client; self.from = from; self.to = to; self.done = done
        let len = to - from + 1
        let fp = Int64(FastLoad.firstPiece), p = Int64(FastLoad.piece)
        count = len <= fp ? 1 : 1 + Int((len - fp + p - 1) / p)
    }

    func bounds(_ k: Int) -> (Int64, Int64) {
        let fp = Int64(FastLoad.firstPiece), p = Int64(FastLoad.piece)
        let a = k == 0 ? from : from + fp + Int64(k - 1) * p
        let b = min(to, (k == 0 ? from + fp : a + p) - 1)
        return (a, b)
    }

    func step() {
        guard !finished else { return }
        // keep up to `ahead` pieces fetching or fetched, from the one being handed over
        while next < count && next < i + FastLoad.ahead {
            let (a, b) = bounds(next)
            if let h = src.head, a < Int64(h.count), b < Int64(h.count) {
                pieces[next] = .ready(Data(h[Int(a)...Int(b)]))   // (already here from the first look)
            } else {
                pieces[next] = .queued
            }
            next += 1
        }
        // no more than the server's connections at once, in the file's order
        var k = i
        while k < next && active < max(1, src.conns) {
            if case .queued? = pieces[k] { start(k) }
            k += 1
        }
        if !writing, case .ready(let d)? = pieces[i] {
            writing = true
            pieces[i] = nil   // (let it go)
            client.send(d) { [weak self] ok in
                guard let self, !self.finished else { return }
                self.writing = false
                if !ok { self.abort(); return }
                self.i += 1
                if self.i >= self.count { self.complete() } else { self.step() }
            }
        }
    }

    private func start(_ k: Int) {
        active += 1
        pieces[k] = .active
        attempt(k, 0)
    }

    private func attempt(_ k: Int, _ n: Int) {
        guard !finished else { return }
        let (a, b) = bounds(k)
        let at = FLAttempt(want: Int(b - a + 1))
        attempts[k] = at
        var r = core.request(src.url)
        r.setValue("bytes=\(a)-\(b)", forHTTPHeaderField: "Range")
        at.fetch = core.fetch(r, onResponse: { [weak self, weak at] resp in
            guard let self, let at, !at.settled else { return false }
            guard let resp else { self.failed(k, n, at, "no answer"); return false }
            let code = resp.statusCode
            if code == 429 || code == 503 { self.src.conns = max(1, self.src.conns - 1); self.failed(k, n, at, "busy \(code)"); return false }
            if code != 206 { self.failed(k, n, at, "no piece: \(code)"); return false }
            if let cr = FLCore.contentRange(resp.value(forHTTPHeaderField: "Content-Range")), cr.from != a {
                self.failed(k, n, at, "wrong piece: \(cr.from)"); return false
            }
            return true
        }, onData: { [weak self, weak at] d in
            guard let self, let at, !at.settled else { return false }
            at.buf.append(d)
            if at.buf.count > at.want { self.failed(k, n, at, "long piece"); return false }
            return true
        }, onDone: { [weak self, weak at] err in
            guard let self, let at, !at.settled else { return }
            if let err { self.failed(k, n, at, err.localizedDescription); return }
            if at.buf.count != at.want { self.failed(k, n, at, "short piece \(at.buf.count)/\(at.want)"); return }
            at.settled = true
            let data = at.buf
            at.buf = Data()
            at.fetch = nil
            self.attempts[k] = nil
            self.active -= 1
            self.pieces[k] = .ready(data)
            self.step()
        })
        // (45 s for a piece, then it's asked for again)
        core.q.asyncAfter(deadline: .now() + 45) { [weak self, weak at] in
            guard let self, let at, !at.settled else { return }
            at.fetch?.cancel()
            self.failed(k, n, at, "timed out")
        }
    }

    // a piece that didn't come: asked for again (4 tries, the slot kept), then the answer stops there
    private func failed(_ k: Int, _ n: Int, _ at: FLAttempt, _ why: String) {
        guard !at.settled else { return }
        at.settled = true
        at.buf = Data()
        at.fetch = nil
        attempts[k] = nil
        guard !finished else { return }
        if n < 3 {
            core.q.asyncAfter(deadline: .now() + 0.4 * Double(n + 1)) { [weak self] in self?.attempt(k, n + 1) }
        } else {
            abort()
        }
    }

    private func complete() {
        finished = true
        pieces = [:]
        done(true)
    }

    // the player went away or jumped (or a piece never came): the rest is let go
    func abort() {
        guard !finished else { return }
        finished = true
        for at in attempts.values { at.settled = true; at.buf = Data(); at.fetch?.cancel(); at.fetch = nil }
        attempts = [:]
        pieces = [:]
        done(false)
    }
}

// ---- URLSession's callbacks, handed to the loader (they arrive on its queue)
final class FLSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    var onData: ((URLSessionDataTask, Data) -> Void)?
    var onComplete: ((URLSessionTask, Error?) -> Void)?
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) { onData?(dataTask, data) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { onComplete?(task, error) }
}

// ---- the loader
fileprivate final class FLCore: @unchecked Sendable {
    let q = DispatchQueue(label: "aperature.fastload", qos: .userInitiated)

    // (all of these only on q)
    private var listener: NWListener?
    private var listenerReady = false
    private var port: UInt16 = 0
    private var restarts = 0
    private var readyWaiters: [() -> Void] = []
    private var sources: [String: FLSource] = [:]
    private var ids: [String: String] = [:]
    private var clients: [ObjectIdentifier: FLClient] = [:]
    private var fetches: [ObjectIdentifier: FLFetch] = [:]
    private var sessions: [URLSession] = []
    private var sessionLoad: [Int] = []

    private let delegate = FLSessionDelegate()

    init() {
        delegate.onData = { [weak self] t, d in self?.received(t, d) }
        delegate.onComplete = { [weak self] t, e in self?.completed(t, e) }
        // URLSession's callbacks on the same queue as everything else
        let oq = OperationQueue()
        oq.maxConcurrentOperationCount = 1
        oq.underlyingQueue = q
        oq.name = "aperature.fastload.http"
        // (several sessions: a server that speaks HTTP/2 would otherwise carry every piece on one connection — the very
        // thing it slows down; each session keeps its own connections)
        for _ in 0..<8 {
            let c = URLSessionConfiguration.ephemeral
            c.httpMaximumConnectionsPerHost = 8
            c.requestCachePolicy = .reloadIgnoringLocalCacheData
            c.urlCache = nil
            c.timeoutIntervalForRequest = 45
            c.waitsForConnectivity = false
            sessions.append(URLSession(configuration: c, delegate: delegate, delegateQueue: oq))
            sessionLoad.append(0)
        }
    }

    // ---- outside: the address for a file
    func map(_ url: String) -> String {
        let lower = url.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://"), let u = URL(string: url), u.host != nil else { return url }
        guard let p = ensureStarted() else { return url }
        let id: String = q.sync {
            if let id = ids[url], sources[id] != nil { return id }
            let id = FLCore.newId()
            ids[url] = id
            sources[id] = FLSource(url: u)
            return id
        }
        // (the name stays at the end: mpv reads the extension from it)
        var name = ""
        let last = u.lastPathComponent
        if !last.isEmpty && last != "/" { name = last.addingPercentEncoding(withAllowedCharacters: FLCore.unreserved) ?? "" }
        return "http://127.0.0.1:\(p)/f/\(id)/\(name.isEmpty ? "file" : name)"
    }

    func isMapped(_ url: String) -> Bool {
        let p = q.sync { port }
        return p > 0 && url.hasPrefix("http://127.0.0.1:\(p)/f/")
    }

    func wake() {
        q.async { [self] in
            if listener == nil { restarts = 0; startListener() }
        }
    }

    static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func newId() -> String {
        (0..<12).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    // ---- the listener on 127.0.0.1
    private func ensureStarted() -> UInt16? {
        let sem = DispatchSemaphore(value: 0)
        let now: UInt16? = q.sync {
            if listener != nil && listenerReady && port != 0 { return port }
            readyWaiters.append { sem.signal() }
            if listener == nil { restarts = 0; startListener() }
            return nil
        }
        if let now { return now }
        _ = sem.wait(timeout: .now() + 3)
        return q.sync { listener != nil && listenerReady && port != 0 ? port : nil }
    }

    // (on q) tries 0–2: 127.0.0.1 on the port it had (so addresses already handed to mpv keep working), then any port;
    // from try 4: every interface, with only this device's own connections taken
    private func startListener() {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.acceptLocalOnly = true
        params.allowLocalEndpointReuse = true
        let same = port != 0 && restarts < 3 ? NWEndpoint.Port(rawValue: port) : nil
        let l: NWListener
        do {
            if restarts < 4 {
                params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: same ?? .any)
                l = try NWListener(using: params)
            } else {
                l = try NWListener(using: params, on: same ?? .any)
            }
        } catch {
            listenerFailed()
            return
        }
        listener = l
        listenerReady = false
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.stateUpdateHandler = { [weak self, weak l] st in
            guard let self, let l, self.listener === l else { return }
            switch st {
            case .ready:
                self.port = l.port?.rawValue ?? self.port
                self.listenerReady = self.port != 0
                self.restarts = 0
                let w = self.readyWaiters
                self.readyWaiters = []
                w.forEach { $0() }
            case .failed, .waiting:
                // (iOS took the socket away — the app was suspended — or it couldn't open: open it again)
                l.stateUpdateHandler = nil
                l.newConnectionHandler = nil
                l.cancel()
                self.listener = nil
                self.listenerReady = false
                self.listenerFailed()
            case .cancelled:
                self.listener = nil
                self.listenerReady = false
            default:
                break
            }
        }
        l.start(queue: q)
    }

    private func listenerFailed() {
        restarts += 1
        if restarts <= 6 {
            let soon = !readyWaiters.isEmpty
            q.asyncAfter(deadline: .now() + (soon ? 0.05 : 1.0)) { [weak self] in
                guard let self, self.listener == nil else { return }
                self.startListener()
            }
        } else {
            let w = readyWaiters
            readyWaiters = []
            w.forEach { $0() }
        }
    }

    private func accept(_ c: NWConnection) {
        // (only this device's own connections: the listener is on 127.0.0.1, this is a second lock)
        guard FLCore.isLocal(c.endpoint) else { c.cancel(); return }
        let cl = FLClient(core: self, conn: c)
        let key = ObjectIdentifier(cl)
        clients[key] = cl
        c.stateUpdateHandler = { [weak self, weak cl] st in
            switch st {
            case .failed:
                cl?.gone()
            case .cancelled:
                cl?.gone()
                self?.clients[key] = nil
            default:
                break
            }
        }
        c.start(queue: q)
        cl.read()
    }

    static func isLocal(_ e: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = e else { return false }
        switch host {
        case .ipv4(let a): return a.isLoopback
        case .ipv6(let a): return a.isLoopback || (a.asIPv4?.isLoopback ?? false)
        case .name(let n, _): return n == "127.0.0.1" || n == "localhost" || n == "::1"
        @unknown default: return false
        }
    }

    // ---- requests to the file's server
    func request(_ url: URL, method: String = "GET") -> URLRequest {
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 45)
        r.httpMethod = method
        r.setValue("Aperature/1.0", forHTTPHeaderField: "User-Agent")
        r.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return r
    }

    func fetch(_ r: URLRequest, onResponse: @escaping (HTTPURLResponse?) -> Bool, onData: @escaping (Data) -> Bool, onDone: @escaping (Error?) -> Void) -> FLFetch {
        var slot = 0
        for s in 1..<sessions.count where sessionLoad[s] < sessionLoad[slot] { slot = s }
        let t = sessions[slot].dataTask(with: r)
        let f = FLFetch(task: t, slot: slot, onResponse: onResponse, onData: onData, onDone: onDone)
        sessionLoad[slot] += 1
        fetches[ObjectIdentifier(t)] = f
        t.resume()
        return f
    }

    // (URLSession, on q)
    private func received(_ dataTask: URLSessionDataTask, _ data: Data) {
        guard let f = fetches[ObjectIdentifier(dataTask)], !f.cancelled else { return }
        if !f.seen {
            f.seen = true
            if !f.onResponse(dataTask.response as? HTTPURLResponse) { f.cancel(); return }
            if f.cancelled { return }
        }
        if !f.onData(data) { f.cancel() }
    }

    private func completed(_ task: URLSessionTask, _ error: Error?) {
        guard let f = fetches.removeValue(forKey: ObjectIdentifier(task)) else { return }
        sessionLoad[f.slot] -= 1
        guard !f.cancelled else { return }
        if error == nil && !f.seen {
            // (an answer with no body: HEAD, an error status)
            f.seen = true
            if !f.onResponse(task.response as? HTTPURLResponse) { f.cancelled = true; return }
            if f.cancelled { return }
        }
        f.onDone(error)
    }

    // "bytes 0-524287/45000000" → (0, 45000000)
    static func contentRange(_ s: String?) -> (from: Int64, total: Int64)? {
        guard let s0 = s?.trimmingCharacters(in: .whitespaces), s0.lowercased().hasPrefix("bytes") else { return nil }
        var t = s0.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("=") { t = String(t.dropFirst()) }
        let sl = t.split(separator: "/")
        guard sl.count == 2, let total = Int64(sl[1].trimmingCharacters(in: .whitespaces)) else { return nil }
        let ft = sl[0].split(separator: "-")
        guard ft.count == 2, let f = Int64(ft[0].trimmingCharacters(in: .whitespaces)) else { return nil }
        return (f, total)
    }

    static func reason(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 416: return "Range Not Satisfiable"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        default: return HTTPURLResponse.localizedString(forStatusCode: code).capitalized
        }
    }

    // ---- the answer to one request (on q)
    func answer(_ req: FLRequest, _ c: FLClient) {
        var src: FLSource?
        let parts = req.path.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count >= 3 && parts[1] == "f" { src = sources[String(parts[2])] }
        guard let src, req.method == "GET" || req.method == "HEAD" else {
            c.send(Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
            c.finish(keep: false)
            return
        }
        probe(src) { [weak self, weak c] failure in
            guard let self, let c, !c.dead else { return }
            self.answer(req, src, c, failure)
        }
    }

    private func answer(_ req: FLRequest, _ src: FLSource, _ c: FLClient, _ failure: String?) {
        // the file's server didn't answer at all: say so (mpv then knows at once), not an empty connection
        if let failure {
            let msg = Data("The file's server didn't answer: \(failure)".utf8)
            c.send(Data("HTTP/1.1 502 Bad Gateway\r\nContent-Type: text/plain\r\nContent-Length: \(msg.count)\r\nConnection: close\r\n\r\n".utf8))
            c.send(msg)
            c.finish(keep: false)
            return
        }
        if !src.ranges || src.length <= 0 {
            passThrough(src, req, c)
            return
        }
        let total = src.length
        let from = req.from < 0 ? 0 : req.from
        let to = req.to < 0 || req.to >= total ? total - 1 : req.to
        if from >= total || to < from {
            c.send(Data("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(total)\r\nContent-Length: 0\r\n\r\n".utf8))
            c.finish(keep: !req.close)
            return
        }
        let partial = req.from >= 0
        var h = partial ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n"
        h += "Content-Type: \(src.type)\r\n"
        h += "Accept-Ranges: bytes\r\n"
        h += "Content-Length: \(to - from + 1)\r\n"
        if partial { h += "Content-Range: bytes \(from)-\(to)/\(total)\r\n" }
        h += req.close ? "Connection: close\r\n" : "Connection: keep-alive\r\n"
        h += "\r\n"
        c.send(Data(h.utf8))
        if req.method == "HEAD" { c.finish(keep: !req.close); return }
        let pump = FLPump(core: self, src: src, client: c, from: from, to: to) { [weak c] ok in
            guard let c else { return }
            if ok { c.finish(keep: !req.close) } else { c.gone() }
        }
        c.pump = pump
        c.onGone = { [weak pump] in pump?.abort() }
        pump.step()
    }

    // the server's answer to the file's first piece: does it send pieces, how long is the file — and the piece itself
    // (one trip to the server fewer before it starts)
    private func probe(_ src: FLSource, _ then: @escaping (String?) -> Void) {
        if src.probed { then(nil); return }
        src.waiters.append(then)
        if src.probing { return }
        src.probing = true
        let pr = FLProbe()
        var r = request(src.url)
        r.setValue("bytes=0-\(FastLoad.firstPiece - 1)", forHTTPHeaderField: "Range")
        pr.fetch = fetch(r, onResponse: { [weak self] resp in
            guard let self else { return false }
            guard let resp else { src.failure = "no answer"; self.probed(src, pr); return false }
            if let ct = resp.value(forHTTPHeaderField: "Content-Type"), !ct.isEmpty { src.type = ct }
            if resp.statusCode == 206, let cr = FLCore.contentRange(resp.value(forHTTPHeaderField: "Content-Range")), cr.from == 0, cr.total > 0 {
                src.ranges = true
                src.length = cr.total
                pr.want = Int(min(Int64(FastLoad.firstPiece), cr.total))
                pr.buf.reserveCapacity(pr.want)
                return true
            }
            // (no pieces from this server: passed straight through — nothing more is read of this answer)
            if resp.statusCode >= 400 { src.failure = "HTTP \(resp.statusCode)" }
            self.probed(src, pr)
            return false
        }, onData: { [weak self] d in
            guard let self, !pr.done else { return false }
            pr.buf.append(d)
            if pr.buf.count > pr.want {
                src.head = Data(pr.buf.prefix(pr.want))
                self.probed(src, pr)
                return false
            }
            return true
        }, onDone: { [weak self] err in
            guard let self, !pr.done else { return }
            if let err {
                src.ranges = false
                src.failure = err.localizedDescription
            } else if pr.buf.count == pr.want {
                src.head = pr.buf
            }
            self.probed(src, pr)
        })
        q.asyncAfter(deadline: .now() + 15) { [weak self, weak pr] in
            guard let self, let pr, !pr.done else { return }
            pr.fetch?.cancel()
            src.ranges = false
            src.failure = "timed out"
            self.probed(src, pr)
        }
    }

    private func probed(_ src: FLSource, _ pr: FLProbe) {
        guard !pr.done else { return }
        pr.done = true
        pr.fetch = nil
        pr.buf = Data()
        src.probed = true
        src.probing = false
        let failure = src.failure
        if failure != nil { src.probed = false; src.failure = nil }   // (asked again next time — it may be back)
        let w = src.waiters
        src.waiters = []
        w.forEach { $0(failure) }
    }

    // a server that doesn't send pieces: straight through, one connection (what mpv did by itself)
    private func passThrough(_ src: FLSource, _ req: FLRequest, _ c: FLClient) {
        let head = req.method == "HEAD"
        var r = request(src.url, method: head ? "HEAD" : "GET")
        if req.from >= 0 { r.setValue("bytes=\(req.from)-" + (req.to >= 0 ? "\(req.to)" : ""), forHTTPHeaderField: "Range") }
        let f = fetch(r, onResponse: { [weak c] resp in
            guard let c, !c.dead else { return false }
            guard let resp else { c.gone(); return false }
            var h = "HTTP/1.1 \(resp.statusCode) \(FLCore.reason(resp.statusCode))\r\n"
            h += "Content-Type: \(resp.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream")\r\n"
            if let cl = resp.value(forHTTPHeaderField: "Content-Length") { h += "Content-Length: \(cl)\r\n" }
            else if resp.expectedContentLength >= 0 { h += "Content-Length: \(resp.expectedContentLength)\r\n" }
            if let cr = resp.value(forHTTPHeaderField: "Content-Range") { h += "Content-Range: \(cr)\r\n" }
            h += "Connection: close\r\n\r\n"
            c.send(Data(h.utf8))
            if head { c.finish(keep: false); return false }
            return true
        }, onData: { [weak c] d in
            guard let c, !c.dead else { return false }
            c.send(d)
            // (a player that reads slowly: the server waits, rather than the file piling up here)
            if c.inflight > 8 << 20 { c.passFetch?.suspend() }
            return true
        }, onDone: { [weak c] err in
            guard let c else { return }
            if err != nil { c.gone() } else { c.finish(keep: false) }
        })
        c.passFetch = f
        c.onDrain = { [weak f] in f?.resume() }
        c.onGone = { [weak f] in f?.cancel() }
    }
}
