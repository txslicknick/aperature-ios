// v1.0.80 (iOS): system Picture in Picture for the mpv player — as YouTube / Crunchyroll: leave the app while a video
// plays (or press the PiP button) and it plays on in a floating window over other apps, with play / pause and skip;
// tapping the window's "back to app" button brings the full player back at the same spot.
//
// How (mpv draws into its own Metal layer, which iOS can't put in a PiP window): AVPictureInPictureController's
// sample-buffer source (iOS 15+) — an AVSampleBufferDisplayLayer that sits behind the Metal layer. While PiP is on,
// mpv's picture goes to a "null" output (no GPU drawing — iOS doesn't allow GPU work in the background) and the
// frames come from mpv itself (screenshot-raw: the decoded frame with its subtitles, BGRA, done on the CPU), copied
// into CVPixelBuffers and shown in the PiP window. In the app, a frame every few seconds keeps the layer ready for PiP
// to start from. Sound plays through mpv as always. When PiP ends the normal picture (gpu-next) comes back.
// One source body. Many apertures. No compulsory simultaneity.
import UIKit
import AVKit
import AVFoundation
import CoreMedia
import CoreVideo
import Libmpv

// v1.0.80 (iOS): what PiP needs from mpv — kept here, apart from MPV.swift
extension MPV {
    // one picture of what's playing (subtitles drawn in), BGRA, handed to `body` while mpv still holds it; false = none
    // (no video, nothing decoded yet, the output being switched). Blocks until mpv's core has made it: not on main.
    @discardableResult
    func pipFrame(_ body: (_ width: Int, _ height: Int, _ stride: Int, _ bytes: UnsafeRawPointer) -> Void) -> Bool {
        guard let h = handle else { return false }
        let args = ["screenshot-raw", "subtitles", "bgra"]
        var cargs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) }
        cargs.append(nil)
        defer { for p in cargs where p != nil { free(UnsafeMutablePointer(mutating: p!)) } }
        var res = mpv_node()
        guard mpv_command_ret(h, &cargs, &res) >= 0 else { return false }
        defer { mpv_free_node_contents(&res) }
        guard res.format == MPV_FORMAT_NODE_MAP, let list = res.u.list?.pointee, list.num > 0,
              let keys = list.keys, let values = list.values else { return false }
        var w = 0, ht = 0, stride = 0, size = 0
        var bytes: UnsafeRawPointer? = nil
        for i in 0..<Int(list.num) {
            guard let k = keys[i] else { continue }
            let v = values[i]
            switch String(cString: k) {
            case "w" where v.format == MPV_FORMAT_INT64: w = Int(v.u.int64)
            case "h" where v.format == MPV_FORMAT_INT64: ht = Int(v.u.int64)
            case "stride" where v.format == MPV_FORMAT_INT64: stride = Int(v.u.int64)
            case "data" where v.format == MPV_FORMAT_BYTE_ARRAY:
                if let ba = v.u.ba?.pointee, let d = ba.data { bytes = UnsafeRawPointer(d); size = Int(ba.size) }
            default: break
            }
        }
        guard w > 0, ht > 0, stride >= w * 4, let bytes, size >= stride * ht else { return false }
        body(w, ht, stride, bytes)
        return true
    }
}

