import AppKit

// Overlay scroll bars by default, in the chrome and in web pages (WebKit's content processes take
// the style from this process). With a mouse attached, "Automatic" otherwise gives pages a solid
// white scroll bar track. A registered default sits below the user's own choice, so
// System Settings → "Show scroll bars: Always" still wins.
UserDefaults.standard.register(defaults: ["AppleShowScrollBars": "WhenScrolling"])

// Before anything opens a file: bring the pre-rename "Aegis" data folder over to "Vane".
MainActor.assumeIsolated { DataMigration.run() }

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    withExtendedLifetime(delegate) {
        app.run()
    }
}
