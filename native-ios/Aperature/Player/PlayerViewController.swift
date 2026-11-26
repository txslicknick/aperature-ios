// Aperature's native player screen: mpv's picture full screen, with Aperature's controls — play / pause, ±10 s,
// a scrubber, Next episode, audio & subtitles — and double-tap left / right to skip 10 s.
import UIKit
import MediaPlayer
import AVFoundation

final class PlayerViewController: UIViewController, MPVDelegate {
    private let job: PlayJob
    var jobId: String { job.n }
    private let done: (PlayResult) -> Void
    private let videoView = UIView()
    private let layerView = MetalLayer()
    private var mpv: MPV?
    private var finished = false

    // controls
    private let overlay = UIView()
    private let shade = CAGradientLayer()
    private let titleLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private let tracksButton = UIButton(type: .system)
    private let audioButton = UIButton(type: .system)      // v1.12.6: the audio language, one tap away
    private let muteButton = UIButton(type: .system)       // v1.12.6: sound on / off
    private var audioChecked = false
    private let playButton = UIButton(type: .system)
    private let backButton = UIButton(type: .system)
    private let fwdButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    // v1.16.1: the Windows player's bar on the iPhone too — speed, Boost and Settings as their own buttons
    private let speedButton = UIButton(type: .system)
    private let boostButton = UIButton(type: .system)
    private let settingsButton = UIButton(type: .system)
    // v1.0.80 (iOS): system Picture in Picture (PiP.swift) — nil where the device has none (then all as before)
    private var pip: PlayerPiP?
    private let pipButton = UIButton(type: .system)
    private let pipCover = UIView()
    private var bgPaused = false              // v1.0.80 (iOS): the app went away and the player paused for it (as always)
    private var pipWait: DispatchWorkItem?    // v1.0.80 (iOS): gone to the background: waiting to see PiP start
    private let slider = UISlider()
    private let timeLabel = UILabel()
    private let leftLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)
    // v1.0.5: Skip intro / recap and Next episode, from the episode's times (Aperature asks AniSkip / IntroDB)
    var askSkips: ((String, Int, Int) -> Void)?
    // the audio/subtitle plan the page sends for each episode (AvPlan.swift); avEvent: what it did, for the page's totals
    let planner = AvPlanner()
    func setPlan(index: Int, plan: [String: Any]) { planner.set(index: index, plan: plan) }
    // v1.0.57 (the owner: "in the middle of ep 10 on my PC, my phone should pick up there"): where you are, sent to the page
    // every ~12 s while playing and at once on pause / play / a jump / the next episode / going to the background
    var pushPos: ((String, Int, Double, Double, String) -> Void)?
    private var pushAt = Date.distantPast, pushIdx = -1, pushPaused = false, pushLast = 0.0
    private func posPush(_ why: String? = nil) {
        guard let m = mpv, let push = pushPos, m.duration > 60, m.position > 5 else { return }
        let paused = m.getString("pause") == "yes"
        var reason = why
        if reason == nil {
            if m.playlistPos != pushIdx { reason = "file" }
            else if paused != pushPaused { reason = paused ? "pause" : "play" }
            else if abs(m.position - pushLast) > 8 && !paused && Date().timeIntervalSince(pushAt) > 3 { reason = "seek" }
            else if !paused && Date().timeIntervalSince(pushAt) >= 12 { reason = "tick" }
        }
        pushIdx = m.playlistPos; pushPaused = paused
        pushLast = m.position + 1.0   // (it moves a second between looks)
        guard let r = reason else { return }
        pushAt = Date()
        push(job.n, m.playlistPos, m.position, m.duration, r)
    }
    private struct Skips { var intro: [Double]?; var recap: [Double]?; var outro: [Double]?; var auto: Bool }
    private var skips: [Int: Skips] = [:]
    private var askedSkips = Set<Int>()
    private var skipAction: String?
    private var autoSkippedAt: Double = -1
    private let skipButton = UIButton(type: .system)
    private var hideTimer: Timer?
    private var scrubbing = false
    private var paused = false
    // v1.9.6: how far a skip goes, the sleep timer, subtitle timing
    private var skipSecs = 10
    private var sleepAt: Date?
    private var sleepNoted = false
    private var sleepEndOf = -1
    private var sleepTimer: Timer?
    private static var carriedSleep: (at: Date, handedAt: Date)?   // v1.0.71 (iOS)
    private let noteLabel = UILabel()
    private var prefetch: Prefetch?
    private var pickedAudio: String?, pickedSub: String?
    // v1.9.6: how fast files load here, how often this one stopped to load
    private var bwSum = 0.0, bwN = 0, stalls = 0, firstStall = Date(), stallNoted = false
    // v1.0.58: for the play log, and the way the file comes (straight from the source; this account's PC only if that
    // fails, and back to the source if it stops to load twice through the PC)
    private let openedAt = Date()
    private var startMs = -1, stallSecs = 0.0, stallSince: Date?
    private var videoCodec = "", audioCodec = "", fileKind = "", fileBytes = 0, videoHeight = 0
    private var viaPC = false, triedPC = false, pcStalls = 0, pcEntry = -1, usedPC = false
    private func mediaInfo(_ m: MPV) {
        guard videoCodec.isEmpty, startMs >= 0 else { return }
        videoCodec = m.getString("video-format") ?? ""
        audioCodec = m.getString("audio-codec-name") ?? ""
        fileKind = String((m.getString("file-format") ?? "").split(separator: ",").first ?? "")
        fileBytes = Int(m.getString("file-size") ?? "") ?? 0
        videoHeight = Int(m.getString("video-params/h") ?? "") ?? 0
    }
    // the file didn't play from its source: once, through this account's PC (when it answers on this Wi-Fi)
    private func tryThroughPC(_ m: MPV) -> Bool {
        let i = m.playlistPos, pos = m.position
        guard !triedPC, job.rb != nil, i >= 0, i < job.items.count else { return false }
        triedPC = true
        job.throughPC { [weak self] r in
            guard let self, !self.finished, let m = self.mpv else { return }
            guard i < r.items.count, r.items[i].u != self.job.items[i].u else { self.mpvEnded(error: true); return }
            self.viaPC = true; self.usedPC = true; self.pcStalls = 0; self.pcEntry = i
            self.note("Trying through your PC")
            m.reroute(i, url: r.items[i].u, viaPC: true, at: pos)
        }
        return true
    }
    private func leavePC(_ m: MPV) {
        let i = m.playlistPos
        guard viaPC, i >= 0, i < job.items.count else { return }
        viaPC = false
        note("Back to loading straight from the source")
        m.reroute(i, url: job.items[i].u, viaPC: false, at: m.position)
    }

    init(job: PlayJob, done: @escaping (PlayResult) -> Void) {
        self.job = job
        self.done = done
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .landscapeRight }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        videoView.backgroundColor = .black
        view.addSubview(videoView)
        layerView.contentsScale = UIScreen.main.nativeScale
        layerView.framebufferOnly = true
        layerView.backgroundColor = UIColor.black.cgColor
        videoView.layer.addSublayer(layerView)
        buildControls()
        spinner.color = .white
        spinner.startAnimating()
        view.addSubview(spinner)

        let m = MPV(layer: layerView, job: job)
        m.delegate = self
        mpv = m
        if let sk = job.sk, [5, 10, 15, 30, 60].contains(sk) { skipSecs = sk }
        if let sd = job.sd, abs(sd) > 0.001 { m.setString("sub-delay", String(format: "%.3f", sd)) }
        applySkipIcons()
        Prefetch.clean()
        prefetch = Prefetch(mpv: m, job: job)
        setupPiP(m)   // v1.0.80 (iOS)
        // v1.0.71 (iOS): a sleep timer set in the player before (Next on the last entry / autoplay handed the next episode
        // to a new player) carries on here — it was lost, so the timer never stopped anything
        if let c = Self.carriedSleep, Date().timeIntervalSince(c.handedAt) < 120 { sleepAt = c.at }
        Self.carriedSleep = nil
        sleepTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.sleepTick(); self?.dropTick(); self?.capTick(); self?.prefetch?.tick(); self?.loadTick(); self?.stuckTick(); self?.audioCheck() }
        titleLabel.text = job.items.first?.t ?? job.t ?? ""

        let tap = UITapGestureRecognizer(target: self, action: #selector(toggleControls))
        let dbl = UITapGestureRecognizer(target: self, action: #selector(doubleTap(_:)))
        dbl.numberOfTapsRequired = 2
        tap.require(toFail: dbl)
        videoView.addGestureRecognizer(tap)
        videoView.addGestureRecognizer(dbl)
        NotificationCenter.default.addObserver(self, selector: #selector(background), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(foreground), name: UIApplication.willEnterForegroundNotification, object: nil)
        UIApplication.shared.isIdleTimerDisabled = true
        setupRemote()
        showControls()
    }

    // ---- v1.16.5: AirPods, headphones, Control Center and the lock screen: tap to pause / play, double / triple
    // tap to skip, the title and progress shown; taking the AirPods out (or unplugging) pauses, as iOS apps do
    private var remoteTargets: [(MPRemoteCommand, Any)] = []
    private var lastNowPlaying = Date.distantPast
    // v1.16.12: frames this device couldn't show in time (a file heavier than it decodes) — checked every 5 s
    private var dropsAt: Int = -1, dropBad = 0, dropTicks = 0, slowHeight = 0, slowEased = false
    // v1.16.15: the buffer filled to its limit before the end of the file — the storage has no more room: the limit
    // grows when space was freed meanwhile; otherwise a note (once) says why it loads in steps
    private var capTicks = 0, capHits = 0, capNoted = false
    private func capTick() {
        capTicks += 1
        guard capTicks % 5 == 0, let m = mpv, m.maxBytes > 0 else { return }
        let cs = m.getString("demuxer-cache-state") ?? ""
        if cs.isEmpty || cs.range(of: "\"eof\"\\s*:\\s*true", options: .regularExpression) != nil { return }
        guard let r = cs.range(of: "\"fw-bytes\"\\s*:\\s*\\d+", options: .regularExpression),
              let fw = Int64(cs[r].split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? ""), Double(fw) >= Double(m.maxBytes) * 0.9 else { return }
        capHits += 1
        let gib: Int64 = 1 << 30
        let more = min(24 * gib, m.maxBytes + Prefetch.freeBytes() - 3 * gib)
        if more > m.maxBytes + (512 << 20) {
            m.maxBytes = more
            m.setString("demuxer-max-bytes", "\(more >> 20)MiB")
        } else if !capNoted {
            capNoted = true
            let ahead = Double(m.getString("demuxer-cache-duration") ?? "") ?? 0
            note("This iPhone's storage is nearly full, so Aperature loads about \(max(1, Int(ahead / 60))) minutes ahead as you watch. Free up some space and whole films load in the background again.")
        }
    }
    private func dropTick() {
        dropTicks += 1
        // v1.0.80 (iOS): not while PiP has the picture (mpv's null output and screenshots drop frames by design —
        // that isn't this device failing the file); counting starts over afterwards
        if pip?.videoIsOff == true { dropsAt = -1; dropBad = 0; return }
        guard dropTicks % 5 == 0, let m = mpv else { return }
        let drops = (Int(m.getString("frame-drop-count") ?? "") ?? 0) + (Int(m.getString("decoder-frame-drop-count") ?? "") ?? 0)
        let playing = !paused && m.getString("paused-for-cache") != "yes" && m.position > 3
        if dropsAt >= 0 && playing {
            dropBad = drops - dropsAt > 24 ? dropBad + 1 : 0
            if dropBad >= 2 && !slowEased {
                slowEased = true
                slowHeight = Int(m.getString("height") ?? "") ?? 2160
                if slowHeight <= 0 { slowHeight = 2160 }
                m.setString("video-sync", "audio"); m.setString("framedrop", "vo")
                note("This device can't keep up with this file — Aperature picks lighter files here from now on")
            }
        }
        dropsAt = drops
    }
    private func setupRemote() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
        try? AVAudioSession.sharedInstance().setActive(true)
        UIApplication.shared.beginReceivingRemoteControlEvents()
        let c = MPRemoteCommandCenter.shared()
        func on(_ cmd: MPRemoteCommand, _ f: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
            cmd.isEnabled = true
            remoteTargets.append((cmd, cmd.addTarget(handler: f)))
        }
        on(c.playCommand) { [weak self] _ in self?.mpv?.setFlag("pause", false); return .success }
        on(c.pauseCommand) { [weak self] _ in self?.mpv?.setFlag("pause", true); return .success }
        on(c.togglePlayPauseCommand) { [weak self] _ in self?.mpv?.togglePause(); return .success }
        c.skipForwardCommand.preferredIntervals = [NSNumber(value: skipSecs)]
        c.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipSecs)]
        on(c.skipForwardCommand) { [weak self] _ in guard let self else { return .commandFailed }; self.mpv?.seek(by: Double(self.skipSecs)); return .success }
        on(c.skipBackwardCommand) { [weak self] _ in guard let self else { return .commandFailed }; self.mpv?.seek(by: -Double(self.skipSecs)); return .success }
        on(c.nextTrackCommand) { [weak self] _ in self?.nextEpisode(); return .success }
        on(c.changePlaybackPositionCommand) { [weak self] e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.mpv?.seek(to: e.positionTime); return .success
        }
        NotificationCenter.default.addObserver(self, selector: #selector(routeChanged(_:)), name: AVAudioSession.routeChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(audioInterrupted(_:)), name: AVAudioSession.interruptionNotification, object: nil)
        updateNowPlaying(force: true)
    }
    private func teardownRemote() {
        for (cmd, t) in remoteTargets { cmd.removeTarget(t) }
        remoteTargets.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.routeChangeNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.interruptionNotification, object: nil)
    }
    private func updateNowPlaying(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastNowPlaying) > 4 else { return }
        lastNowPlaying = Date()
        var info: [String: Any] = [MPMediaItemPropertyTitle: titleLabel.text ?? (job.t ?? "Aperature")]
        if let t = job.t, t != titleLabel.text { info[MPMediaItemPropertyAlbumTitle] = t }
        if let m = mpv {
            if m.duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = m.duration }
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = m.position
        }
        info[MPNowPlayingInfoPropertyPlaybackRate] = paused ? 0.0 : 1.0
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    @objc private func routeChanged(_ n: Notification) {
        guard let raw = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt, AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
        DispatchQueue.main.async { [weak self] in self?.mpv?.setFlag("pause", true) }   // (the AirPods came out)
    }
    @objc private func audioInterrupted(_ n: Notification) {
        guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt, AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
        DispatchQueue.main.async { [weak self] in self?.mpv?.setFlag("pause", true) }    // (a call, Siri…)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        videoView.frame = view.bounds
        layerView.frame = videoView.bounds
        pip?.layer.frame = videoView.bounds   // v1.0.80 (iOS): behind the Metal layer, the same size
        layoutPiPCover()
        overlay.frame = view.bounds
        shade.frame = overlay.bounds
        spinner.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        layoutControls()
    }

    // ---- controls
    private func symbol(_ b: UIButton, _ name: String, _ size: CGFloat, _ label: String) {
        b.setImage(UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .semibold)), for: .normal)
        b.tintColor = b === playButton ? UIColor(red: 0.04, green: 0.05, blue: 0.07, alpha: 1) : .white
        b.accessibilityLabel = label
    }
    private func buildControls() {
        overlay.backgroundColor = .clear
        shade.colors = [UIColor.black.withAlphaComponent(0.65).cgColor, UIColor.clear.cgColor, UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.75).cgColor]
        shade.locations = [0, 0.28, 0.62, 1]
        overlay.layer.addSublayer(shade)
        view.addSubview(overlay)

        symbol(closeButton, "xmark", 20, "Close")
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        symbol(tracksButton, "captions.bubble", 20, "Subtitles")
        tracksButton.showsMenuAsPrimaryAction = true
        tracksButton.menu = UIMenu(title: "Subtitles", children: [UIDeferredMenuElement.uncached { [weak self] done in done(self?.subsMenu() ?? []) }])
        symbol(settingsButton, "gearshape.fill", 20, "Settings")
        settingsButton.showsMenuAsPrimaryAction = true
        settingsButton.menu = UIMenu(title: "Settings", children: [UIDeferredMenuElement.uncached { [weak self] done in done(self?.moreMenus() ?? []) }])
        speedButton.setTitle("1×", for: .normal)
        speedButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .bold)
        speedButton.setTitleColor(.white, for: .normal)
        speedButton.accessibilityLabel = "Speed"
        speedButton.showsMenuAsPrimaryAction = true
        speedButton.menu = UIMenu(title: "Speed", children: [UIDeferredMenuElement.uncached { [weak self] done in done(self?.speedMenu() ?? []) }])
        boostButton.setTitle("BOOST", for: .normal)
        boostButton.titleLabel?.font = .systemFont(ofSize: 12, weight: .heavy)
        boostButton.accessibilityLabel = "Boost: louder, with theater sound (hold for levels)"
        boostButton.addTarget(self, action: #selector(toggleBoost), for: .touchUpInside)
        boostButton.menu = UIMenu(title: "Boost", children: [UIDeferredMenuElement.uncached { [weak self] done in done(self?.boostLevels() ?? []) }])
        symbol(audioButton, "globe", 20, "Audio language")
        audioButton.showsMenuAsPrimaryAction = true
        audioButton.menu = UIMenu(title: "Audio language", children: [UIDeferredMenuElement.uncached { [weak self] done in done(self?.audioMenu() ?? []) }])
        symbol(pipButton, "pip.enter", 20, "Picture in Picture")   // v1.0.80 (iOS)
        pipButton.addTarget(self, action: #selector(startPiP), for: .touchUpInside)
        pipButton.isHidden = true
        symbol(muteButton, "speaker.wave.2.fill", 20, "Mute or unmute")
        muteButton.addTarget(self, action: #selector(toggleMute), for: .touchUpInside)
        symbol(backButton, "gobackward.10", 34, "Back 10 seconds")
        backButton.addTarget(self, action: #selector(back10), for: .touchUpInside)
        symbol(fwdButton, "goforward.10", 34, "Forward 10 seconds")
        fwdButton.addTarget(self, action: #selector(fwd10), for: .touchUpInside)
        symbol(playButton, "pause.fill", 46, "Play or pause")
        playButton.addTarget(self, action: #selector(togglePlay), for: .touchUpInside)
        symbol(nextButton, "forward.end.fill", 20, "Next episode")
        nextButton.setTitle("  Next", for: .normal)
        nextButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        nextButton.setTitleColor(.white, for: .normal)
        nextButton.backgroundColor = UIColor.white.withAlphaComponent(0.16)
        nextButton.layer.cornerRadius = 18
        nextButton.contentEdgeInsets = UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 16)
        nextButton.addTarget(self, action: #selector(nextEpisode), for: .touchUpInside)
        nextButton.isHidden = !episodic

        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        for l in [timeLabel, leftLabel] {
            l.textColor = UIColor.white.withAlphaComponent(0.85)
            l.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        }
        leftLabel.textAlignment = .right
        slider.minimumTrackTintColor = UIColor(red: 0.49, green: 0.36, blue: 1, alpha: 1)
        slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.25)
        slider.setThumbImage(UIImage(systemName: "circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14))?.withTintColor(.white, renderingMode: .alwaysOriginal), for: .normal)
        slider.addTarget(self, action: #selector(scrubStart), for: .touchDown)
        slider.addTarget(self, action: #selector(scrubMove), for: .valueChanged)
        slider.addTarget(self, action: #selector(scrubEnd), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        for v in [closeButton, titleLabel, pipButton, tracksButton, audioButton, muteButton, speedButton, boostButton, settingsButton, backButton, playButton, fwdButton, nextButton, slider, timeLabel, leftLabel] as [UIView] { overlay.addSubview(v) }
        // v1.9.6: glassy round buttons over the picture (the play button the accent), a thicker scrubber
        for (b, accent) in [(playButton, true), (backButton, false), (fwdButton, false), (closeButton, false), (pipButton, false), (tracksButton, false), (audioButton, false), (muteButton, false), (speedButton, false), (boostButton, false), (settingsButton, false)] {
            b.backgroundColor = accent ? UIColor(white: 0.96, alpha: 0.95) : UIColor.white.withAlphaComponent(0.14)
            b.tintColor = accent ? UIColor(red: 0.04, green: 0.05, blue: 0.07, alpha: 1) : .white
            b.layer.cornerCurve = .continuous
            b.layer.shadowColor = UIColor.black.cgColor; b.layer.shadowOpacity = 0.35; b.layer.shadowRadius = 10; b.layer.shadowOffset = .zero
        }
        nextButton.backgroundColor = UIColor(white: 0.96, alpha: 0.95)
        nextButton.setTitleColor(UIColor(red: 0.04, green: 0.05, blue: 0.07, alpha: 1), for: .normal)
        nextButton.tintColor = UIColor(red: 0.04, green: 0.05, blue: 0.07, alpha: 1)
        slider.minimumTrackTintColor = .white   // (v1.16.1: white, as the website and the Windows player)
        titleLabel.font = .systemFont(ofSize: 18, weight: .bold)
        titleLabel.layer.shadowColor = UIColor.black.cgColor; titleLabel.layer.shadowOpacity = 0.6; titleLabel.layer.shadowRadius = 6; titleLabel.layer.shadowOffset = .zero
        skipButton.setTitleColor(.white, for: .normal)
        skipButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        skipButton.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        skipButton.layer.borderColor = UIColor.white.withAlphaComponent(0.85).cgColor
        skipButton.layer.borderWidth = 1
        skipButton.layer.cornerRadius = 10
        skipButton.contentEdgeInsets = UIEdgeInsets(top: 10, left: 18, bottom: 10, right: 18)
        skipButton.isHidden = true
        skipButton.addTarget(self, action: #selector(doSkip), for: .touchUpInside)
        view.addSubview(skipButton)     // on the picture itself: it shows even while the controls are hidden
        noteLabel.textColor = .white
        noteLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        noteLabel.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        noteLabel.textAlignment = .center
        noteLabel.layer.cornerRadius = 10
        noteLabel.clipsToBounds = true
        noteLabel.alpha = 0
        noteLabel.numberOfLines = 2
        noteLabel.adjustsFontSizeToFitWidth = true
        noteLabel.minimumScaleFactor = 0.75
        view.addSubview(noteLabel)
    }
    private func layoutControls() {
        let b = view.bounds, safe = view.safeAreaInsets
        let side = max(20, max(safe.left, safe.right) + 8)
        closeButton.frame = CGRect(x: side, y: max(16, safe.top + 6), width: 44, height: 44)
        titleLabel.frame = CGRect(x: closeButton.frame.maxX + 8, y: closeButton.frame.minY, width: b.width - side - closeButton.frame.maxX - 16, height: 44)
        // v1.0.80 (iOS): the PiP button at the top right, the title making room for it
        pipButton.frame = CGRect(x: b.width - side - 44, y: closeButton.frame.minY, width: 44, height: 44)
        if !pipButton.isHidden { titleLabel.frame.size.width = max(0, pipButton.frame.minX - 8 - titleLabel.frame.minX) }
        playButton.frame = CGRect(x: b.midX - 40, y: b.midY - 40, width: 80, height: 80)
        backButton.frame = CGRect(x: playButton.frame.minX - 110, y: b.midY - 32, width: 64, height: 64)
        fwdButton.frame = CGRect(x: playButton.frame.maxX + 46, y: b.midY - 32, width: 64, height: 64)
        // v1.16.1: as the Windows bar — the seek bar with the time and the length at its ends, then a row of buttons:
        // mute on the left; Next, speed, Boost, subtitles, audio, settings on the right
        let bottom = b.height - max(14, safe.bottom + 6)
        let bs: CGFloat = 40, gap: CGFloat = 8, rowY = bottom - bs
        muteButton.frame = CGRect(x: side, y: rowY, width: bs, height: bs)
        var x = b.width - side
        for v in [settingsButton, audioButton, tracksButton] as [UIButton] { x -= bs; v.frame = CGRect(x: x, y: rowY, width: bs, height: bs); x -= gap }
        x -= 64; boostButton.frame = CGRect(x: x, y: rowY, width: 64, height: bs); x -= gap
        x -= 48; speedButton.frame = CGRect(x: x, y: rowY, width: 48, height: bs); x -= gap
        nextButton.sizeToFit()
        let compact = x - muteButton.frame.maxX < nextButton.frame.width + 16
        nextButton.setTitle(compact ? "" : "  Next", for: .normal)
        nextButton.sizeToFit()
        let nw = max(bs, nextButton.frame.width)
        nextButton.frame = CGRect(x: x - nw, y: rowY + 2, width: nw, height: bs - 4)
        let seekY = rowY - 40
        timeLabel.frame = CGRect(x: side, y: seekY, width: 64, height: 30)
        leftLabel.frame = CGRect(x: b.width - side - 64, y: seekY, width: 64, height: 30)
        slider.frame = CGRect(x: timeLabel.frame.maxX + 8, y: seekY, width: leftLabel.frame.minX - timeLabel.frame.maxX - 16, height: 30)
        for b in [playButton, backButton, fwdButton, closeButton, pipButton, tracksButton, audioButton, muteButton, settingsButton] { b.layer.cornerRadius = b.bounds.height / 2 }
        for b in [speedButton, boostButton] { b.layer.cornerRadius = b.bounds.height / 2 }
        paintBoost()
        skipButton.sizeToFit()
        skipButton.frame = CGRect(x: b.width - side - skipButton.frame.width, y: bottom - 150, width: skipButton.frame.width, height: 44)   // v1.9.6: higher, clear of the bar
        let noteW = min(b.width - 2 * side, noteLabel.intrinsicContentSize.width + 32)
        noteLabel.frame = CGRect(x: b.midX - noteW / 2, y: max(16, safe.top + 6) + 56, width: noteW, height: 52)
    }

    // ---- v1.9.6: a short note over the picture
    private func note(_ text: String) {
        noteLabel.text = text
        view.setNeedsLayout()
        view.bringSubviewToFront(noteLabel)
        noteLabel.layer.removeAllAnimations()
        noteLabel.alpha = 1
        UIView.animate(withDuration: 0.4, delay: 1.8, options: [.beginFromCurrentState], animations: { self.noteLabel.alpha = 0 })
    }
    private func skipIcon(_ dir: String) -> String {
        let n = [5, 10, 15, 30, 45, 60, 75, 90].contains(skipSecs) ? skipSecs : 10
        let name = "go\(dir).\(n)"
        return UIImage(systemName: name) != nil ? name : "go\(dir)"
    }
    private func applySkipIcons() {
        symbol(backButton, skipIcon("backward"), 34, "Back \(skipSecs) seconds")
        symbol(fwdButton, skipIcon("forward"), 34, "Forward \(skipSecs) seconds")
    }

    // ---- v1.9.6: sleep timer (stops and keeps your place), subtitle timing, skip amount — in the tracks menu
    private func subDelay() -> Double { Double(mpv?.getString("sub-delay") ?? "") ?? 0 }
    private func delayText(_ s: Double) -> String {
        abs(s) < 0.001 ? "In sync" : (s > 0 ? "+" : "−") + String(format: "%g", (abs(s) * 100).rounded() / 100) + " s " + (s > 0 ? "(later)" : "(earlier)")
    }
    private func nudgeSubs(_ by: Double) {
        let v = ((max(-60, min(60, subDelay() + by))) * 20).rounded() / 20
        mpv?.setString("sub-delay", String(format: "%.3f", v))
        note("Subtitles: " + delayText(v))
    }
    private func moreMenus() -> [UIMenuElement] {
        let timing = UIMenu(title: "Subtitle timing · " + delayText(subDelay()), image: UIImage(systemName: "timer"), children:
            [(-0.5, "Earlier −0.5 s"), (0.5, "Later +0.5 s"), (-0.1, "Earlier −0.1 s"), (0.1, "Later +0.1 s"), (-2.0, "Earlier −2 s"), (2.0, "Later +2 s")].map { (by, t) in
                UIAction(title: t) { [weak self] _ in self?.nudgeSubs(by) }
            } + [UIAction(title: "Back to the file’s timing") { [weak self] _ in self?.mpv?.setString("sub-delay", "0"); self?.note("Subtitles: in sync") }])
        var sleepTitle = "Sleep timer"
        if let at = sleepAt { sleepTitle += " · \(max(1, Int(ceil(at.timeIntervalSinceNow / 60)))) min left" } else if sleepEndOf >= 0 { sleepTitle += " · end of episode" }
        var sleepItems: [UIMenuElement] = [UIAction(title: "End of this episode", state: sleepEndOf >= 0 ? .on : .off) { [weak self] _ in
            guard let self else { return }
            self.sleepAt = nil; self.sleepEndOf = self.mpv?.playlistPos ?? 0; self.note("Sleep timer: end of this episode")
        }]
        sleepItems += [15, 30, 45, 60, 90, 120].map { n -> UIMenuElement in
            UIAction(title: n < 60 || n % 60 != 0 ? "\(n) minutes" : "\(n / 60) hour" + (n == 60 ? "" : "s")) { [weak self] _ in
                guard let self else { return }
                self.sleepEndOf = -1; self.sleepNoted = false; self.sleepAt = Date().addingTimeInterval(Double(n) * 60); self.note("Sleep timer: \(n) minutes")
            }
        }
        if sleepAt != nil || sleepEndOf >= 0 { sleepItems.append(UIAction(title: "Off") { [weak self] _ in self?.sleepAt = nil; self?.sleepEndOf = -1; self?.note("Sleep timer off") }) }
        let sleep = UIMenu(title: sleepTitle, image: UIImage(systemName: "moon.zzz"), children: sleepItems)
        let skip = UIMenu(title: "Skip amount · \(skipSecs) s", image: UIImage(systemName: "goforward"), children: [5, 10, 15, 30, 60].map { n in
            UIAction(title: "\(n) seconds", state: n == skipSecs ? .on : .off) { [weak self] _ in
                guard let self else { return }
                self.skipSecs = n; self.applySkipIcons(); self.note("Skip: \(n) seconds")
            }
        })
        // v1.12.5: Settings, as Crunchyroll lays them out: Autoplay, subtitle opacity, then the rest
        var top: [UIMenuElement] = []
        if episodic {
            top.append(UIAction(title: "Autoplay", image: UIImage(systemName: "play.square.stack"), state: autoplay ? .on : .off) { [weak self] _ in
                guard let self else { return }
                self.autoplay.toggle(); self.changedAuto = true
                self.mpv?.setString("keep-open", self.autoplay ? "yes" : "always")
                self.note("Autoplay " + (self.autoplay ? "on" : "off"))
            })
        }
        let opacity = UIMenu(title: "Subtitle opacity · \(subOpacity)%", image: UIImage(systemName: "circle.lefthalf.filled"), children: [100, 75, 50, 25].map { n in
            UIAction(title: "\(n)%" + (n == 100 ? " (solid)" : ""), state: n == subOpacity ? .on : .off) { [weak self] _ in
                guard let self else { return }
                self.subOpacity = n; self.changedOpacity = true
                for (k, v) in MPV.subLook(sc: self.job.sc, sb: self.job.sb, so: n) { self.mpv?.setString(k, v) }
                self.note("Subtitles \(n)%")
            }
        })
        // v1.12.12: volume boost, like Miruro's — louder than the file's own 100%
        let boost = UIMenu(title: volBoost > 100 ? "Boost · \(volBoost)% (theater sound)" : "Boost · Off", image: UIImage(systemName: "speaker.wave.3"), children: [100, 125, 150, 200, 250, 300, 350, 400].map { n in
            UIAction(title: n == 100 ? "Off" : "\(n)%" + (n >= 350 ? " (IMAX)" : ""), state: n == volBoost ? .on : .off) { [weak self] _ in self?.setBoost(n) }
        })
        return [UIMenu(title: "", options: .displayInline, children: top + [boost, opacity, timing, sleep, skip])]
    }
    // v1.16.15: time's up: paused, and "Still watching?" for 2 minutes; no answer: it closes, this episode saved from its start
    private var askUntil: Date?
    private var askAlert: UIAlertController?
    private var sleepReset = false
    private func askText(_ s: Int) -> String { "Closing in \(s / 60):\(String(format: "%02d", s % 60)) — this episode starts from the beginning next time." }
    private func startAsk() {
        guard let m = mpv, askUntil == nil else { return }
        m.setFlag("pause", true)
        askUntil = Date().addingTimeInterval(120)
        let a = UIAlertController(title: "Still watching?", message: askText(120), preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Keep watching", style: .default) { [weak self] _ in
            self?.askUntil = nil; self?.askAlert = nil; self?.mpv?.setFlag("pause", false)
        })
        a.addAction(UIAlertAction(title: "Stop", style: .cancel) { [weak self] _ in
            self?.askUntil = nil; self?.askAlert = nil; self?.finish(error: false)
        })
        askAlert = a
        present(a, animated: true)
    }
    private var wrongLen = false
    private func sleepTick() {
        guard let m = mpv, !finished else { return }
        // v1.16.22: far longer than an episode can be: another video — closed at once, the page plays the next file
        if let ml = job.ml, ml > 0, m.duration > Double(ml), m.position < 120 { wrongLen = true; finish(error: false); return }
        if let until = askUntil {
            // answered another way: playing again (AirPods, the lock screen, Control Center)
            if m.getString("pause") != "yes" { askAlert?.dismiss(animated: true); askAlert = nil; askUntil = nil; return }
            let left = Int(ceil(until.timeIntervalSinceNow))
            if left <= 0 {
                let a = askAlert
                askAlert = nil; askUntil = nil; sleepReset = true
                if let a, a.presentingViewController != nil { a.dismiss(animated: false) { [weak self] in self?.finish(error: false) } } else { finish(error: false) }
                return
            }
            askAlert?.message = askText(left)
            return
        }
        // v1.0.55 (the owner: a finished episode is watched, one you skipped or left isn't): each one played past 90%
        if m.duration > 60 && m.position >= m.duration * 0.9 { finishedIdx.insert(m.playlistPos) }
        extSubsTick()   // (v1.0.56)
        planner.tick(m, paused: paused, userSub: pickedSub != nil, userAudio: pickedAudio != nil)   // the audio/subtitle plan: followed once it's here
        posPush()   // (v1.0.57)
        if let at = sleepAt {
            let left = at.timeIntervalSinceNow
            if left <= 60 && !sleepNoted { sleepNoted = true; note("Sleeping in 1 minute"); showControls() }
            if left <= 0 { sleepAt = nil; startAsk() }
        } else if sleepEndOf >= 0 {
            if m.playlistPos != sleepEndOf || (m.duration > 60 && m.position >= m.duration - 1.5) { sleepEndOf = -1; startAsk() }
        }
    }

    // ---- Skip intro / recap, Next episode
    // v1.0.56 (the owner: subtitles "sometimes appear, sometimes don't"): your addons' subtitles for each episode, sent by the
    // page as it finds them — added once the file is loaded; when the file has nothing in your subtitle language, the best
    // of them (sent best first) is turned on. Before, only subtitles inside the file were there.
    private var extSubs: [Int: [[String: String]]] = [:]
    private var extAdded = Set<Int>()
    func setSubs(index: Int, list: [[String: String]]) { extSubs[index] = list; extAdded.remove(index) }
    private func extSubsTick() {
        guard let m = mpv, m.duration > 0 else { return }
        let i = m.playlistPos
        guard !extAdded.contains(i), let list = extSubs[i] else { return }
        extAdded.insert(i)
        let before = Set(m.tracks().filter { $0.type == "sub" }.map { $0.id })
        for x in list {
            guard let u = x["u"], u.hasPrefix("https://") || u.hasPrefix("http://") else { continue }
            m.command(["sub-add", u, "auto", x["t"] ?? "Subtitles", x["l"] ?? ""])
        }
        guard let want = job.sl, !want.isEmpty, want != "-", pickedSub == nil, !planner.decides(i) else { return }   // (the plan chose: it stands; a plan with nothing usable doesn't stop this)
        let all = m.tracks().filter { $0.type == "sub" }
        if all.contains(where: { $0.selected && Self.sameLang($0.lang, want) }) { return }
        if let t = all.first(where: { !before.contains($0.id) && Self.sameLang($0.lang, want) }) { m.select(t, type: "sub") }
    }
    func setSkips(index: Int, intro: [Double]?, recap: [Double]?, outro: [Double]?, auto: Bool) {
        skips[index] = Skips(intro: intro, recap: recap, outro: outro, auto: auto)
    }
    private func inSeg(_ s: [Double]?, _ p: Double) -> Bool { guard let s, s.count == 2 else { return false }; return p >= s[0] && p < s[1] - 1 }
    private func skipTick(_ pos: Double, _ dur: Double) {
        guard let m = mpv else { return }
        let i = m.playlistPos
        if dur > 0, !askedSkips.contains(i) { askedSkips.insert(i); askSkips?(job.n, i, Int(dur)) }
        let k = skips[i]
        var act: String? = nil, label = "", seg: [Double]? = nil
        if inSeg(k?.intro, pos) { act = "intro"; label = "Skip intro"; seg = k?.intro }
        else if inSeg(k?.recap, pos) { act = "recap"; label = "Skip recap"; seg = k?.recap }
        else if (m.hasNext || episodic) && (inSeg(k?.outro, pos) || (dur > 60 && pos > dur - 30)) { act = "next"; label = autoplay && dur > 0 && dur - pos <= 30 ? "Up next in \(max(1, Int((dur - pos).rounded(.up)))) s  ▶" : "Next episode  ▶" }
        if let k, k.auto, let seg, autoSkippedAt != seg[0] {     // the profile skips intros and recaps by itself
            autoSkippedAt = seg[0]
            m.seek(to: seg[1])
            act = nil
        }
        skipAction = act
        if act == nil { skipButton.isHidden = true; return }
        if skipButton.title(for: .normal) != label { skipButton.setTitle(label, for: .normal); view.setNeedsLayout() }
        skipButton.isHidden = false
    }
    @objc private func doSkip() {
        guard let m = mpv, let act = skipAction else { return }
        let k = skips[m.playlistPos]
        if act == "next" { nextEpisode() }
        else if let seg = act == "intro" ? k?.intro : k?.recap { m.seek(to: seg[1]) }
        skipButton.isHidden = true
    }

    // v1.14.0: only the languages the profile chose (the one playing always shows; a track whose language can't be
    // told stays unless its name says another language)
    private static let langCodes: [String: String] = ["eng": "eng", "en": "eng", "jpn": "jpn", "ja": "jpn", "spa": "spa", "es": "spa", "fre": "fre", "fra": "fre", "fr": "fre",
        "ger": "ger", "deu": "ger", "de": "ger", "ita": "ita", "it": "ita", "por": "por", "pt": "por", "kor": "kor", "ko": "kor", "chi": "chi", "zho": "chi", "zh": "chi",
        "ara": "ara", "ar": "ara", "rus": "rus", "ru": "rus", "hin": "hin", "hi": "hin"]
    private static let langWords: [String: String] = ["english": "eng", "japanese": "jpn", "spanish": "spa", "french": "fre", "german": "ger", "italian": "ita",
        "portuguese": "por", "korean": "kor", "chinese": "chi", "arabic": "ara", "russian": "rus", "hindi": "hin"]
    private func allowList(_ csv: String?) -> Set<String>? {
        let s = Set((csv ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        return s.isEmpty ? nil : s
    }
    private func langOK(_ t: Track) -> Bool {
        guard let allow = allowList(t.type == "sub" ? job.sa : job.aa) else { return true }
        if t.selected { return true }
        var known = false
        if let c = Self.langCodes[t.lang.lowercased().components(separatedBy: "-").first ?? ""] { known = true; if allow.contains(c) { return true } }
        let words = t.title.lowercased()
        for (w, c) in Self.langWords where words.range(of: "\\b" + w + "\\b", options: .regularExpression) != nil { known = true; if allow.contains(c) { return true } }
        return !known
    }
    // once a file is going: subtitles or audio the profile didn't choose are switched for one it did (subtitles off when none)
    private var langsCheckedPos = -1
    private func enforceLangs() {
        guard let m = mpv, m.position > 1, langsCheckedPos != m.playlistPos, !planner.decides(m.playlistPos) else { return }   // (the plan chose: it decides)
        langsCheckedPos = m.playlistPos
        defer { matchSubs() }   // v1.17.23
        let all = m.tracks()
        for type in ["audio", "sub"] where allowList(type == "sub" ? job.sa : job.aa) != nil {
            let list = all.filter { $0.type == type }
            guard let cur = list.first(where: { $0.selected }) else { continue }
            let probe = Track(id: cur.id, type: cur.type, title: cur.title, lang: cur.lang, selected: false)
            if langOK(probe) { continue }
            if let ok = list.first(where: { !$0.lang.isEmpty && langOK(Track(id: $0.id, type: $0.type, title: $0.title, lang: $0.lang, selected: false)) }) { m.select(ok, type: type) }
            else if type == "sub" { m.select(nil, type: "sub") }
        }
    }

    // v1.17.23: subtitles in the same language as the audio match what's said: of that language's tracks, a full / CC /
    // SDH / dub one first, never signs-and-songs only. "Same as the audio" (job.sm): they follow the audio's language.
    private static func sameLang(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        let base = { (x: String) -> String in let l = x.lowercased(); let two = ["eng": "en", "jpn": "ja", "spa": "es", "fre": "fr", "fra": "fr", "ger": "de", "deu": "de", "ita": "it", "por": "pt", "kor": "ko", "chi": "zh", "zho": "zh", "rus": "ru", "ara": "ar", "hin": "hi"]; return two[l] ?? String(l.prefix(2)) }
        return base(a) == base(b)
    }
    private static func subScore(_ title: String) -> Int {
        let t = title.lowercased()
        var sc = 0
        if t.range(of: "\\b(signs?|songs?|forced|lyrics|karaoke)\\b", options: .regularExpression) != nil { sc -= 6 }
        if t.range(of: "\\b(cc|sdh|closed ?captions?|hearing ?impaired|dub|dubbed|dubtitles?)\\b", options: .regularExpression) != nil { sc += 4 }
        if t.range(of: "\\b(full|dialogue)\\b", options: .regularExpression) != nil { sc += 1 }
        return sc
    }
    private func matchSubs() {
        guard let m = mpv, pickedSub == nil else { return }
        let all = m.tracks()
        guard let a = all.first(where: { $0.type == "audio" && $0.selected }), !a.lang.isEmpty else { return }
        let cur = all.first(where: { $0.type == "sub" && $0.selected })
        if (job.sm ?? 0) != 1 && !(cur.map { Self.sameLang($0.lang, a.lang) } ?? false) { return }
        let same = all.filter { $0.type == "sub" && Self.sameLang($0.lang, a.lang) }
        guard let best = same.max(by: { Self.subScore($0.title) < Self.subScore($1.title) }), Self.subScore(best.title) > -6, best.id != cur?.id else { return }
        m.select(best, type: "sub")
    }

    // v1.12.6: the file's audio tracks (a dual-audio release: English / Portuguese…); the pick is the show's from now on
    private func audioMenu() -> [UIMenuElement] {
        guard let mpv else { return [] }
        let audio = mpv.tracks().filter { $0.type == "audio" && langOK($0) }
        if audio.isEmpty { return [UIAction(title: "This file has no sound", attributes: .disabled) { _ in }] }
        return audio.map { t in
            UIAction(title: t.label, state: t.selected ? .on : .off) { [weak self] _ in
                self?.mpv?.select(t, type: "audio"); self?.mpv?.setString("mute", "no"); self?.paintMute()
                if !t.lang.isEmpty { self?.pickedAudio = t.lang }
                if (self?.job.sm ?? 0) == 1 { self?.matchSubs() }   // v1.17.23: the subtitles follow
                self?.note("Audio: " + t.label)
            }
        }
    }
    @objc private func toggleMute() {
        guard let m = mpv else { return }
        let muted = m.getString("mute") == "yes"
        m.setString("mute", muted ? "no" : "yes")
        paintMute()
        note(muted ? "Sound on" : "Muted")
        showControls()
    }
    private func paintMute() {
        let muted = mpv?.getString("mute") == "yes"
        muteButton.setImage(UIImage(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)), for: .normal)
    }
    // a few seconds in: a file with no sound track says so (rather than playing in silence)
    private func audioCheck() {
        enforceLangs()
        guard !audioChecked, let m = mpv, m.position > 3 else { return }
        audioChecked = true
        if !m.tracks().contains(where: { $0.type == "audio" }) { note("This file has no sound. Close it and choose another file.") }
        else if m.getString("aid") == "no" { m.setString("aid", "auto") }
        paintMute()
    }
    // v1.16.1: subtitles on their own button (the profile's languages; Off always there)
    private func subsMenu() -> [UIMenuElement] {
        guard let mpv else { return [] }
        let subs = mpv.tracks().filter { $0.type == "sub" && langOK($0) }
        var items: [UIMenuElement] = [UIAction(title: "Off", state: subs.contains { $0.selected } ? .off : .on) { [weak self] _ in self?.mpv?.select(nil, type: "sub"); self?.pickedSub = "-"; self?.note("Subtitles off") }]
        items += subs.map { t in UIAction(title: t.label, state: t.selected ? .on : .off) { [weak self] _ in self?.mpv?.select(t, type: "sub"); if !t.lang.isEmpty { self?.pickedSub = t.lang }; self?.note("Subtitles: " + t.label) } }
        if subs.isEmpty { items.append(UIAction(title: "No subtitles in this file", attributes: .disabled) { _ in }) }
        return items
    }
    private func speedMenu() -> [UIMenuElement] {
        let cur = Double(mpv?.getString("speed") ?? "1") ?? 1
        return [0.5, 0.75, 1.0, 1.25, 1.5, 2.0].map { v in
            UIAction(title: String(format: "%g×", v), state: abs(cur - v) < 0.01 ? .on : .off) { [weak self] _ in
                self?.mpv?.setString("speed", String(v))
                self?.pip?.speed = v   // v1.0.80 (iOS): the PiP window's progress runs at this speed
                self?.speedButton.setTitle(String(format: "%g×", v), for: .normal)
                self?.note(v == 1 ? "Normal speed" : String(format: "Speed %g×", v))
            }
        }
    }
    // Boost: a tap turns it on (150%) or off, as on Windows; holding the button picks a level
    @objc private func toggleBoost() { setBoost(volBoost > 100 ? 100 : 150) }
    private func setBoost(_ n: Int) {
        volBoost = n; changedBoost = true
        mpv?.setString("volume", String(n)); mpv?.setString("af", MPV.theaterFilter(n, eq: job.be))   // (v1.17.4: the profile's tuned Boost)
        note(n == 100 ? "Boost off" : "Boost \(n)% — theater sound")
        paintBoost()
    }
    private func boostLevels() -> [UIMenuElement] {
        [100, 125, 150, 200, 250, 300, 350, 400].map { n in
            UIAction(title: n == 100 ? "Off" : "\(n)%" + (n >= 350 ? " (IMAX)" : ""), state: n == volBoost ? .on : .off) { [weak self] _ in self?.setBoost(n) }
        }
    }
    private func paintBoost() {
        let on = volBoost > 100
        boostButton.backgroundColor = on ? UIColor(white: 0.96, alpha: 0.95) : UIColor.white.withAlphaComponent(0.14)
        boostButton.setTitleColor(on ? UIColor(red: 0.04, green: 0.05, blue: 0.07, alpha: 1) : .white, for: .normal)
        boostButton.setTitle(on ? "\(volBoost)%" : "BOOST", for: .normal)
    }
    private func trackMenu() -> [UIMenuElement] {
        guard let mpv else { return [] }
        let all = mpv.tracks()
        let audio = all.filter { $0.type == "audio" && langOK($0) }.map { t in
            UIAction(title: t.label, state: t.selected ? .on : .off) { [weak self] _ in self?.mpv?.select(t, type: "audio"); if !t.lang.isEmpty { self?.pickedAudio = t.lang }; if (self?.job.sm ?? 0) == 1 { self?.matchSubs() } }
        }
        let subs = all.filter { $0.type == "sub" && langOK($0) }
        var subActions: [UIMenuElement] = [UIAction(title: "Off", state: subs.contains { $0.selected } ? .off : .on) { [weak self] _ in self?.mpv?.select(nil, type: "sub"); self?.pickedSub = "-" }]
        subActions += subs.map { t in UIAction(title: t.label, state: t.selected ? .on : .off) { [weak self] _ in self?.mpv?.select(t, type: "sub"); if !t.lang.isEmpty { self?.pickedSub = t.lang } } }
        return [UIMenu(title: "Audio", options: .displayInline, children: audio), UIMenu(title: "Subtitles", options: .displayInline, children: subActions)] + moreMenus()
    }

    @objc private func toggleControls() { overlay.alpha > 0.5 ? hideControls() : showControls() }
    private func showControls() {
        UIView.animate(withDuration: 0.2) { self.overlay.alpha = 1 }
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            guard let self, !self.paused, !self.scrubbing else { return }
            self.hideControls()
        }
    }
    private func hideControls() { UIView.animate(withDuration: 0.25) { self.overlay.alpha = 0 } }

    @objc private func doubleTap(_ g: UITapGestureRecognizer) {
        let x = g.location(in: view).x
        if x < view.bounds.width / 3 { mpv?.seek(by: -Double(skipSecs)); flash(skipIcon("backward")) }
        else if x > view.bounds.width * 2 / 3 { mpv?.seek(by: Double(skipSecs)); flash(skipIcon("forward")) }
        else { togglePlay() }
    }
    private func flash(_ name: String) {
        let iv = UIImageView(image: UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 40, weight: .semibold)))
        iv.tintColor = .white
        iv.sizeToFit()
        iv.center = CGPoint(x: name.contains("backward") ? view.bounds.width / 5 : view.bounds.width * 4 / 5, y: view.bounds.midY)
        view.addSubview(iv)
        UIView.animate(withDuration: 0.6, animations: { iv.alpha = 0; iv.transform = CGAffineTransform(scaleX: 1.3, y: 1.3) }) { _ in iv.removeFromSuperview() }
    }

    @objc private func togglePlay() { mpv?.togglePause(); showControls() }
    @objc private func back10() { mpv?.seek(by: -Double(skipSecs)); showControls() }
    @objc private func fwd10() { mpv?.seek(by: Double(skipSecs)); showControls() }
    // v1.12.3: an episode always has Next: the next one in the playlist, else Aperature finds it (closes with nx = 1)
    private var episodic: Bool { job.items.contains { !($0.c ?? "").isEmpty } }
    private var wantNext = 0
    private lazy var autoplay: Bool = job.an != 0          // v1.12.5: the player's Settings
    private lazy var volBoost: Int = { let v = job.vb ?? 100; return v > 100 && v <= 400 ? v : 100 }()
    private var changedBoost = false
    private lazy var subOpacity: Int = (job.so ?? 100) >= 25 && (job.so ?? 100) <= 100 ? (job.so ?? 100) : 100
    private var changedAuto = false, changedOpacity = false
    @objc private func nextEpisode() {
        if mpv?.hasNext ?? false { mpv?.next(); showControls(); return }
        wantNext = 1
        finish(error: false)
    }
    @objc private func scrubStart() { scrubbing = true; hideTimer?.invalidate() }
    @objc private func scrubMove() {
        let d = mpv?.duration ?? 0
        timeLabel.text = clock(Double(slider.value) * d)
    }
    @objc private func scrubEnd() {
        let d = mpv?.duration ?? 0
        if d > 0 { mpv?.seek(to: Double(slider.value) * d) }
        scrubbing = false
        showControls()
    }

    private func clock(_ t: Double) -> String {
        let s = max(0, Int(t)), h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    // ---- mpv
    func mpvTime(_ position: Double, _ duration: Double) {
        pip?.update(position: position, duration: duration, paused: paused, played: mpv?.everPlayed ?? false)   // v1.0.80 (iOS)
        if spinner.isAnimating && position > 0 { spinner.stopAnimating() }
        if startMs < 0 && position > 0 { startMs = Int(Date().timeIntervalSince(openedAt) * 1000) }
        skipTick(position, duration)
        guard !scrubbing else { return }
        timeLabel.text = clock(position)
        leftLabel.text = duration > 0 ? "-" + clock(duration - position) : ""
        slider.value = duration > 0 ? Float(position / duration) : 0
        updateNowPlaying()
    }
    func mpvPaused(_ p: Bool) {
        paused = p
        if let m = mpv { pip?.update(position: m.position, duration: m.duration, paused: p, played: m.everPlayed) }   // v1.0.80 (iOS)
        symbol(playButton, p ? "play.fill" : "pause.fill", 46, "Play or pause")
        updateNowPlaying(force: true)
        if p { showControls() }
    }
    func mpvBuffering(_ b: Bool) {
        b ? spinner.startAnimating() : spinner.stopAnimating()
        if !b, let since = stallSince { stallSecs += Date().timeIntervalSince(since); stallSince = nil }
        guard b, let m = mpv, m.everPlayed, Date().timeIntervalSince(m.seekedAt) > 4 else { return }   // (not a jump's own load)
        if stalls == 0 { firstStall = Date() }
        stalls += 1
        stallSince = Date()
        // v1.0.58: it starts at once, but after a stop it gathers more each time before going on (one longer wait
        // instead of stop after stop): 4 s, 10 s, then 20 s
        m.setString("cache-pause-wait", stalls == 1 ? "4" : stalls == 2 ? "10" : "20")
        if viaPC { pcStalls += 1; if pcStalls >= 2 { leavePC(m) } }
        if !stallNoted && stalls >= 3 && Date().timeIntervalSince(firstStall) < 300 {
            stallNoted = true
            let size = Double(m.getString("file-size") ?? "") ?? 0, dur = m.duration
            let need = size > 0 && dur > 0 ? size * 8 / dur / 1e6 : 0, have = bwN > 0 ? bwSum / Double(bwN) * 8 / 1e6 : 0
            note(need > 0 && have > 0 ? String(format: "Keeps stopping to load: needs ~%.0f Mbps, you have ~%.0f. Pick a smaller file.", need, have) : "Keeps stopping to load: pick a smaller file")
        }
    }
    // v1.16.34: stuck loading for 15 s while you want it playing (the connection died): opened again where it was;
    // three times without moving on: the file didn't play
    private var stuckSecs = 0, stuckAt: Double = -1, kicks = 0
    private func stuckTick() {
        guard let m = mpv, !paused, !finished, m.position > 1 else { stuckSecs = 0; return }
        let waiting = m.getString("paused-for-cache") == "yes" || m.getString("core-idle") == "yes"
        if waiting && abs(m.position - stuckAt) < 0.5 { stuckSecs += 1 } else { stuckSecs = 0; stuckAt = m.position; if !waiting { kicks = 0 } }
        guard stuckSecs >= 15 else { return }
        stuckSecs = 0
        kicks += 1
        if kicks > 3 { mpvEnded(error: true); return }
        m.kick()
    }
    private func loadTick() {
        if let m = mpv { mediaInfo(m) }
        guard let m = mpv, m.getString("demuxer-cache-idle") != "yes", let cs = Double(m.getString("cache-speed") ?? ""), cs > 50000 else { return }
        bwSum += cs; bwN += 1
    }
    private var shownIndex = -1
    func mpvFile(_ index: Int) {
        // v1.0.71 (iOS): auto-skip is once per segment per entry — the next episode's intro at the same time as this
        // one's (common) was never skipped, because autoSkippedAt still held the last episode's start
        if index != shownIndex { shownIndex = index; autoSkippedAt = -1 }
        if index != pcEntry { viaPC = false }   // (v1.0.58: the next episodes come from their source)
        if index < job.items.count { titleLabel.text = job.items[index].t ?? job.t ?? "" }
        updateNowPlaying(force: true)
        nextButton.isHidden = !((mpv?.hasNext ?? false) || episodic)
        audioChecked = false
        spinner.startAnimating()
    }
    private var errorShown = false
    func mpvEnded(error: Bool) {
        // v1.0.71 (iOS): not after closing (an event still on its way presented an alert on a closing player), and one
        // error alert only (the stuck-loading check repeats every 15 s); with something else already over the player
        // (the sleep timer's question), present() would fail and OK would never come — it just closes
        guard !finished else { return }
        if error {
            if let m = mpv, tryThroughPC(m) { return }
            guard !errorShown else { return }
            errorShown = true
            if presentedViewController != nil { finish(error: true); return }
            let a = UIAlertController(title: "This file didn't play", message: "Pick another file for it in Aperature.", preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in self?.finish(error: true) })
            present(a, animated: true)
        } else {
            // the last one played to its end: Aperature plays the next (autoplay on)
            // v1.0.71 (iOS): …unless the sleep timer said "end of this episode" (or is asking "Still watching?"): it
            // ended in the last ~1.5 s before sleepTick saw it, and autoplay went on to the next episode
            if sleepEndOf >= 0 || askUntil != nil { sleepEndOf = -1 }
            else if episodic && autoplay { wantNext = 2 }
            finish(error: false)
        }
    }

    // v1.0.80 (iOS): with Picture in Picture, leaving the app while it plays carries on in the PiP window. Without it
    // (no PiP on this device, paused, PiP turned off in Settings, or it didn't start) the player pauses as it always has.
    @objc private func background() {
        posPush("bg")
        if let p = pip, p.isActive { return }                       // (started from the button: it plays on in PiP)
        if let p = pip, p.isPossible, !paused, !finished, mpv?.everPlayed == true {
            // iOS starts PiP by itself (canStartPictureInPictureAutomaticallyFromInline): no GPU drawing meanwhile, and
            // if it hasn't started in a second, as before
            p.videoOff(true)
            pipWait?.cancel()
            let w = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pipWait = nil
                guard !self.finished, !(self.pip?.isActive ?? false), UIApplication.shared.applicationState == .background else { return }
                self.bgPaused = true
                self.mpv?.pauseForBackground(true)
                self.pip?.videoOff(false)   // (no picture now; the normal one comes back with the app)
            }
            pipWait = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: w)
            return
        }
        bgPaused = true
        mpv?.pauseForBackground(true)
    }
    @objc private func foreground() {
        pipWait?.cancel(); pipWait = nil
        if let p = pip, !p.isActive, p.videoIsOff { p.videoOff(false); layerView.isHidden = false }   // (back before PiP began)
        if bgPaused { bgPaused = false; mpv?.pauseForBackground(false) }
    }

    // ---- v1.0.80 (iOS): Picture in Picture
    private func setupPiP(_ m: MPV) {
        pipCover.backgroundColor = .black
        pipCover.isHidden = true
        let icon = UIImageView(image: UIImage(systemName: "pip", withConfiguration: UIImage.SymbolConfiguration(pointSize: 44, weight: .regular)))
        icon.tintColor = UIColor.white.withAlphaComponent(0.7)
        icon.tag = 1
        let label = UILabel()
        label.text = "Playing in Picture in Picture"
        label.textColor = UIColor.white.withAlphaComponent(0.7)
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textAlignment = .center
        label.tag = 2
        pipCover.addSubview(icon)
        pipCover.addSubview(label)
        pipCover.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(stopPiP)))
        view.insertSubview(pipCover, aboveSubview: videoView)
        guard let p = PlayerPiP(mpv: m) else { return }
        pip = p
        videoView.layer.insertSublayer(p.layer, below: layerView)
        p.onWillStart = { [weak self] in self?.pipWillStart() }
        p.onStop = { [weak self] restoring in self?.pipStopped(restoring: restoring) }
        p.onPlay = { [weak self] play in self?.mpv?.setFlag("pause", !play) }
        p.onSkip = { [weak self] s in self?.mpv?.seek(by: s) }
        pipButton.isHidden = false
        view.setNeedsLayout()
    }
    private func layoutPiPCover() {
        pipCover.frame = view.bounds
        if let icon = pipCover.viewWithTag(1) { icon.sizeToFit(); icon.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY - 18) }
        if let label = pipCover.viewWithTag(2) { label.frame = CGRect(x: 16, y: view.bounds.midY + 18, width: max(0, view.bounds.width - 32), height: 24) }
    }
    @objc private func startPiP() {
        guard let p = pip else { return }
        if !p.start() { note("Picture in Picture isn't available for this video right now") }
    }
    @objc private func stopPiP() { pip?.stop() }
    private func pipWillStart() {
        pipWait?.cancel(); pipWait = nil
        layerView.isHidden = true            // (its last picture would show, stale, when PiP ends)
        pipCover.isHidden = false
        view.bringSubviewToFront(pipCover)   // (over the controls: a tap anywhere brings the picture back)
        hideControls()
    }
    private func pipStopped(restoring: Bool) {
        pipWait?.cancel(); pipWait = nil
        pipCover.isHidden = true
        if !restoring && UIApplication.shared.applicationState == .background {
            // the PiP window closed with the app away: paused, as when the app goes away without PiP (the background
            // return then works as always — the picture back, the file opened again where it was if it's been long)
            if !bgPaused && !finished { bgPaused = true; mpv?.pauseForBackground(true) }
            pip?.videoOff(false)
            layerView.isHidden = false
            return
        }
        // back in the app (the PiP window's button, a tap on the cover, or PiP couldn't start): the full player at the
        // same spot — the normal picture back (mpv opens it again at the same time); the Metal layer shows once it has
        pip?.videoOff(false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, !(self.pip?.isActive ?? false) else { return }
            self.layerView.isHidden = false
        }
        showControls()
    }

    // ---- closing: tell Aperature where you stopped
    @objc private func close() { finish(error: false) }
    // v1.0.71 (iOS): another file asked for while this one is up (a second tap on Play, a link from Safari): this player
    // closes properly first — reported, mpv destroyed — and `then` runs once it is off screen. (It used to be dismissed
    // with no finish: its mpv kept playing, heard under the new one, with its timers and prefetch left running.)
    private var afterClose: (() -> Void)?
    func closeForNewFile(then: @escaping () -> Void) {
        afterClose = then
        finish(error: false)
    }
    private var finishedIdx = Set<Int>()   // (v1.0.55: the episodes played to the end, by their place in the list)
    private func finish(error: Bool) {
        guard !finished else { return }
        // (the sleep timer's question on screen: it goes first, so the player itself closes)
        if let a = askAlert, a.presentingViewController != nil { askAlert = nil; askUntil = nil; a.dismiss(animated: false) { [weak self] in self?.finish(error: error) }; return }
        finished = true
        hideTimer?.invalidate()
        sleepTimer?.invalidate()
        prefetch?.stop()
        prefetch = nil
        UIApplication.shared.isIdleTimerDisabled = false
        teardownRemote()
        let m = mpv
        let sd = (subDelay() * 1000).rounded() / 1000
        pipWait?.cancel(); pipWait = nil   // v1.0.80 (iOS)
        if let since = stallSince { stallSecs += Date().timeIntervalSince(since); stallSince = nil }
        var result = PlayResult(n: job.n, i: m?.playlistPos ?? 0, p: sleepReset ? 0 : Int(m?.position ?? 0), d: Int(m?.duration ?? 0), e: error ? 1 : 0, sd: sd, sk: skipSecs, bw: bwN > 0 ? Int(bwSum / Double(bwN)) : 0, st: stalls, pa: pickedAudio, ps: pickedSub, nx: wantNext, an: changedAuto ? (autoplay ? 1 : 0) : nil, vb: changedBoost ? volBoost : nil, so: changedOpacity ? subOpacity : nil, sl: slowHeight, cm: Int((m?.maxBytes ?? 0) >> 20), cf: Int((m?.freeAtStart ?? 0) >> 30), ch: capHits, zz: sleepReset ? 1 : 0, wl: wrongLen ? 1 : 0, w: finishedIdx.sorted())
        result.ms = startMs; result.bs = Int(stallSecs.rounded()); result.vc = videoCodec; result.ac = audioCodec; result.fm = fileKind
        result.fs = fileBytes; result.vh = videoHeight; result.rt = usedPC ? "home-pc" : "direct"
        if wantNext > 0, let at = sleepAt { Self.carriedSleep = (at: at, handedAt: Date()) } else { Self.carriedSleep = nil }   // v1.0.71 (iOS)
        // v1.0.80 (iOS): PiP ends with the player; mpv is destroyed once no PiP frame is being taken from it
        if let p = pip { pip = nil; p.shutdown { m?.destroy() } } else { m?.destroy() }
        mpv = nil
        // v1.0.71 (iOS): dismissed from the presenter, so an alert over the player (the error alert, when Next comes from
        // the lock screen / AirPods) goes with it — dismiss() on the player itself only took the alert down and left a
        // dead player on screen; and never presented at all: straight on
        let complete = { [done] in
            done(result)
            let a = self.afterClose
            self.afterClose = nil
            a?()
        }
        if let host = presentingViewController { host.dismiss(animated: true, completion: complete) } else { complete() }
    }
}
