// The Aperature web app (aperature.lol), full screen, with a bridge to the native player:
//   web → app:  window.webkit.messageHandlers.aperature.postMessage({ type: 'play', link: 'aperature-player:…' })
//   app → web:  window.__apNativeDone({ n, i, p, d, e })   (where you stopped, as Aperature Player for Windows says it)
import SwiftUI
import WebKit
import SafariServices

let siteURL = URL(string: "https://aperature.lol/")!
// project.yml WKAppBoundDomains: Aperature, the MyAnimeList and AniList sign-ins (they come back here), trailers
let appBoundSites = ["aperature.lol", "myanimelist.net", "anilist.co", "youtube-nocookie.com"]
func isAppBound(_ url: URL) -> Bool {
    guard let host = url.host?.lowercased() else { return false }
    return appBoundSites.contains { host == $0 || host.hasSuffix("." + $0) }
}

struct WebScreen: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> WebViewController { WebViewController() }
    func updateUIViewController(_ vc: WebViewController, context: Context) {}
}

final class WebViewController: UIViewController, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    private var web: WKWebView!
    private var player: PlayerViewController?

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = true
        config.applicationNameForUserAgent = "AperatureApp/1.0 Mobile/15E148 Safari/604.1"
        config.websiteDataStore = .default()
        config.limitsNavigationsToAppBoundDomains = true   // v1.0.58: turns the service worker on (offline opening)
        let ucc = WKUserContentController()
        ucc.add(WeakHandler(self), name: "aperature")
        ucc.addScriptMessageHandler(ChapterStore.shared, contentWorld: .page, name: "apStore")   // v1.0.58: saved chapters, in the app's own storage
        // v1.12: what this app can do (the page saves downloads through the app when it can)
        ucc.addUserScript(WKUserScript(source: "window.__apCaps = { download: 1, theater: 1, avplan: 1, chapterStore: 1 }; window.__apNative = 'ios';", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController = ucc

        web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.backgroundColor = .black
        web.scrollView.contentInsetAdjustmentBehavior = .never
        if #available(iOS 16.4, *) { web.isInspectable = true }
        view = web
        web.load(URLRequest(url: siteURL))
        // a notification tapped: its page here
        Notifier.shared.onOpen = { [weak self] u in self?.web.load(URLRequest(url: u)) }
        IncomingLink.shared.handler = { [weak self] link in self?.playIncoming(link) }
        Downloads.shared.send = { [weak self] m in
            guard let data = try? JSONSerialization.data(withJSONObject: [m]), let arr = String(data: data, encoding: .utf8) else { return }
            self?.web.evaluateJavaScript("window.__apDl && window.__apDl(\(arr)[0])", completionHandler: nil)
        }
    }

    // ---- web → app
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        // (only Aperature's own page: a sign-in page or a trailer in this web view gets no say over the app)
        guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.host == siteURL.host,
              let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "play":
            guard let link = body["link"] as? String, let job = PlayJob.decode(link: link) else { return }
            // v1.10.1: through this account's PC when it's on the same Wi-Fi (else straight from the source)
            job.throughPC { [weak self] j in self?.present(job: j) }
        case "skips":
            guard let p = player, let n = body["n"] as? String, n == p.jobId else { return }
            let seg: (Any?) -> [Double]? = { v in
                guard let a = v as? [Any], a.count == 2 else { return nil }
                let d = a.compactMap { ($0 as? NSNumber)?.doubleValue }
                return d.count == 2 ? d : nil
            }
            p.setSkips(index: (body["i"] as? NSNumber)?.intValue ?? 0, intro: seg(body["intro"]), recap: seg(body["recap"]), outro: seg(body["outro"]), auto: (body["auto"] as? Bool) ?? false)
        case "subs":   // v1.0.56: your addons' subtitles for an episode
            guard let p = player, let n = body["n"] as? String, n == p.jobId, let raw = body["list"] as? [[String: Any]] else { return }
            let list = raw.map { d in d.compactMapValues { $0 as? String } }
            p.setSubs(index: (body["i"] as? NSNumber)?.intValue ?? 0, list: list)
        case "avplan":   // the audio/subtitle plan for an episode (AvPlan.swift)
            guard let p = player, let n = body["n"] as? String, n == p.jobId, let plan = body["plan"] as? [String: Any] else { return }
            p.setPlan(index: (body["i"] as? NSNumber)?.intValue ?? 0, plan: plan)
        case "roku-open":
            RokuLauncher.open(typed: body["host"] as? String) { [weak self] r in
                guard let data = try? JSONEncoder().encode(r), let json = String(data: data, encoding: .utf8) else { return }
                DispatchQueue.main.async { self?.web.evaluateJavaScript("window.__apRokuDone && window.__apRokuDone(\(json))", completionHandler: nil) }
            }
        case "download":
            Downloads.shared.start(id: body["id"] as? String ?? "", url: body["url"] as? String ?? "", name: body["name"] as? String ?? "")
        case "download-cancel":
            Downloads.shared.cancel(id: body["id"] as? String ?? "")
        case "download-delete":
            Downloads.shared.delete(id: body["id"] as? String ?? "")
        case "download-keep":
            Downloads.shared.keep(ids: (body["ids"] as? [Any] ?? []).compactMap { $0 as? String })
        case "notify":
            Notifier.shared.setSession(token: body["token"] as? String ?? "", site: body["site"] as? String ?? "")
        default:
            break
        }
    }

    // v1.12.10: a file from the Aperature website: the page here first learns what it is (so where you stop is saved —
    // Continue Watching, MyAnimeList — as if it had been played from here), then this app's player plays it
    private var pageReady = false
    private var waiting: String?
    func playIncoming(_ link: String) {
        guard pageReady else { waiting = link; return }
        guard let job = PlayJob.decode(link: link) else { return }
        if let r = PlayJob.carriedRun(link: link) {
            web.evaluateJavaScript("window.__apAdoptRun && window.__apAdoptRun(\(r), \(PlayJob.jsString(job.n)))") { [weak self] _, _ in
                job.throughPC { j in self?.present(job: j) }
            }
        } else {
            job.throughPC { [weak self] j in self?.present(job: j) }
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // (the page's own code needs a moment after load to be ready for a handed-over file)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            self.pageReady = true
            if let l = self.waiting { self.waiting = nil; self.playIncoming(l) }
        }
    }

    // v1.0.71 (iOS): a file while another plays (a double tap on Play — two throughPC answers — or a link from Safari):
    // the one up closes properly first (reported, its mpv destroyed) and the newest file asked for then plays. Before,
    // the old player was only dismissed: its mpv went on playing (two sets of sound), its timers and prefetch with it.
    private var closingPlayer = false
    private var nextJob: PlayJob?
    private func present(job: PlayJob) {
        if closingPlayer { nextJob = job; return }
        if let p = player {
            closingPlayer = true
            nextJob = job
            p.closeForNewFile { [weak self] in
                guard let self else { return }
                self.closingPlayer = false
                if let j = self.nextJob { self.nextJob = nil; self.present(job: j) }
            }
            return
        }
        let vc = PlayerViewController(job: job) { [weak self] result in
            self?.player = nil
            self?.report(result)
        }
        vc.planner.event = { [weak self] code, ok in
            guard let data = try? JSONSerialization.data(withJSONObject: [code]), let arr = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.web.evaluateJavaScript("window.__apAvEvent && window.__apAvEvent(\(arr)[0], \(ok ? "true" : "false"))", completionHandler: nil) }
        }
        vc.askSkips = { [weak self] n, i, d in
            guard let data = try? JSONSerialization.data(withJSONObject: [n]), let arr = String(data: data, encoding: .utf8) else { return }
            self?.web.evaluateJavaScript("window.__apSkips && window.__apSkips(\(arr)[0], \(i), \(d))", completionHandler: nil)
        }
        // v1.0.57: where you are, every ~12 s and on pause / seek / next episode / background → window.__apNativeTick(n, i, p, d, why)
        vc.pushPos = { [weak self] n, i, p, d, why in
            guard let data = try? JSONSerialization.data(withJSONObject: [n, why]), let arr = String(data: data, encoding: .utf8) else { return }
            // (going to the background: iOS may suspend the page at once — a short background task lets the page send it)
            var bg = UIBackgroundTaskIdentifier.invalid
            if why == "bg" { bg = UIApplication.shared.beginBackgroundTask(expirationHandler: nil) }
            self?.web.evaluateJavaScript("window.__apNativeTick && window.__apNativeTick(\(arr)[0], \(i), \(p), \(d), \(arr)[1])", completionHandler: nil)
            if bg != .invalid { DispatchQueue.main.asyncAfter(deadline: .now() + 6) { UIApplication.shared.endBackgroundTask(bg) } }
        }
        vc.modalPresentationStyle = .fullScreen
        player = vc
        present(vc, animated: true)
    }

    // ---- app → web
    private func report(_ r: PlayResult) {
        guard let data = try? JSONEncoder().encode(r), let json = String(data: data, encoding: .utf8) else { return }
        web.evaluateJavaScript("window.__apNativeDone && window.__apNativeDone(\(json))", completionHandler: nil)
    }

    // ---- links: Aperature stays here; other apps (Outplayer, Infuse, VLC) open; other sites open in Safari views
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, let scheme = url.scheme?.lowercased() else { decisionHandler(.allow); return }
        // v1.0.58: the page itself only goes to the app-bound sites; any other one (a store, a forum, an add-on's setup
        // page) opens over it in Safari — here it would be refused. Frames inside the page are left to the page.
        if (scheme == "http" || scheme == "https") && action.targetFrame?.isMainFrame == true && !isAppBound(url) {
            if url.host?.hasSuffix("apps.apple.com") == true || player != nil || presentedViewController != nil { UIApplication.shared.open(url) }
            else { present(SFSafariViewController(url: url), animated: true) }
            decisionHandler(.cancel)
            return
        }
        if ["http", "https", "about", "blob", "data"].contains(scheme) {
            decisionHandler(.allow)
            return
        }
        if scheme == "aperature-player", let job = PlayJob.decode(link: url.absoluteString) {
            present(job: job)
        } else {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
        decisionHandler(.cancel)
    }

    // target=_blank (Trakt's page, an App Store link…): opened outside the app's page
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url {
            if url.scheme == "https" || url.scheme == "http" {
                if url.host?.hasSuffix("apps.apple.com") == true { UIApplication.shared.open(url) }
                else { present(SFSafariViewController(url: url), animated: true) }
            } else {
                UIApplication.shared.open(url)
            }
        }
        return nil
    }

    // window.alert / confirm from the page
    // v1.0.71 (iOS): not while the player (or anything else) is over the page — present() fails there, the alert and its
    // completion handler are dropped uncalled, and WebKit raises an exception for that (a crash); the page is just answered
    private var canAsk: Bool { view.window != nil && presentedViewController == nil && player == nil }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard canAsk else { completionHandler(); return }
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        present(a, animated: true)
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard canAsk else { completionHandler(false); return }
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        present(a, animated: true)
    }

    // the page reloads if iOS dropped it in the background
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { webView.reload() }
}

// WKUserContentController keeps its handlers strongly; this keeps the page's controller free to go.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ t: WKScriptMessageHandler) { target = t }
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(ucc, didReceive: message)
    }
}

// v1.12.10: links opened from outside (the website's "Aperature app"), kept until the page is ready
final class IncomingLink {
    static let shared = IncomingLink()
    var handler: ((String) -> Void)? { didSet { if let h = handler, let p = pending { pending = nil; h(p) } } }
    private var pending: String?
    func receive(_ url: URL) {
        guard url.scheme?.lowercased() == "aperature-player" else { return }
        let s = url.absoluteString
        if let h = handler { h(s) } else { pending = s }
    }
}
