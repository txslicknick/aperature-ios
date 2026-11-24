// v1.0.80 (iOS): the several-connections loader (../Aperature/Player/FastLoad.swift, the same file the app is built
// with), tested for real on a Mac — the Windows app's FastLoadTest, check for check: a local server that sends each
// connection slowly (origin.py, like a debrid service), a file through the loader byte for byte, jumps like a player's,
// a server without ranges, a player that goes away mid-file, a failing server, and real FFmpeg (what mpv uses to read)
// playing and seeking through it.
//
//   xcrun swiftc -O -target "$(uname -m)-apple-macosx13.0" -o fastload-test main.swift ../Aperature/Player/FastLoad.swift
//   ./fastload-test origin.py [ffmpeg] [ffprobe]
//
// Prints ok / FAIL lines, then "ALL PASSED" (exit 0) or "<n> FAILED" (exit 1).
// One source body. Many apertures. No compulsory simultaneity.
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

final class Box<T> { var v: T; init(_ v: T) { self.v = v } }

var fails = 0
func ok(_ what: String, _ pass: Bool, _ extra: String = "") {
    print((pass ? "ok   " : "FAIL ") + what + (pass || extra.isEmpty ? "" : "  [\(extra)]"))
    if !pass { fails += 1 }
}

let args = CommandLine.arguments
let originScript = args.count > 1 ? args[1] : "origin.py"
let ffmpeg = args.count > 2 ? args[2] : "ffmpeg"
let ffprobe = args.count > 3 ? args[3] : "ffprobe"

// (the whole test never hangs a build: 15 minutes at most)
DispatchQueue.global().asyncAfter(deadline: .now() + 900) {
    print("FAIL the test took over 15 minutes")
    exit(2)
}

// ---- running a program (through env: ffmpeg / python3 from PATH)
func run(_ exe: String, _ a: [String], timeout: TimeInterval) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = [exe] + a
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    p.standardInput = FileHandle.nullDevice
    let out = Box(Data())
    let reading = DispatchGroup()
    reading.enter()
    let fh = pipe.fileHandleForReading
    DispatchQueue.global().async {
        let d = fh.readDataToEndOfFile()
        out.v = d
        reading.leave()
    }
    do { try p.run() } catch { return (-1, "could not start \(exe): \(error)") }
    let deadline = Date().addingTimeInterval(timeout)
    while p.isRunning && Date() < deadline { usleep(100_000) }
    if p.isRunning {
        p.terminate()
        p.waitUntilExit()
        _ = reading.wait(timeout: .now() + 5)
        return (-1, "timed out")
    }
    p.waitUntilExit()
    _ = reading.wait(timeout: .now() + 10)
    return (p.terminationStatus, String(decoding: out.v, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}

// ---- HTTP, the way a player asks (one request at a time, waited for)
let cfg = URLSessionConfiguration.ephemeral
cfg.httpMaximumConnectionsPerHost = 16
cfg.timeoutIntervalForRequest = 300
cfg.timeoutIntervalForResource = 600
cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
cfg.urlCache = nil
let http = URLSession(configuration: cfg)

struct Got { var status = -1; var resp: HTTPURLResponse?; var data = Data(); var error = "" }
func get(_ url: String, _ from: Int64 = -1, _ to: Int64 = -1, method: String = "GET") -> Got {
    guard let u = URL(string: url) else { return Got(error: "bad address \(url)") }
    var r = URLRequest(url: u)
    r.httpMethod = method
    if from >= 0 { r.setValue("bytes=\(from)-" + (to >= 0 ? "\(to)" : ""), forHTTPHeaderField: "Range") }
    let sem = DispatchSemaphore(value: 0)
    let g = Box(Got())
    http.dataTask(with: r) { d, resp, err in
        g.v.resp = resp as? HTTPURLResponse
        g.v.status = g.v.resp?.statusCode ?? -1
        g.v.data = d ?? Data()
        g.v.error = err.map { "\($0)" } ?? ""
        sem.signal()
    }.resume()
    sem.wait()
    return g.v
}

// a player that goes away mid-file: a plain socket that reads for a while, then closes
func walkAway(port: Int, path: String, seconds: Double) -> Int {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return -1 }
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(UInt16(port)).bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let rc = withUnsafePointer(to: &addr) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard rc == 0 else { close(fd); return -1 }
    var tv = timeval(tv_sec: 0, tv_usec: 200_000)
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    let req = Array("GET \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8)
    _ = req.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
    var total = 0
    var buf = [UInt8](repeating: 0, count: 65536)
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        let n = buf.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
        if n > 0 { total += n } else if n == 0 { break }
    }
    close(fd)
    return total
}

