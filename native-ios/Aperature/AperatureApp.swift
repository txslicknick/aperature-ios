// Aperature for iPhone — the Aperature app (the same one as on the web, every device) with its own native
// player: mpv (MPVKit), so every format plays in full quality inside Aperature.
// One source body. Many apertures. No compulsory simultaneity.
import SwiftUI
import AVFoundation

@main
struct AperatureApp: App {
    init() {
        // play with the ring/silent switch off, like a video app
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
        try? AVAudioSession.sharedInstance().setActive(true)
        // notifications: on from the start (iOS asks once), checked in the background too
        Notifier.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            WebScreen()
                // v1.12.10: a file handed over by the Aperature website (Safari / Home Screen): this app's player
                .onOpenURL { url in IncomingLink.shared.receive(url) }
                .ignoresSafeArea()
                .background(Color.black)
                .preferredColorScheme(.dark)
        }
    }
}
