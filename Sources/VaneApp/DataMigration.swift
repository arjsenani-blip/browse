import AppKit

/// One-time move of the pre-rename data folder (~/Library/Application Support/Aegis, or
/// "Aegis Dev" for development bundles) to its Vane name. Runs before anything opens a file.
///
/// The bundle ID never changed, so preferences, WebKit data, Keychain passwords and the
/// default-browser setting carry over on their own; only this folder had the old name.
enum DataMigration {
    static func run() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dev = Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true
        let old = base.appending(path: dev ? "Aegis Dev" : "Aegis", directoryHint: .isDirectory)
        let new = base.appending(path: dev ? "Vane Dev" : "Vane", directoryHint: .isDirectory)
        guard fm.fileExists(atPath: old.path) else { return }

        // An old copy still running holds the session open and would keep writing to the old
        // folder. Moving it underneath would split the data, so ask to quit it first.
        let me = ProcessInfo.processInfo.processIdentifier
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != me }) {
            let alert = NSAlert()
            alert.messageText = "Quit Aegis to finish updating to Vane"
            alert.informativeText = "Aegis is now called Vane. Quit the old Aegis app, then open Vane again to bring over your tabs, history and settings."
            alert.runModal()
            exit(0)
        }

        if !fm.fileExists(atPath: new.path) {
            try? fm.moveItem(at: old, to: new)
            return
        }
        // Both exist: the new folder can only hold caches a development build made before the
        // move (filters, favicons), so the old folder's items win.
        let items = (try? fm.contentsOfDirectory(at: old, includingPropertiesForKeys: nil)) ?? []
        for item in items {
            let dest = new.appending(path: item.lastPathComponent)
            if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
            try? fm.moveItem(at: item, to: dest)
        }
        if ((try? fm.contentsOfDirectory(atPath: old.path)) ?? []).isEmpty {
            try? fm.removeItem(at: old)
        }
    }
}