// a little seeded generator (the same jumps every run)
struct SplitMix: RandomNumberGenerator {
    var s: UInt64
    mutating func next() -> UInt64 {
        s &+= 0x9E3779B97F4A7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

// ---- 0. a real video: 60 s, 1080p, sound — about 45 MB
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("fastload-test.mkv").path
var (rc, o) = run(ffmpeg, ["-nostdin", "-y", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=30", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
                           "-t", "60", "-c:v", "mpeg4", "-b:v", "6M", "-c:a", "aac", "-b:a", "128k", tmp], timeout: 300)
ok("a 60 s 1080p test video was made", rc == 0 && FileManager.default.fileExists(atPath: tmp), o)
guard let file = FileManager.default.contents(atPath: tmp), file.count > 10_000_000 else {
    print("FAIL no test video — stopping here")
    print("\(fails) FAILED")
    exit(1)
}
print("     test file: " + String(format: "%.1f", Double(file.count) / 1048576) + " MB")
let N = Int64(file.count)

// ---- the slow server
let origin = Process()
origin.executableURL = URL(fileURLWithPath: "/usr/bin/env")
origin.arguments = ["python3", originScript, tmp]
let originOut = Pipe()
origin.standardOutput = originOut
origin.standardInput = FileHandle.nullDevice
do { try origin.run() } catch { print("FAIL could not start the test server: \(error)"); exit(1) }
var portData = Data()
while !portData.contains(10) {
    let d = originOut.fileHandleForReading.availableData
    if d.isEmpty { break }
    portData.append(d)
}
let portLine = String(decoding: portData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
guard portLine.hasPrefix("PORT "), let port = Int(portLine.dropFirst(5)) else {
    print("FAIL the test server didn't start: \(portLine)")
    origin.terminate()
    exit(1)
}
func stop(_ code: Int32) -> Never {
    origin.terminate()
    try? FileManager.default.removeItem(atPath: tmp)
    exit(code)
}
let base = "http://127.0.0.1:\(port)"
func stats(_ q: String = "") -> [String: Int] {
    let g = get(base + "/_ctl?" + q)
    return (try? JSONSerialization.jsonObject(with: g.data)) as? [String: Int] ?? [:]
}
let originUrl = base + "/media/test%20file.mkv"

// ---- 1. one connection (what the player did) vs through the loader
var t0 = Date()
let direct = get(originUrl)
let tDirect = Date().timeIntervalSince(t0)
ok("straight from the server: the whole file", direct.data == file, "\(direct.data.count) bytes \(direct.error)")
let mapped = FastLoad.map(originUrl)
ok("the loader's address is on this computer and keeps the file's name", mapped.hasPrefix("http://127.0.0.1:") && mapped.hasSuffix("/test%20file.mkv"), mapped)
ok("…and it is the loader's (isMapped), the same each time", FastLoad.isMapped(mapped) && FastLoad.map(originUrl) == mapped)
_ = stats("resetMax=1")
t0 = Date()
let via = get(mapped)
let tVia = Date().timeIntervalSince(t0)
let maxOpen = stats()["maxOpen"] ?? -1
ok("through the loader: the same file, byte for byte", via.data.count == file.count && via.data == file, "\(via.data.count) bytes \(via.error)")
ok("…at least 2.5× as fast as one connection (" + String(format: "%.1f s → %.1f s", tDirect, tVia) + ")", tVia * 2.5 <= tDirect, "\(tDirect) vs \(tVia)")
ok("…on several connections at once (up to \(maxOpen))", maxOpen >= 3 && maxOpen <= FastLoad.connections + 2, "\(maxOpen)")

// ---- 2. jumps, as a player makes them
var rnd = SplitMix(s: 7)
var allRanges = true
var bad = ""
for _ in 0..<20 {
    let a = Int64.random(in: 0..<(N - 1), using: &rnd)
    let b = min(N - 1, a + Int64.random(in: 1..<(3 * 1024 * 1024), using: &rnd))
    let g = get(mapped, a, b)
    if g.status != 206 || g.data != file[Int(a)...Int(b)] { allRanges = false; bad = "\(a)-\(b) got \(g.status) \(g.data.count) \(g.error)" }
}
ok("20 jumps to anywhere in the file: each piece exact", allRanges, bad)
let tail = get(mapped, N - 100)
ok("the last 100 bytes (\"bytes=N-\")", tail.data.count == 100 && tail.data == file.suffix(100), "\(tail.status) \(tail.data.count)")
let oneByte = get(mapped, 0, 0)
let cr = oneByte.resp?.value(forHTTPHeaderField: "Content-Range") ?? ""
ok("a 1-byte range answers 206 with the file's length", oneByte.status == 206 && cr == "bytes 0-0/\(N)" && oneByte.data.count == 1, "\(oneByte.status) \(cr)")
let headAns = get(mapped, method: "HEAD")
ok("HEAD: the length, no body", headAns.status == 200 && headAns.resp?.value(forHTTPHeaderField: "Content-Length") == "\(N)" && headAns.data.isEmpty,
   "\(headAns.status) \(headAns.resp?.value(forHTTPHeaderField: "Content-Length") ?? "-")")

// ---- 3. the player goes away mid-file (a jump), then asks again
let mappedPort = URLComponents(string: mapped)?.port ?? 0
let mappedPath = URLComponents(string: mapped)?.percentEncodedPath ?? "/"
let readBytes = walkAway(port: mappedPort, path: mappedPath, seconds: 1.5)
ok("a player read part of the file, then went away (\(readBytes / 1024) KB)", readBytes > 0 && Int64(readBytes) < N, "\(readBytes)")
Thread.sleep(forTimeInterval: 1.5)
let again = get(mapped, 1_000_000, 1_999_999)
ok("after a player went away mid-file, the next ask is fine", again.data.count == 1_000_000 && again.data == file[1_000_000...1_999_999], "\(again.status) \(again.data.count)")
let letGo = Date()
var openNow = stats()["open"] ?? -1
while openNow != 0 && Date().timeIntervalSince(letGo) < 5 { Thread.sleep(forTimeInterval: 0.1); openNow = stats()["open"] ?? -1 }
ok("…and its connections were let go within 5 s (\(openNow) open after \(Int(Date().timeIntervalSince(letGo) * 1000)) ms)", openNow == 0, "\(openNow)")

// ---- 4. real FFmpeg (mpv reads http the same way): plays it through, and from 30 s in
_ = stats("rate=\(40 * 1024 * 1024)")
(rc, o) = run(ffmpeg, ["-nostdin", "-v", "error", "-i", mapped, "-f", "null", "-"], timeout: 180)
ok("FFmpeg plays the whole video through the loader", rc == 0, o)
(rc, o) = run(ffmpeg, ["-nostdin", "-v", "error", "-ss", "30", "-i", mapped, "-t", "5", "-f", "null", "-"], timeout: 120)
ok("…and from 30 s in (a jump)", rc == 0, o)
(rc, o) = run(ffprobe, ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", mapped], timeout: 60)
let dur = Double(o.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? "") ?? -1
ok("…FFprobe reads its length (60 s)", rc == 0 && abs(dur - 60) < 1.5, o)

// ---- 5. a server that doesn't send pieces: straight through, still the whole file
_ = stats("ranges=0")
let plain = get(FastLoad.map(base + "/media/plain.mkv"))
ok("a server without ranges: passed straight through, the whole file", plain.data.count == file.count && plain.data == file, "\(plain.status) \(plain.data.count) \(plain.error)")
_ = stats("ranges=1")

// ---- 6. the first look brings the start of the file: a small first ask needs no second trip
let fresh = FastLoad.map(base + "/media/fresh.mkv")
_ = stats("resetAsks=1")
let startAns = get(fresh, 0, 300_000)
let asks = stats()["asks"] ?? -1
ok("the file's start comes with the first look (1 ask of the server, not 2): \(asks)", asks == 1 && startAns.data.count == 300_001 && startAns.data == file.prefix(300_001), "\(asks) \(startAns.status) \(startAns.data.count)")

// ---- 7. a server that fails: an error at once, not an empty answer
let failing = FastLoad.map(base + "/fail/x.mkv")
t0 = Date()
let fr = get(failing)
let fms = Int(Date().timeIntervalSince(t0) * 1000)
ok("a failing server: the player is told (502) within 3 s", fr.status == 502 && fms < 3000 && String(decoding: fr.data, as: UTF8.self).contains("HTTP 500"), "\(fr.status) in \(fms) ms")

// ---- 8. something not on the web is left alone; and the loader answers after a wake (the app back in front)
ok("a file on this device isn't mapped", FastLoad.map("/Users/me/Videos/a.mkv") == "/Users/me/Videos/a.mkv" && FastLoad.map("file:///tmp/a.mkv") == "file:///tmp/a.mkv")
FastLoad.wake()
Thread.sleep(forTimeInterval: 0.3)
let woke = get(mapped, 0, 0)
ok("after wake(): the same address still answers", woke.status == 206 && woke.data.count == 1, "\(woke.status)")

print(fails == 0 ? "ALL PASSED" : "\(fails) FAILED")
stop(fails == 0 ? 0 : 1)
