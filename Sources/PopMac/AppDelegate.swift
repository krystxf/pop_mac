import AppKit
import PopCore
import ServiceManagement

/// The menu bar app, the macOS counterpart of Pop Shell's top bar indicator.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var manager: WindowManager?
    private let shortcuts = ShortcutsWindow()
    private var permissionTimer: Timer?
    private var configWatcher: DispatchSourceFileSystemObject?
    private var fileWatcher: DispatchSourceFileSystemObject?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        if AX.isTrusted(prompt: true) {
            start()
        } else {
            // Wait until the user grants Accessibility access in System Settings.
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard AX.isTrusted(prompt: false) else { return }
                    self?.permissionTimer?.invalidate()
                    self?.start()
                }
            }
        }
    }

    private func start() {
        let settings: Settings
        do {
            settings = try Settings.load()
        } catch {
            Log.warn("config is invalid, using defaults: \(error)")
            settings = Settings()
        }

        let manager = WindowManager(settings: settings)
        manager.onStateChange = { [weak self] in self?.updateIcon() }
        self.manager = manager
        manager.start()
        updateIcon()
        watchConfig()
    }

    private func updateIcon() {
        let tiled = manager?.autoTiler != nil
        let name = manager == nil ? "exclamationmark.triangle" : (tiled ? "rectangle.split.2x1.fill" : "rectangle.split.2x1")
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Pop Mac")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        guard let manager else {
            menu.addItem(withTitle: "Waiting for Accessibility access…", action: nil, keyEquivalent: "")
            menu.addItem(item("Open Accessibility Settings", #selector(openAccessibility)))
            menu.addItem(.separator())
            menu.addItem(item("Quit Pop Mac", #selector(quit), key: "q"))
            return
        }

        let s = manager.settings
        menu.addItem(toggle("Tile Windows", manager.autoTiler != nil, #selector(toggleTiling), hint: .toggleTiling))
        menu.addItem(.separator())

        menu.addItem(gapMenu("Inner Gap", current: s.gapInner, action: #selector(setInnerGap(_:))))
        menu.addItem(gapMenu("Outer Gap", current: s.gapOuter, action: #selector(setOuterGap(_:))))
        menu.addItem(toggle("Smart Gaps", s.smartGaps, #selector(toggleSmartGaps)))
        menu.addItem(colorMenu(current: s.overlayColor))
        menu.addItem(.separator())

        menu.addItem(toggle("Cursor Follows Active Window", s.mouseCursorFollowsActiveWindow, #selector(toggleCursorFollows)))
        menu.addItem(toggle("Snap Floating Windows to Grid", s.snapToGrid, #selector(toggleSnap)))
        menu.addItem(.separator())

        menu.addItem(toggle("Launcher…", false, #selector(openLauncher), hint: .activateLauncher))
        menu.addItem(item("View All Shortcuts…", #selector(showShortcuts)))
        menu.addItem(item("Edit Config File…", #selector(editConfig)))
        menu.addItem(item("Reload Config", #selector(reloadConfig)))
        menu.addItem(item("Copy Tiling Tree (debug)", #selector(copyTree)))
        menu.addItem(.separator())
        menu.addItem(toggle("Launch at Login", SMAppService.mainApp.status == .enabled, #selector(toggleLaunchAtLogin)))
        menu.addItem(item("Quit Pop Mac", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func toggle(_ title: String, _ on: Bool, _ action: Selector, hint: Action? = nil) -> NSMenuItem {
        var label = title
        if let hint, let combo = manager?.settings.combos(for: hint).first {
            label += "    " + combo.description
        }
        let item = item(label, action)
        item.state = on ? .on : .off
        return item
    }

    private func gapMenu(_ title: String, current: Double, action: Selector) -> NSMenuItem {
        let parent = NSMenuItem(title: "\(title): \(Int(current)) pt", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for value in [0, 2, 4, 8, 12, 16, 24, 32] {
            let entry = item("\(value) pt", action)
            entry.tag = value
            entry.state = Int(current) == value ? .on : .off
            sub.addItem(entry)
        }
        parent.submenu = sub
        return parent
    }

    private static let colorPresets: [(String, String)] = [
        ("Pop Orange", "#FBB86C"), ("Blue", "#3D8BFD"), ("Teal", "#2BC4B6"), ("Green", "#5CC06E"),
        ("Purple", "#A77BF3"), ("Pink", "#F06EAA"), ("Red", "#EF5B5B"), ("Graphite", "#8E8E93"),
    ]

    /// The highlight color: presets, the system accent color, or any color from the color panel.
    private func colorMenu(current: String) -> NSMenuItem {
        let parent = NSMenuItem(title: "Highlight Color", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        var matched = false

        for (name, hex) in Self.colorPresets {
            let entry = item(name, #selector(setPresetColor(_:)))
            entry.representedObject = hex
            entry.image = swatch(NSColor(hex: hex) ?? .gray)
            if current.caseInsensitiveCompare(hex) == .orderedSame {
                entry.state = .on
                matched = true
            }
            sub.addItem(entry)
        }

        let accent = item("System Accent Color", #selector(setPresetColor(_:)))
        accent.representedObject = "accent"
        accent.image = swatch(.controlAccentColor)
        if current == "accent" {
            accent.state = .on
            matched = true
        }
        sub.addItem(accent)

        sub.addItem(.separator())
        let custom = item(matched ? "Custom…" : "Custom (\(current.uppercased()))…", #selector(pickCustomColor))
        custom.state = matched ? .off : .on
        if !matched, let color = NSColor(hex: current) { custom.image = swatch(color) }
        sub.addItem(custom)

        parent.submenu = sub
        return parent
    }

    private func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3).fill()
            return true
        }
    }

    // MARK: - Menu actions

    @objc private func setPresetColor(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        manager?.update { $0.overlayColor = value }
        manager?.previewOverlay()
    }

    @objc private func pickCustomColor() {
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.isContinuous = true
        if let manager { panel.color = manager.overlayColor }
        panel.setTarget(self)
        panel.setAction(#selector(customColorChanged(_:)))
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func customColorChanged(_ sender: NSColorPanel) {
        manager?.update { $0.overlayColor = sender.color.hexString }
        manager?.previewOverlay()
    }

    @objc private func toggleTiling() { manager?.toggleTiling() }
    @objc private func toggleSmartGaps() { manager?.update { $0.smartGaps.toggle() } }
    @objc private func toggleCursorFollows() { manager?.update { $0.mouseCursorFollowsActiveWindow.toggle() } }
    @objc private func toggleSnap() { manager?.update { $0.snapToGrid.toggle() } }
    @objc private func setInnerGap(_ sender: NSMenuItem) { manager?.update { $0.gapInner = Double(sender.tag) } }
    @objc private func setOuterGap(_ sender: NSMenuItem) { manager?.update { $0.gapOuter = Double(sender.tag) } }
    @objc private func openLauncher() { manager?.launcher.open() }

    @objc private func showShortcuts() {
        guard let manager else { return }
        shortcuts.show(settings: manager.settings)
    }

    @objc private func editConfig() {
        let url = Settings.defaultURL
        if !FileManager.default.fileExists(atPath: url.path) {
            manager?.save()
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func reloadConfig() {
        do {
            try manager?.reload(Settings.load())
        } catch {
            let alert = NSAlert()
            alert.messageText = "The config file is invalid"
            alert.informativeText = "\(error)"
            alert.runModal()
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

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            Log.warn("launch at login failed: \(error)")
        }
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
        guard let manager, let settings = try? Settings.load(), settings != manager.settings else { return }
        Log.info("config file changed; reloading")
        manager.reload(settings)
    }
}
