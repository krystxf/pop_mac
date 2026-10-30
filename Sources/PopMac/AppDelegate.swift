import AppKit
import PopCore

/// The menu bar app, the macOS counterpart of Pop Shell's top bar indicator.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var manager: WindowManager?
    private let settingsWindow = SettingsWindowController()
    private let welcome = WelcomeWindowController()
    private var permissionTimer: Timer?
    private var configWatcher: DispatchSourceFileSystemObject?
    private var fileWatcher: DispatchSourceFileSystemObject?

    /// Why the config file could not be read, if it could not.
    private var configError: String?
    /// True if macOS revoked Accessibility access while Pop Mac ran.
    private var accessLost = false

    func applicationWillTerminate(_: Notification) {
        // The next start rebuilds this layout.
        manager?.saveLayout()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !takeOverFromOtherCopies() {
            // Two copies of the same build would fight over every window.
            NSApp.terminate(nil)
            return
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        if AX.isTrusted(prompt: false) {
            start()
            // For development: show the first-run window even with access.
            if ProcessInfo.processInfo.environment["POP_MAC_SHOW_WELCOME"] != nil {
                welcome.isTrusted = true
                welcome.show()
            }
        } else {
            welcome.show()
        }

        // Watches for access being granted at first, and revoked later.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAccess() }
        }
    }

    /// Bundle ids of every Pop Mac build: the release and a renamed "Pop Mac Prod" copy.
    private static let family = ["dev.krystof.popmac", "dev.krystof.popmac.prod"]

    /// Makes sure that only one Pop Mac manages windows.
    ///
    /// Another copy of this same build is already doing that, so this one quits.
    /// Another build (for example "Pop Mac Prod" beside a development build) is
    /// quit instead, so that starting a build switches to it.
    /// Returns false if this copy should quit.
    private func takeOverFromOtherCopies() -> Bool {
        guard let me = Bundle.main.bundleIdentifier else { return true }
        let myPID = ProcessInfo.processInfo.processIdentifier
        for id in Self.family {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: id) where app.processIdentifier != myPID {
                if id == me {
                    Log.warn("Pop Mac is already running (pid \(app.processIdentifier)); quitting")
                    return false
                }
                Log.info("quitting \(app.localizedName ?? id), so that this copy manages the windows")
                app.terminate()
            }
        }
        return true
    }

    private func checkAccess() {
        let trusted = AX.isTrusted(prompt: false)
        if manager == nil {
            guard trusted else { return }
            start()
            welcome.isTrusted = true
        } else if accessLost != !trusted {
            accessLost = !trusted
            updateIcon()
        }
    }

    private func start() {
        let settings: Settings
        do {
            settings = try Settings.load()
        } catch {
            configError = Self.describe(error)
            settings = Settings()
        }

        let manager = WindowManager(settings: settings)
        manager.onStateChange = { [weak self] in
            self?.updateIcon()
            self?.settingsWindow.refresh()
        }
        self.manager = manager
        manager.start()
        updateIcon()
        watchConfig()

        // For development: save images of the settings pages.
        if let folder = ProcessInfo.processInfo.environment["POP_MAC_SNAPSHOT_DIR"] {
            settingsWindow.snapshotPages(manager: manager, to: URL(fileURLWithPath: folder))
        }
    }

    private func updateIcon() {
        let image: NSImage? = if manager == nil || accessLost || configError != nil {
            NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Pop Mac needs attention")
        } else {
            Self.menuBarIcon(tiling: manager?.autoTiler != nil)
        }
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    /// The app icon's tile layout, drawn for the menu bar. Outlined tiles mean tiling is off.
    private static func menuBarIcon(tiling: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 16), flipped: false) { _ in
            let line: CGFloat = 1.3
            let area = NSRect(x: 1, y: 1.5, width: 16, height: 13)
            let gap: CGFloat = 1.8
            let half = (area.width - gap) / 2
            let tiles = [
                NSRect(x: area.minX, y: area.minY, width: half, height: area.height),
                NSRect(x: area.minX + half + gap, y: area.minY + (area.height + gap) / 2, width: half, height: (area.height - gap) / 2),
                NSRect(x: area.minX + half + gap, y: area.minY, width: half, height: (area.height - gap) / 2),
            ]
            NSColor.black.set()
            for tile in tiles {
                if tiling {
                    NSBezierPath(roundedRect: tile, xRadius: 1.5, yRadius: 1.5).fill()
                } else {
                    let path = NSBezierPath(roundedRect: tile.insetBy(dx: line / 2, dy: line / 2), xRadius: 1.2, yRadius: 1.2)
                    path.lineWidth = line
                    path.stroke()
                }
            }
            return true
        }
        image.accessibilityDescription = tiling ? "Pop Mac, tiling on" : "Pop Mac, tiling off"
        return image
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        guard let manager else {
            menu.addItem(disabled("Waiting for Accessibility access"))
            menu.addItem(item("Set Up Pop Mac…", #selector(showWelcome)))
            menu.addItem(.separator())
            menu.addItem(item("Quit Pop Mac", #selector(quit), key: "q"))
            return
        }

        if accessLost {
            menu.addItem(warning("Accessibility access was turned off"))
            menu.addItem(item("Open Accessibility Settings…", #selector(openAccessibility)))
            menu.addItem(.separator())
        }
        if configError != nil {
            menu.addItem(warning("The config file has an error"))
            menu.addItem(item("Show Error…", #selector(showConfigError)))
            menu.addItem(.separator())
        }

        menu.addItem(item("Tile Windows", #selector(toggleTiling), shortcut: .toggleTiling, on: manager.autoTiler != nil))
        menu.addItem(item("Float Focused Window", #selector(toggleFloating), shortcut: .toggleFloating))
        menu.addItem(.separator())
        menu.addItem(item("Keyboard Shortcuts…", #selector(showShortcuts)))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(showSettings), key: ","))
        menu.addItem(item("About Pop Mac", #selector(showAbout)))

        // Hold Option to show the debug item in place of About.
        let debug = item("Copy Tiling Tree", #selector(copyTree))
        debug.isAlternate = true
        debug.keyEquivalentModifierMask = .option
        menu.addItem(debug)

        menu.addItem(.separator())
        menu.addItem(item("Quit Pop Mac", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "", shortcut: Action? = nil, on: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.state = on ? .on : .off
        if let shortcut, let combo = manager?.settings.combos(for: shortcut).first {
            // Show the global shortcut on the right, like a key equivalent.
            let attributed = NSMutableAttributedString(string: title + "\t")
            attributed.append(NSAttributedString(string: combo.description, attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
            let paragraph = NSMutableParagraphStyle()
            paragraph.tabStops = [NSTextTab(textAlignment: .right, location: 240)]
            attributed.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: attributed.length))
            item.attributedTitle = attributed
        }
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        NSMenuItem(title: title, action: nil, keyEquivalent: "")
    }

    private func warning(_ title: String) -> NSMenuItem {
        let item = disabled(title)
        item.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        return item
    }

    // MARK: - Menu actions

    @objc private func toggleTiling() { manager?.toggleTiling() }
    @objc private func toggleFloating() { manager?.toggleFloating() }
    @objc private func showWelcome() { welcome.show() }

    @objc private func showSettings() {
        guard let manager else { return }
        settingsWindow.show(manager: manager)
    }

    @objc private func showShortcuts() {
        guard let manager else { return }
        settingsWindow.show(manager: manager, tab: .shortcuts)
    }

    @objc private func showAbout() {
        let credits = NSAttributedString(
            string: "A port of Pop Shell by System76 to macOS.\nLicensed under the GNU GPL v3.",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        )
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    @objc private func showConfigError() {
        guard let configError else { return }
        let alert = NSAlert()
        alert.messageText = "The config file has an error"
        alert.informativeText = configError + "\n\nPop Mac keeps the last good settings until the file is fixed."
        alert.addButton(withTitle: "Open Config File")
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(Settings.defaultURL)
        }
    }

    @objc private func copyTree() {
        guard let manager else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(manager.dumpTree(), forType: .string)
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Config file

    /// Reloads the settings when the config file changes on disk.
    ///
    /// Editors save in two ways: some replace the file, which changes the
    /// folder; others write into the file. Both are watched.
    private func watchConfig() {
        let url = Settings.defaultURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.deletingLastPathComponent().path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.reloadConfigIfChanged()
                // The file may have been replaced; watch the new one.
                self?.watchConfigFile()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        configWatcher = source
        watchConfigFile()
    }

    private func watchConfigFile() {
        fileWatcher?.cancel()
        fileWatcher = nil
        let fd = open(Settings.defaultURL.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.reloadConfigIfChanged() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        fileWatcher = source
    }

    private func reloadConfigIfChanged() {
        guard let manager else { return }
        do {
            let settings = try Settings.load()
            configError = nil
            if settings != manager.settings {
                Log.info("config file changed; reloading")
                manager.reload(settings)
            }
        } catch {
            configError = Self.describe(error)
            Log.warn("config file error: \(configError ?? "")")
        }
        updateIcon()
    }

    /// A readable description of a config file error, with the setting it concerns.
    static func describe(_ error: Error) -> String {
        guard let error = error as? DecodingError else { return error.localizedDescription }
        func path(_ context: DecodingError.Context) -> String {
            let keys = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }
            return keys.isEmpty ? "The file" : "“" + keys.joined(separator: ".").replacingOccurrences(of: ".[", with: "[") + "”"
        }
        switch error {
        case let .typeMismatch(_, context), let .valueNotFound(_, context):
            return "\(path(context)) has the wrong type. \(context.debugDescription)"
        case let .keyNotFound(key, context):
            return "\(path(context)) is missing “\(key.stringValue)”."
        case let .dataCorrupted(context):
            let detail = (context.underlyingError as NSError?)?.userInfo[NSDebugDescriptionErrorKey] as? String
            return "\(path(context)) is not valid. \(detail ?? context.debugDescription)"
        @unknown default:
            return error.localizedDescription
        }
    }
}