final class PlayerPiP: NSObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    // the layer PiP shows (the player puts it behind mpv's Metal layer, the same size)
    let layer = AVSampleBufferDisplayLayer()
    private var controller: AVPictureInPictureController?
    private var timebase: CMTimebase?
    private weak var mpv: MPV?

    // the player's side (main thread)
    var onWillStart: (() -> Void)?
    var onStop: ((_ restoring: Bool) -> Void)?    // ended (or failed to start); restoring = back to the app's player
    var onPlay: ((Bool) -> Void)?
    var onSkip: ((Double) -> Void)?
    private(set) var isActive = false             // from "will start" until it has stopped
    private var restoring = false
    private var savedVO: String?
    private(set) var videoIsOff = false           // mpv's picture on the null output (PiP's frames come from screenshots)
    var speed: Double = 1 { didSet { applyRate() } }
    private var paused = true, position: Double = 0, duration: Double = 0
    private var observers: [NSObjectProtocol] = []

    // shared with the frame queue
    private let lock = NSLock()
    private var sPaused = true, sPosition: Double = 0, sDuration: Double = 0, sPlayed = false, sAppActive = true, sVideoOff = false

    // the frame queue's own
    private let feedQueue = DispatchQueue(label: "aperature.pip", qos: .userInitiated)
    private var fast = false, gen = 0, stopped = false
    private var pool: CVPixelBufferPool?
    private var poolW = 0, poolH = 0
    private var haveFrame = false, lastPos: Double = -1, fps: Double = 24
    private var failingSince: Double = 0   // (PiP on, but no frame could be made since then: 0 = fine)

    // nil where this device has no Picture in Picture (the player then works as before)
    init?(mpv: MPV) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return nil }
        self.mpv = mpv
        super.init()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColor.black.cgColor
        var tb: CMTimebase?
        if CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &tb) == 0, let tb {
            CMTimebaseSetTime(tb, time: .zero)
            CMTimebaseSetRate(tb, rate: 0)
            layer.controlTimebase = tb
            timebase = tb
        }
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: self)
        let c = AVPictureInPictureController(contentSource: source)
        c.delegate = self
        c.requiresLinearPlayback = false
        c.canStartPictureInPictureAutomaticallyFromInline = true
        controller = c
        // in the app a frame now and then, never while the app is going away (no GPU work in the background)
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.setAppActive(false) })
        observers.append(nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.setAppActive(true) })
        setFast(false)
    }
    deinit { for o in observers { NotificationCenter.default.removeObserver(o) } }

    // PiP can start now (the button; and whether leaving the app should wait to see it start)
    var isPossible: Bool { controller?.isPictureInPicturePossible ?? false }
    @discardableResult
    func start() -> Bool {
        guard let c = controller, c.isPictureInPicturePossible, !c.isPictureInPictureActive else { return false }
        c.startPictureInPicture()
        return true
    }
    func stop() { if controller?.isPictureInPictureActive == true { controller?.stopPictureInPicture() } }

    // mpv's picture: off (null output — nothing drawn on the GPU; frames for PiP still come from mpv) or back on
    func videoOff(_ off: Bool) {
        guard let m = mpv, off != videoIsOff else { return }
        videoIsOff = off
        lock.lock(); sVideoOff = off; lock.unlock()
        if off {
            if let vo = m.getString("vo"), !vo.isEmpty, vo != "null" { savedVO = vo }
            m.setString("vo", "null")
        } else {
            m.setString("vo", savedVO ?? "gpu-next")
        }
    }

    // ---- the player's state (main thread): the PiP window's progress, play / pause
    func update(position: Double, duration: Double, paused: Bool, played: Bool) {
        let pausedChanged = paused != self.paused, lengthChanged = abs(duration - self.duration) > 0.5
        let jumped = abs(position - self.position) > 2
        self.paused = paused; self.position = position; self.duration = duration
        lock.lock(); sPaused = paused; sPosition = position; sDuration = duration; sPlayed = played; lock.unlock()
        if let tb = timebase {
            let now = CMTimeGetSeconds(CMTimebaseGetTime(tb))
            if !now.isFinite || abs(now - position) > 0.5 { CMTimebaseSetTime(tb, time: CMTime(seconds: max(0, position), preferredTimescale: 1000)) }
        }
        if pausedChanged { applyRate() }
        if pausedChanged || (isActive && (lengthChanged || jumped)) { controller?.invalidatePlaybackState() }
    }
    private func applyRate() {
        if let tb = timebase { CMTimebaseSetRate(tb, rate: paused ? 0 : max(0.1, speed)) }
    }
    private func setAppActive(_ on: Bool) { lock.lock(); sAppActive = on; lock.unlock() }

    // the player closes: PiP ends, no more frames; `then` once no frame is being taken (mpv can be destroyed then)
    func shutdown(then: @escaping () -> Void) {
        onWillStart = nil; onStop = nil; onPlay = nil; onSkip = nil
        controller?.canStartPictureInPictureAutomaticallyFromInline = false
        stop()
        feedQueue.async { [self] in
            stopped = true; gen += 1
            DispatchQueue.main.async { then() }
        }
    }

    // ---- frames: in the app one every 4 s while it plays (so PiP has a picture to start from); in PiP at the
    // video's frame rate (10–30 a second), slower when a frame takes long to make (4K)
    private func setFast(_ on: Bool) {
        feedQueue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.gen += 1
            self.fast = on
            if on, let m = self.mpv {
                let f = Double(m.getString("estimated-vf-fps") ?? "") ?? Double(m.getString("container-fps") ?? "") ?? 24
                self.fps = f.isFinite ? min(30, max(10, f)) : 24
            }
            self.tick(self.gen)
        }
    }
    private func tick(_ g: Int) {
        guard !stopped, g == gen else { return }
        lock.lock(); let p = sPaused, pos = sPosition, played = sPlayed, appActive = sAppActive, off = sVideoOff; lock.unlock()
        var cost = 0.0
        let same = haveFrame && abs(pos - lastPos) < 0.01
        let want = played && !(p && same) && (fast ? true : (appActive && !off))
        if want {
            let t0 = CACurrentMediaTime()
            if grab() { haveFrame = true; lastPos = pos; failingSince = 0 }
            else if fast {
                // no picture for PiP for 6 s (this mpv can't make one here): PiP ends — and with it the player does as
                // it did before PiP (paused in the background), rather than a black window
                if failingSince == 0 { failingSince = t0 }
                else if t0 - failingSince > 6 { failingSince = 0; DispatchQueue.main.async { [weak self] in self?.stop() } }
            }
            cost = CACurrentMediaTime() - t0
        }
        if !fast { failingSince = 0 }
        let interval = fast ? max(1 / fps, cost * 2) : 4
        feedQueue.asyncAfter(deadline: .now() + max(0.01, interval - cost)) { [weak self] in self?.tick(g) }
    }

    private func grab() -> Bool {
        guard let m = mpv else { return false }
        var out: CVPixelBuffer?
        let ok = m.pipFrame { w, h, stride, src in
            if self.pool == nil || self.poolW != w || self.poolH != h { self.makePool(w, h) }
            guard let pool = self.pool else { return }
            var pb: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb) == kCVReturnSuccess, let pb else { return }
            CVPixelBufferLockBaseAddress(pb, [])
            if let dst = CVPixelBufferGetBaseAddress(pb) {
                let dstStride = CVPixelBufferGetBytesPerRow(pb)
                let row = min(w * 4, dstStride)
                if dstStride == stride { memcpy(dst, src, stride * h) }
                else { for y in 0..<h { memcpy(dst + y * dstStride, src + y * stride, row) } }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            out = pb
        }
        guard ok, let pb = out else { return false }
        return enqueue(pb)
    }
    private func makePool(_ w: Int, _ h: Int) {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        var p: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &p)
        pool = p; poolW = w; poolH = h
    }
    private func enqueue(_ pb: CVPixelBuffer) -> Bool {
        var fmt: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescriptionOut: &fmt) == 0, let fmt else { return false }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: timebase.map { CMTimebaseGetTime($0) } ?? .zero, decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescription: fmt, sampleTiming: &timing, sampleBufferOut: &sb) == 0, let sb else { return false }
        // shown at once (the timebase only drives the PiP window's progress bar)
        if let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true), CFArrayGetCount(atts) > 0 {
            let d = unsafeBitCast(CFArrayGetValueAtIndex(atts, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(d, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        if layer.status == .failed || layer.requiresFlushToResumeDecoding { layer.flush() }
        guard layer.isReadyForMoreMediaData else { return false }
        layer.enqueue(sb)
        return true
    }

    // ---- AVPictureInPictureControllerDelegate
    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isActive = true
        restoring = false
        videoOff(true)
        setFast(true)
        onWillStart?()
    }
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        controller?.invalidatePlaybackState()
    }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        ended()
    }
    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        ended()
    }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        // the full player never went away (it stays presented behind the PiP window): it's there at once
        restoring = true
        completionHandler(true)
    }
    private func ended() {
        let r = restoring
        restoring = false
        isActive = false
        setFast(false)
        onStop?(r)
    }

    // ---- AVPictureInPictureSampleBufferPlaybackDelegate: the PiP window's buttons and progress
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        if Thread.isMainThread { onPlay?(playing) } else { DispatchQueue.main.async { [weak self] in self?.onPlay?(playing) } }
    }
    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        lock.lock(); let len = sDuration; lock.unlock()
        if len > 0 { return CMTimeRange(start: .zero, duration: CMTime(seconds: len, preferredTimescale: 1000)) }
        return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)   // (length not known yet: as live)
    }
    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return sPaused
    }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        let s = CMTimeGetSeconds(skipInterval)
        if s.isFinite && s != 0 {
            if Thread.isMainThread { onSkip?(s) } else { DispatchQueue.main.async { [weak self] in self?.onSkip?(s) } }
        }
        completionHandler()
    }
}
