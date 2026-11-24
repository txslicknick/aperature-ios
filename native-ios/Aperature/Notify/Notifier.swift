// Aperature's notifications in the iPhone app. Apps installed with a free Apple ID can't get Apple's push, so the
// app checks the account's inbox itself (https://aperature.lol/api/push/inbox) when it opens, while it's
// open, and in the background whenever iOS lets it, and shows what's new as notifications. Ones the Home Screen
// version already got by push are left out, so nothing comes twice.
// One source body. Many apertures. No compulsory simultaneity.
import Foundation
import UserNotifications
import BackgroundTasks
import Security
import UIKit

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    static let refreshTask = "com.txslicknick.aperature.inbox"
    /// a notification tapped: the page opens this address
    var onOpen: ((URL) -> Void)?
    private var timer: Timer?
    private var busy = false

    // ---- on launch: ask once (on by default), and register the background check
    func start() {
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        c.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Notifier.refreshTask, using: nil) { task in
            self.handle(task as! BGAppRefreshTask)
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in self.schedule() }
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in self.check() }
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { _ in self.check() }
        check()
    }

    // ---- the page hands over the account's session ('' = signed out here)
    func setSession(token: String, site: String) {
        if token.isEmpty { Keychain.delete("session"); return }
        let first = Keychain.get("session") == nil
        Keychain.set("session", token)
        if let s = URL(string: site), s.scheme == "https", s.host == siteURL.host { UserDefaults.standard.set(site, forKey: "site") }
        // a new session: what's already in the inbox isn't news
        if first && UserDefaults.standard.double(forKey: "inboxSince") == 0 { UserDefaults.standard.set(Date().timeIntervalSince1970 * 1000, forKey: "inboxSince") }
        check()
    }

    func schedule() {
        let r = BGAppRefreshTaskRequest(identifier: Notifier.refreshTask)
        r.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(r)
    }

    private func handle(_ task: BGAppRefreshTask) {
        schedule()
        task.expirationHandler = { task.setTaskCompleted(success: false) }
        check { ok in task.setTaskCompleted(success: ok) }
    }

    // ---- the inbox: what's new since last time, shown as notifications
    func check(done: ((Bool) -> Void)? = nil) {
        guard !busy, let token = Keychain.get("session") else { done?(false); return }
        busy = true
        let since = UserDefaults.standard.double(forKey: "inboxSince")
        var c = URLComponents(url: siteURL.appendingPathComponent("api/push/inbox"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "since", value: String(Int64(since)))]
        var req = URLRequest(url: c.url!, timeoutInterval: 20)
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        req.setValue(siteURL.absoluteString.dropLast().description, forHTTPHeaderField: "Origin")
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            defer { self.busy = false }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 { Keychain.delete("session"); done?(false); return }
            guard code == 200, let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = obj["items"] as? [[String: Any]] else { done?(false); return }
            var newest = since
            for it in items {
                let at = (it["at"] as? NSNumber)?.doubleValue ?? 0
                newest = max(newest, at)
                if (it["pushed"] as? Bool) == true { continue }      // the Home Screen version already showed it
                self.show(id: it["id"] as? String ?? UUID().uuidString, title: it["title"] as? String ?? "Aperature",
                          body: it["body"] as? String ?? "", url: it["url"] as? String ?? "")
            }
            UserDefaults.standard.set(newest, forKey: "inboxSince")
            done?(true)
        }.resume()
    }

    private func show(id: String, title: String, body: String, url: String) {
        let n = UNMutableNotificationContent()
        n.title = title.isEmpty ? "Aperature" : title
        n.body = body
        n.sound = .default
        n.userInfo = ["url": url]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: n, trigger: nil))
    }

    // shown while the app is open too
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        let path = response.notification.request.content.userInfo["url"] as? String ?? ""
        if let u = URL(string: path, relativeTo: siteURL)?.absoluteURL, u.host == siteURL.host { DispatchQueue.main.async { self.onOpen?(u) } }
        done()
    }
}

// The session lives in the iPhone's keychain (this app only, this device only).
enum Keychain {
    private static func q(_ k: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.txslicknick.aperature", kSecAttrAccount as String: k]
    }
    static func set(_ k: String, _ v: String) {
        delete(k)
        var a = q(k)
        a[kSecValueData as String] = Data(v.utf8)
        a[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(a as CFDictionary, nil)
    }
    static func get(_ k: String) -> String? {
        var a = q(k)
        a[kSecReturnData as String] = true
        a[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(a as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func delete(_ k: String) { SecItemDelete(q(k) as CFDictionary) }
}
