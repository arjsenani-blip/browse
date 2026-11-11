import AppKit

/// The main menu. Every action is also reachable from the command palette,
/// which shows the same shortcuts.
@MainActor
enum Menus {
    static func build(target: AppDelegate) -> NSMenu {
        let main = NSMenu()

        main.addItem(submenu("Aegis", [
            item("About Aegis", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "", target: nil),
            .separator(),
            item("Settings…", #selector(AppDelegate.showSettings), ",", target: target),
            item("Add Extension…", #selector(AppDelegate.addExtension), "", target: target),
            item("Make Aegis the Default Browser", #selector(AppDelegate.makeDefaultBrowser), "", target: target),
            .separator(),
            item("Hide Aegis", #selector(NSApplication.hide(_:)), "h", target: nil),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], target: nil),
            .separator(),
            item("Quit Aegis", #selector(NSApplication.terminate(_:)), "q", target: nil),
        ]))

        main.addItem(submenu("File", [
            item("New Tab", #selector(AppDelegate.newTab), "t", target: target),
            item("New Window", #selector(AppDelegate.newWindow), "n", target: target),
            item("New Private Window", #selector(AppDelegate.newPrivateWindow), "n", [.command, .shift], target: target),
            item("Open Location…", #selector(AppDelegate.openLocation), "l", target: target),
            .separator(),
            item("Close Tab", #selector(AppDelegate.closeTab), "w", target: target),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift], target: nil),
            item("Reopen Closed Tab", #selector(AppDelegate.reopenClosedTab), "t", [.command, .shift], target: target),
            .separator(),
            item("Import from Arc, Chrome or Safari…", #selector(AppDelegate.importBrowserData), "", target: target),
            item("Import Passwords…", #selector(AppDelegate.importPasswords), "", target: target),
            item("Export Passwords…", #selector(AppDelegate.exportPasswords), "", target: target),
        ]))

        main.addItem(submenu("Edit", [
            item("Undo", Selector(("undo:")), "z", target: nil),
            item("Redo", Selector(("redo:")), "z", [.command, .shift], target: nil),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x", target: nil),
            item("Copy", #selector(NSText.copy(_:)), "c", target: nil),
            item("Paste", #selector(NSText.paste(_:)), "v", target: nil),
            item("Select All", #selector(NSText.selectAll(_:)), "a", target: nil),
            .separator(),
            item("Copy Link", #selector(AppDelegate.copyURL), "c", [.command, .shift], target: target),
            item("Find…", #selector(AppDelegate.find), "f", target: target),
            item("Find Next", #selector(AppDelegate.findNext), "g", target: target),
            item("Find Previous", #selector(AppDelegate.findPrevious), "g", [.command, .shift], target: target),
        ]))

        main.addItem(submenu("View", [
            item("Command Palette", #selector(AppDelegate.commandPalette), "k", target: target),
            item("Toggle Sidebar", #selector(AppDelegate.toggleSidebar), "s", target: target),
            item("Tabs on Top", #selector(AppDelegate.toggleTabsOnTop), "", target: target),
            item("Downloads and Media", #selector(AppDelegate.showLibrary), "j", [.command, .option], target: target),
            item("Reader", #selector(AppDelegate.toggleReader), "r", [.command, .shift], target: target),
            item("Reader Theme", #selector(AppDelegate.cycleReaderTheme), "r", [.command, .option], target: target),
            .separator(),
            item("Reload Page", #selector(AppDelegate.reload), "r", target: target),
            item("Actual Size", #selector(AppDelegate.zoomReset), "0", target: target),
            item("Zoom In", #selector(AppDelegate.zoomIn), "+", target: target),
            // ⌘= is what people press for zoom in (no Shift needed on most layouts).
            hidden(item("Zoom In", #selector(AppDelegate.zoomIn), "=", target: target)),
            item("Zoom Out", #selector(AppDelegate.zoomOut), "-", target: target),
            .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control], target: nil),
        ]))

        var tabItems: [NSMenuItem] = [
            item("Back", #selector(AppDelegate.goBack), "[", target: target),
            item("Forward", #selector(AppDelegate.goForward), "]", target: target),
            .separator(),
            item("Next Tab", #selector(AppDelegate.nextTab), "\t", [.control], target: target),
            // Shift turns Tab into back-tab (U+0019) before menu matching.
            item("Previous Tab", #selector(AppDelegate.previousTab), "\u{19}", [.control, .shift], target: target),
            hidden(item("Next Tab", #selector(AppDelegate.nextTab), "]", [.command, .shift], target: target)),
            hidden(item("Previous Tab", #selector(AppDelegate.previousTab), "[", [.command, .shift], target: target)),
            item("Pin / Unpin Tab", #selector(AppDelegate.togglePin), "p", [.command, .shift], target: target),
            item("Add to Favorites", #selector(AppDelegate.toggleFavorite), "d", target: target),
            item("Put Background Tabs to Sleep", #selector(AppDelegate.hibernateBackground), "h", [.command, .option, .control], target: target),
            .separator(),
        ]
        for n in 1...9 {
            let i = item(n == 9 ? "Last Tab" : "Tab \(n)", #selector(AppDelegate.selectTabNumber(_:)), "\(n)", target: target)
            i.tag = n - 1
            tabItems.append(i)
        }
        main.addItem(submenu("Tabs", tabItems))

        main.addItem(submenu("Spaces", [
            item("New Space", #selector(AppDelegate.newSpace), "n", [.command, .option], target: target),
            item("New Folder", #selector(AppDelegate.newFolder), "n", [.command, .option, .shift], target: target),
            item("Next Space", #selector(AppDelegate.nextSpace), "]", [.command, .option], target: target),
            item("Previous Space", #selector(AppDelegate.previousSpace), "[", [.command, .option], target: target),
        ]))

        main.addItem(submenu("Privacy", [
            item("Content Blocking", #selector(AppDelegate.toggleBlocking), "", target: target),
            item("Fingerprint Protection", #selector(AppDelegate.toggleFingerprinting), "", target: target),
            item("Strip Tracking Parameters", #selector(AppDelegate.toggleStripping), "", target: target),
            item("HTTPS Only", #selector(AppDelegate.toggleHTTPSOnly), "", target: target),
            .separator(),
            item("Update Filter Lists", #selector(AppDelegate.updateFilters), "", target: target),
            item("Clear This Space's Website Data…", #selector(AppDelegate.clearSpaceData), "", target: target),
            item("Clear History…", #selector(AppDelegate.clearHistory), "", target: target),
        ]))

        let window = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", target: nil),
            item("Zoom", #selector(NSWindow.performZoom(_:)), "", target: nil),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), "", target: nil),
        ])
        NSApp.windowsMenu = window.submenu
        main.addItem(window)
        return main
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        top.submenu = menu
        return top
    }

    /// Keeps a shortcut alive without showing a duplicate row.
    private static func hidden(_ i: NSMenuItem) -> NSMenuItem {
        i.isHidden = true
        i.allowsKeyEquivalentWhenHidden = true
        return i
    }

    private static func item(_ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = [.command], target: AnyObject?) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        i.target = target
        return i
    }
}
