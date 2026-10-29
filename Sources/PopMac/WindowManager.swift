import AppKit
import PopCore

/// Tracks every window, reacts to system events, and drives the auto-tiler.
///
/// This is the macOS counterpart of Pop Shell's `Ext` class.
@MainActor
final class WindowManager {
    private(set) var settings: Settings
    /// Called when a setting or the tiling state changes, so the menu can refresh.
    var onStateChange: (() -> Void)?

    private var observers: [pid_t: AppObserver] = [:]
    private(set) var windows: [WindowID: ManagedWindow] = [:]
    private(set) var autoTiler: AutoTiler?

    /// Windows that the user made float with toggle-floating.
    var floating = Set<WindowID>()
    /// Windows that match a float rule, but that the user made tile with toggle-floating.
    var forceTile = Set<WindowID>()
    /// Maximized windows, with their frame before maximizing.
    var maximized: [WindowID: Rect] = [:]
    /// The two most recently focused windows: [older, newer].
    private var prevFocused: [WindowID?] = [nil, nil]
    /// Each tiled window's frame from before it was tiled.
    private(set) var prevRect: [WindowID: Rect] = [:]
    private var pendingRestore: [WindowID: Rect] = [:]
    private var restoreScheduled = false
    private var minimizedAttachments: [WindowID: AutoTiler.Attachment] = [:]
    private(set) var displays: [Display] = Displays.all()

    let overlay = OverlayWindow()
    let hint = HintWindow()
    /// The dark layers over the wallpaper, by display.
    private var wallpaperDims: [MonitorID: WallpaperDimWindow] = [:]
    let animator = WindowAnimator()
    private var hintScheduled = false
    /// When the outline started to wait for its window's real frame.
    private var hintWaitStart: Date?
    private let tabs = StackTabsController()
    private var stacksScheduled = false
    /// When the drop preview of a dragged stack was last updated.
    private var stackPreviewTime = Date.distantPast
    /// Saved trees from before Pop Mac started, waiting for their Space to be visible.
    private var savedTrees: [SavedTree] = []
    private var layoutSaveScheduled = false
    let hotkeys = HotkeyManager()
    private(set) lazy var launcher = Launcher(manager: self)
    private var mouse: MouseMonitor?
    private var signalSource: DispatchSourceSignal?
    var tileMode: TileMode?
    /// Windows to check after a move: the frame they should have, and whether it was set twice.
    private var pendingVerify: [WindowID: (target: Rect, retried: Bool)] = [:]
    /// The smallest size each window accepted, learned when it refused a smaller tile.
    private var minimumSizes: [WindowID: Size] = [:]
    /// When Pop Mac last moved each window, so the window's own move events can be ignored.
    private var lastSet: [WindowID: Date] = [:]
    /// The tile that each window last received.
    private var lastApplied: [WindowID: Rect] = [:]
    /// The windows behind a gliding stack's selected tab, with their tiles. They arrive when the selected window does.
    private var stackFollowers: [WindowID: [(id: WindowID, target: Rect)]] = [:]
    /// Tiled windows that were just closed. A native tab of the same app may take their tile.
    private var closingTabs: [WindowID: (pid: pid_t, frame: Rect)] = [:]
    private var snapBackPending = Set<WindowID>()
    private var snapBackScheduled = false
    private var verifyScheduled = false
    private var spaceScanScheduled = false
    private var departureTimer: Timer?
    /// How many checks in a row found each tiled window off screen.
    private var offscreenStrikes: [WindowID: Int] = [:]
    /// How many checks in a row found each tilable window on screen but untiled.
    private var untiledStrikes: [WindowID: Int] = [:]
    /// For the end-to-end tests: the only app whose windows Pop Mac manages.
    private let onlyPID = ProcessInfo.processInfo.environment["POP_MAC_ONLY_PID"].flatMap { pid_t($0) }

    init(settings: Settings) {
        self.settings = settings
    }

    // MARK: - Startup

    func start() {
        applyStyles()
        // An app raises its window when the user clicks it. The outline and the tab bar follow,
        // the tab bar last, so the outline's glass never covers it.
        WindowReorders.observe { [weak self] window in
            self?.hint.reorder(after: window)
            self?.tabs.reorder(above: window)
        }
        registerHotkeys()
        observeWorkspace()

        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            addApp(app)
        }

        if settings.tileByDefault {
            autoTileOn()
        }

        if let focused = focusedWindow() {
            onFocused(focused)
        }

        // `kill -USR1 <pid>` writes the tiling tree to the log.
        signal(SIGUSR1, SIG_IGN)
        let dump = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        dump.setEventHandler { [weak self] in
            MainActor.assumeIsolated { if let self { Log.info(self.dumpTree()) } }
        }
        dump.resume()
        signalSource = dump

        let mouse = MouseMonitor(manager: self)
        mouse.start()
        self.mouse = mouse

        departureTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkDepartedWindows()
                // Some changes have no event, such as a window that another app moved to a display.
                self?.updateWallpaperDims()
            }
        }
        Log.info("started with \(windows.count) windows")
    }

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter

        center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.addApp(app, attempt: 0) }
        }
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated {
                if let pid = Processes.pid(of: app) { self?.removeApp(pid) }
            }
        }
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let focused = self.focusedWindow() { self.onFocused(focused) }
                self.scheduleFocusCheck()
            }
        }
        center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onSpaceChanged() }
        }
        // The accent color can change in System Settings.
        NotificationCenter.default.addObserver(forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyStyles()
                self?.scheduleStacksRefresh()
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onDisplaysChanged() }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged"),
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                KeyCodes.reloadLayout()
                self?.registerHotkeys()
            }
        }
    }

    // MARK: - Settings

    func update(_ change: (inout Settings) -> Void) {
        let old = settings
        change(&settings)
        guard settings != old else { return }
        save()
        settingsChanged(from: old)
    }

    /// Replaces all settings, for example after the config file was edited.
    func reload(_ new: Settings) {
        let old = settings
        settings = new
        settingsChanged(from: old)
    }

    private func settingsChanged(from old: Settings) {
        applyStyles()
        scheduleStacksRefresh()
        if settings.superModifiers != old.superModifiers || settings.primaryModifiers != old.primaryModifiers
            || settings.keybindings != old.keybindings
        {
            registerHotkeys()
        }
        if settings.tileByDefault != old.tileByDefault {
            settings.tileByDefault ? autoTileOn() : autoTileOff()
        }
        if let autoTiler, settings.gapInner != old.gapInner || settings.gapOuter != old.gapOuter
            || settings.smartGaps != old.smartGaps || settings.maxWindowWidth != old.maxWindowWidth
        {
            autoTiler.forest.gapInner = settings.gapInner
            retileAll()
        }
        if settings.floatRules != old.floatRules, let autoTiler {
            // Windows that now match a rule float, back at their frame from before tiling.
            for id in Array(autoTiler.attached.keys) where !forceTile.contains(id) {
                if let window = windows[id], matchesFloatRule(window) {
                    autoTiler.detachWindow(id)
                }
            }
            // Windows that no longer match get tiled.
            scanVisibleWindows()
        }
        scheduleHint()
        onStateChange?()
    }

    func save() {
        do {
            try settings.save()
        } catch {
            Log.warn("could not save settings: \(error)")
        }
    }

    /// The system accent color, for the selected stack tab and, before macOS 26, the highlights.
    ///
    /// The color is resolved, so a new accent color counts as a change.
    private var accentColor: NSColor {
        NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .controlAccentColor
    }

    private func applyStyles() {
        Motion.enabled = settings.animations
        overlay.style(color: accentColor, radius: settings.overlayBorderRadius)
        hint.style(color: accentColor, width: settings.activeHintWidth, radius: settings.overlayBorderRadius)
    }

    // MARK: - Applications

    private func addApp(_ app: NSRunningApplication, attempt: Int = 0) {
        guard let pid = Processes.pid(of: app), observers[pid] == nil, pid != ProcessInfo.processInfo.processIdentifier,
              app.activationPolicy == .regular, !app.isTerminated, onlyPID == nil || pid == onlyPID
        else { return }

        guard let observer = AppObserver(app: app, pid: pid, handler: { [weak self] observer, event in
            MainActor.assumeIsolated { self?.handle(observer, event) }
        }) else {
            // A launching app may not answer Accessibility requests yet.
            if attempt < 5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    MainActor.assumeIsolated { self?.addApp(app, attempt: attempt + 1) }
                }
            }
            return
        }

        observers[pid] = observer
        for element in observer.windows() {
            if let window = register(element, observer) {
                autoTileIfNeeded(window.id)
            }
        }
    }

    private func removeApp(_ pid: pid_t) {
        for window in windows.values where window.pid == pid {
            onDestroy(window.id)
        }
        observers.removeValue(forKey: pid)
    }

    // MARK: - Windows

    /// Starts tracking a window, if it is a standard window.
    @discardableResult
    private func register(_ element: AXUIElement, _ observer: AppObserver) -> ManagedWindow? {
        guard let id = AX.windowID(element) else { return nil }
        if let existing = windows[id] { return existing }

        let window = ManagedWindow(id: id, element: element, app: observer.app, pid: observer.pid, appElement: observer.element)
        // Minimized windows report the dialog subrole until they are restored.
        guard window.isStandard || (window.role == kAXWindowRole && window.isMinimized) else { return nil }

        windows[id] = window
        AXUIElementSetMessagingTimeout(element, 1.0)
        observer.watch(element)
        Log.debug("registered \(window.appName): \(window.title) (\(id))")
        return window
    }

    /// Finds the tracked window for an element, even after it was destroyed.
    ///
    /// Comparing elements needs no call to the app, which may be busy, so it comes first.
    /// It matters during animations, which send many move events.
    private func lookup(_ element: AXUIElement, pid: pid_t) -> WindowID? {
        if let window = windows.values.first(where: { $0.pid == pid && CFEqual($0.element, element) }) { return window.id }
        if let id = AX.windowID(element), windows[id] != nil { return id }
        return nil
    }

    func focusedWindow() -> ManagedWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let pid = Processes.pid(of: app),
              let observer = observers[pid],
              let element = observer.focusedWindow()
        else { return nil }
        if let id = lookup(element, pid: pid) { return windows[id] }
        return register(element, observer)
    }

    private func handle(_ observer: AppObserver, _ event: AXEvent) {
        let pid = observer.pid

        switch event {
        case let .windowCreated(element):
            // Give the application a moment to set the window's final frame.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                MainActor.assumeIsolated { self?.onWindowCreated(element, observer) }
            }

        case let .windowDestroyed(element):
            if let id = lookup(element, pid: pid) { onDestroy(id) }

        case let .focusedWindowChanged(element):
            var id = lookup(element, pid: pid)
            if id == nil, let window = register(element, observer) {
                // A window that was not standard when it was created.
                id = window.id
                autoTileIfNeeded(window.id)
            }
            if let id, let window = windows[id], NSWorkspace.shared.frontmostApplication.flatMap(Processes.pid(of:)) == pid {
                onFocused(window)
            } else {
                scheduleFocusCheck()
            }

        case let .windowMinimized(element):
            if let id = lookup(element, pid: pid) { onMinimize(id, minimized: true) }

        case let .windowDeminimized(element):
            if let id = lookup(element, pid: pid) { onMinimize(id, minimized: false) }

        case let .windowMoved(element), let .windowResized(element):
            let moved = lookup(element, pid: pid)
            // Pop Mac's own animation moves the window. The outline glides along by itself.
            if let moved, animator.target(of: moved) != nil { break }
            if moved != nil, moved == prevFocused[1] {
                // The outline would trail a window that the mouse moves. It returns at mouse-up.
                if NSEvent.pressedMouseButtons & 1 != 0 { hint.hide() } else { scheduleHint() }
            }
            if let id = moved,
               // Mouse drags are handled at mouse-up. Anything else snaps back to its tile.
               autoTiler?.isAttached(id) == true, NSEvent.pressedMouseButtons & 1 == 0,
               Date().timeIntervalSince(lastSet[id] ?? .distantPast) > 0.5
            {
                scheduleSnapBack(id)
            }

        case let .titleChanged(element):
            // Only tab bars show titles. Most title changes are of other windows.
            let stacked = autoTiler?.forest.allStacks().flatMap(\.entities) ?? []
            if stacked.contains(where: { windows[$0]?.pid == pid }),
               let id = lookup(element, pid: pid), stacked.contains(id)
            {
                scheduleStacksRefresh()
            }

        case .appHidden:
            for window in windows.values where window.pid == pid {
                onMinimize(window.id, minimized: true)
            }

        case .appShown:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    for window in self.windows.values where window.pid == pid {
                        self.onMinimize(window.id, minimized: false)
                    }
                }
            }
        }
    }

    private func onWindowCreated(_ element: AXUIElement, _ observer: AppObserver) {
        guard let window = register(element, observer) else { return }
        autoTileIfNeeded(window.id)
    }

    /// Tiles a window that is not in the tree yet.
    ///
    /// A native tab takes the tile of the tab it replaced on screen.
    private func autoTileIfNeeded(_ id: WindowID) {
        guard let autoTiler, !autoTiler.isAttached(id), isTilable(id), minimizedAttachments[id] == nil else { return }
        // A saved tree of this Space takes the window back to its old place.
        restoreSavedTrees()
        guard !autoTiler.isAttached(id) else { return }
        if let sibling = tabSibling(of: id) {
            Log.debug("window \(id) replaces tab \(sibling)")
            closingTabs.removeValue(forKey: sibling)
            autoTiler.replace(sibling, with: id)
            return
        }
        autoTiler.autoTile(id, ignoreFocus: false)
    }

    /// Finds the tiled tab that a window replaced.
    ///
    /// macOS shows only the selected tab of a tab group, at the group's frame.
    /// The replaced tab is either hidden now, or was just closed.
    private func tabSibling(of id: WindowID) -> WindowID? {
        guard let autoTiler, let window = windows[id], let frame = window.frame,
              let key = actualKey(of: id)
        else { return nil }

        for (other, closing) in closingTabs
            where closing.pid == window.pid && autoTiler.isAttached(other) && closing.frame.approximatelyEquals(frame, tolerance: 4)
        {
            return other
        }

        let visible = Set(Displays.onScreenWindowIDs())
        guard visible.contains(id) else { return nil }
        for other in windows.values where other.id != id && other.pid == window.pid && !visible.contains(other.id) {
            guard autoTiler.isAttached(other.id), !other.isMinimized, workspaceKey(of: other.id) == key,
                  let otherFrame = other.frame, otherFrame.approximatelyEquals(frame, tolerance: 4)
            else { continue }
            return other.id
        }
        return nil
    }

    /// Moves tiled windows back into their tiles after something else moved them.
    private func scheduleSnapBack(_ id: WindowID) {
        snapBackPending.insert(id)
        guard !snapBackScheduled else { return }
        snapBackScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.snapBackScheduled = false
                let ids = self.snapBackPending
                self.snapBackPending.removeAll()
                guard let autoTiler = self.autoTiler, NSEvent.pressedMouseButtons & 1 == 0 else { return }

                var tiled = Set<ObjectIdentifier>()
                for id in ids {
                    guard let window = self.windows[id], let fork = autoTiler.attached[id] else { continue }
                    if window.isFullscreen {
                        // Native full screen moves the window to its own Space.
                        self.detachQuietly(id)
                        continue
                    }
                    let top = autoTiler.forest.toplevel(of: fork)
                    if tiled.insert(ObjectIdentifier(top)).inserted {
                        Log.debug("window \(id) left its tile; snapping back")
                        autoTiler.tile(top, area: top.area)
                    }
                }
            }
        }
    }

    private func onDestroy(_ id: WindowID) {
        if tileMode?.window == id { exitTileMode() }
        defer { scheduleHint() }
        // Closing the focused tab of a stack focuses the tab that takes its place.
        let closedStack = prevFocused[1] == id ? autoTiler?.findStack(id)?.stack : nil
        let detach = { [weak self] in
            guard let self else { return }
            autoTiler?.detachWindow(id)
            if let closedStack, closedStack.active != id, autoTiler?.isAttached(closedStack.active) == true {
                activate(closedStack.active, moveCursor: false)
            }
        }

        if prevFocused[0] == id {
            prevFocused[0] = nil
        } else if prevFocused[1] == id {
            prevFocused[1] = prevFocused[0]
            prevFocused[0] = nil
        }

        let pid = windows[id]?.pid
        windows.removeValue(forKey: id)
        stopAnimation(id)
        if let autoTiler, autoTiler.isAttached(id), let pid, let frame = lastApplied[id] {
            // Wait briefly: if this was a native tab, the next tab takes its tile.
            closingTabs[id] = (pid, frame)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.closingTabs.removeValue(forKey: id) != nil else { return }
                    detach()
                }
            }
        } else {
            detach()
        }
        lastSet.removeValue(forKey: id)
        lastApplied.removeValue(forKey: id)
        minimumSizes.removeValue(forKey: id)
        floating.remove(id)
        forceTile.remove(id)
        maximized.removeValue(forKey: id)
        prevRect.removeValue(forKey: id)
        minimizedAttachments.removeValue(forKey: id)
    }

    func onFocused(_ window: ManagedWindow) {
        hintWaitStart = nil
        if prevFocused[1] != window.id {
            prevFocused[0] = prevFocused[1]
            prevFocused[1] = window.id
        }

        if let stack = autoTiler?.findStack(window.id)?.stack, stack.active != window.id {
            stack.active = window.id
            scheduleStacksRefresh()
        }

        // Every window that can tile is tiled, for example after leaving full screen.
        autoTileIfNeeded(window.id)
        scheduleHint()

        if settings.logOnFocus {
            var message = window.describe()
            if let fork = autoTiler?.attached[window.id] {
                message += "\n  fork: \(fork.id), workspace: \(fork.workspace)"
            }
            Log.info(message)
        }
    }

    /// Asks for the focused window again a moment later, and twice.
    ///
    /// Mission Control and App Exposé report the window that the user picked while the
    /// Dock is still frontmost, and the app's activation can come before its focus moves.
    /// Without a second look, the outline stays on the window that had focus before.
    private func scheduleFocusCheck() {
        for delay in [0.3, 0.8] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let focused = self.focusedWindow(), focused.id != self.prevFocused[1] {
                        self.onFocused(focused)
                    } else {
                        self.scheduleHint()
                    }
                }
            }
        }
    }

    private func onMinimize(_ id: WindowID, minimized: Bool) {
        if id == prevFocused[1] { scheduleHint() }
        guard let autoTiler else { return }

        if minimized {
            if let attachment = autoTiler.attachment(of: id) {
                minimizedAttachments[id] = attachment
                autoTiler.detachWindow(id)
            }
        } else if !floating.contains(id), !autoTiler.isAttached(id), isTilable(id) {
            // Return to the old place, unless the window came back on another Space.
            if let attachment = minimizedAttachments.removeValue(forKey: id),
               autoTiler.workspace(of: attachment) == actualKey(of: id),
               autoTiler.restore(id, to: attachment)
            {
                return
            }
            autoTiler.autoTile(id)
        }
    }

    // MARK: - Spaces and displays

    private func onSpaceChanged() {
        exitTileMode()
        hint.hide()
        scheduleFocusCheck()
        guard !spaceScanScheduled else { return }
        spaceScanScheduled = true
        // The window list lags slightly behind the Space switch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated {
                self?.spaceScanScheduled = false
                self?.scanVisibleWindows()
            }
        }
    }

    /// Keeps the trees in step with windows that moved between Spaces.
    ///
    /// Mission Control and the window menu can move a window to another Space
    /// without a Space switch, and without any event for it.
    /// - A window that left is still in the tree of a visible Space, but no
    ///   longer on screen. It leaves the tree, so the others fill its tile.
    /// - A window that arrived is on screen, but in no tree. It gets tiled.
    ///
    /// Both must hold on two checks in a row, because windows also leave and
    /// enter the screen for a moment while a Space switch animates.
    private func checkDepartedWindows() {
        guard let autoTiler, NSEvent.pressedMouseButtons & 1 == 0, !SpaceMover.isMoving else { return }

        let visible = Set(Displays.onScreenWindowIDs())
        let visibleKeys = Set(displays.map { currentKey(of: $0) })
        var strikes: [WindowID: Int] = [:]

        // A window whose title now matches a user's float rule leaves its tile.
        for id in Array(autoTiler.attached.keys) where visible.contains(id) && !forceTile.contains(id) {
            if let window = windows[id], matchesFloatRule(window) {
                Log.debug("window \(id) matches a float rule now; floating it")
                autoTiler.detachWindow(id)
            }
        }

        for (id, fork) in autoTiler.attached where !visible.contains(id) {
            guard let window = windows[id], !window.isMinimized, !window.isHidden,
                  visibleKeys.contains(autoTiler.forest.toplevel(of: fork).workspace)
            else { continue }

            let count = (offscreenStrikes[id] ?? 0) + 1
            if count >= 2 {
                Log.debug("window \(id) left the visible Space; untiling it")
                detachQuietly(id)
            } else {
                strikes[id] = count
            }
        }
        offscreenStrikes = strikes

        var untiled: [WindowID: Int] = [:]
        for id in visible where windows[id] != nil && !autoTiler.isAttached(id) {
            guard !floating.contains(id), minimizedAttachments[id] == nil, isTilable(id) else { continue }
            let count = (untiledStrikes[id] ?? 0) + 1
            if count >= 2 {
                Log.debug("window \(id) arrived on the visible Space; tiling it")
                autoTileIfNeeded(id)
            } else {
                untiled[id] = count
            }
        }
        untiledStrikes = untiled
    }

    /// Finds new windows on the visible Spaces, and fixes windows that changed Space.
    func scanVisibleWindows() {
        displays = Displays.all()
        for observer in observers.values {
            for element in observer.windows() {
                register(element, observer)
            }
        }

        if let autoTiler {
            restoreSavedTrees()
            let visible = Displays.onScreenWindowIDs()
            for id in visible.reversed() {
                guard windows[id] != nil else { continue }
                if let fork = autoTiler.attached[id] {
                    let key = autoTiler.forest.toplevel(of: fork).workspace
                    if !isTilable(id) {
                        detachQuietly(id)
                    } else if let actual = actualKey(of: id), actual != key {
                        Log.debug("window \(id) moved from \(key) to \(actual)")
                        detachQuietly(id)
                        autoTiler.attachToWorkspace(id, key: actual)
                    }
                } else if !floating.contains(id), isTilable(id), minimizedAttachments[id] == nil {
                    autoTiler.autoTile(id, ignoreFocus: true)
                }
            }
        }

        scheduleStacksRefresh()
        if let focused = focusedWindow() { onFocused(focused) }
    }

    private func onDisplaysChanged() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated { self?.rearrangeDisplays() }
        }
    }

    private func rearrangeDisplays() {
        displays = Displays.all()
        guard let autoTiler else { return }

        let present = Set(displays.map(\.id))
        var orphans: [WindowID] = []
        for (key, fork) in autoTiler.forest.toplevels where !present.contains(key.monitor) {
            orphans += autoTiler.forest.windows(in: fork)
        }
        for id in orphans { detachQuietly(id) }
        for id in orphans where isTilable(id) { autoTiler.autoTile(id, ignoreFocus: true) }

        autoTiler.updateAllToplevels()
    }

    func display(_ id: MonitorID) -> Display? {
        displays.first { $0.id == id }
    }

    /// The workspace key of a display's current Space.
    func currentKey(of display: Display) -> WorkspaceKey {
        WorkspaceKey(monitor: display.id, space: Displays.currentSpace(of: display))
    }

    /// The workspace key from the window's real frame and Space.
    func actualKey(of id: WindowID) -> WorkspaceKey? {
        guard let window = windows[id], let frame = Displays.onScreenFrame(of: id) ?? window.frame,
              let display = Displays.display(for: frame, in: displays)
        else { return nil }
        // After a window crosses displays, macOS can still report its old display's Space.
        // Trust the reported Space only if it belongs to the window's display.
        let all = Spaces.allSpaces()
        let spacesOfDisplay = all[display.uuid] ?? all["Main"] ?? []
        if let space = Spaces.space(of: id), spacesOfDisplay.contains(space) {
            return WorkspaceKey(monitor: display.id, space: space)
        }
        return WorkspaceKey(monitor: display.id, space: Displays.currentSpace(of: display))
    }

    // MARK: - Tiling state

    func isTilable(_ id: WindowID) -> Bool {
        guard let window = windows[id], !floating.contains(id), window.isStandard, !window.isMinimized, !window.isFullscreen,
              !window.isHidden else { return false }
        if matchesFloatRule(window) {
            return forceTile.contains(id)
        }
        return window.isResizable
    }

    /// True if the window matches a float rule in the config.
    func matchesFloatRule(_ window: ManagedWindow) -> Bool {
        FloatRules.windowShallFloat(appName: window.appName, bundleID: window.bundleID, title: window.title, userRules: settings.floatRules)
    }

    func autoTileOn() {
        if autoTiler != nil { return }
        let tiler = AutoTiler(env: self, gapInner: settings.gapInner)
        tiler.forest.tabHeight = 26
        tiler.forest.onAttach = { [weak self] id in self?.onTileAttach(id) }
        tiler.forest.onDetach = { [weak self] id in self?.onTileDetach(id) }
        autoTiler = tiler

        if !settings.tileByDefault {
            settings.tileByDefault = true
            save()
        }

        // The layout from before a restart, or from before tiling was turned off.
        savedTrees = SavedLayout.load()?.trees ?? []

        // Rebuild the saved layout first, with its stacks. Then tile the other windows
        // from back to front, so the frontmost window is split last.
        // Each window moves once, to its final tile.
        tiler.batch {
            restoreSavedTrees()
            for id in Displays.onScreenWindowIDs().reversed() where windows[id] != nil && isTilable(id) && !tiler.isAttached(id) {
                tiler.autoTile(id, ignoreFocus: true)
            }
        }
        onStateChange?()
    }

    func autoTileOff() {
        guard let tiler = autoTiler else { return }
        exitTileMode()
        // Turning tiling on again rebuilds this layout, with its stacks.
        saveLayout()
        tiler.destroy()
        // Windows stay where they are, instead of returning to their frames from before tiling.
        pendingRestore.removeAll()
        prevRect.removeAll()
        autoTiler = nil
        tabs.removeAll()
        savedTrees.removeAll()
        minimizedAttachments.removeAll()

        if settings.tileByDefault {
            settings.tileByDefault = false
            save()
        }
        onStateChange?()
    }

    func toggleTiling() {
        autoTiler == nil ? autoTileOn() : autoTileOff()
    }

    func retileAll() {
        autoTiler?.updateAllToplevels()
    }

    private func onTileAttach(_ id: WindowID) {
        maximized.removeValue(forKey: id)
        if let rect = pendingRestore.removeValue(forKey: id) {
            prevRect[id] = rect
        } else if prevRect[id] == nil, let frame = windows[id]?.frame {
            prevRect[id] = frame
        }
    }

    /// Returns a window to its pre-tiling frame, unless it is re-attached in the same turn.
    private func onTileDetach(_ id: WindowID) {
        maximized.removeValue(forKey: id)
        guard let rect = prevRect.removeValue(forKey: id) else { return }
        pendingRestore[id] = rect
        guard !restoreScheduled else { return }
        restoreScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.flushRestores() }
        }
    }

    private func flushRestores() {
        restoreScheduled = false
        let pending = pendingRestore
        pendingRestore.removeAll()
        for (id, rect) in pending {
            guard let window = windows[id] else { continue }
            if autoTiler?.isAttached(id) == true || window.isMinimized || window.isHidden {
                prevRect[id] = rect
                continue
            }
            move(window, to: rect)
        }
        scheduleHint()
    }

    /// Detaches a window without moving it back to its pre-tiling frame.
    func detachQuietly(_ id: WindowID) {
        let saved = prevRect[id]
        autoTiler?.detachWindow(id)
        pendingRestore.removeValue(forKey: id)
        if let saved { prevRect[id] = saved }
    }

    // MARK: - Saved layout

    /// Rebuilds the saved trees of the visible Spaces, from before Pop Mac started.
    ///
    /// A tree whose Space is visible is used once. If its Space has a tree already, it is dropped.
    private func restoreSavedTrees() {
        guard let autoTiler, !savedTrees.isEmpty else { return }
        let visible = Set(displays.map { currentKey(of: $0) })
        guard savedTrees.contains(where: { visible.contains($0.key) }) else { return }

        // The windows of a Space are not known before the first visit.
        for observer in observers.values {
            for element in observer.windows() {
                register(element, observer)
            }
        }
        savedTrees.removeAll { tree in
            guard visible.contains(tree.key) else { return false }
            let restored = autoTiler.restore(tree) { [self] id in
                windows[id] != nil && !floating.contains(id) && isTilable(id) && actualKey(of: id) == tree.key
            }
            if restored { Log.debug("restored the saved layout of \(tree.key)") }
            return true
        }
    }

    private func scheduleLayoutSave() {
        guard !layoutSaveScheduled else { return }
        layoutSaveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated {
                self?.layoutSaveScheduled = false
                self?.saveLayout()
            }
        }
    }

    /// Saves the trees, so the next start of Pop Mac can rebuild them.
    func saveLayout() {
        guard let autoTiler else { return }
        var layout = autoTiler.forest.snapshot()
        // Saved trees of Spaces not visited since the start stay saved.
        let current = Set(layout.trees.map(\.key))
        layout.trees += savedTrees.filter { !current.contains($0.key) }
        do {
            try layout.save()
        } catch {
            Log.warn("could not save the layout: \(error)")
        }
    }

    // MARK: - Focus

    /// Windows that are visible on screen, from front to back.
    func activeWindowList() -> [ManagedWindow] {
        Displays.onScreenWindowIDs().compactMap { windows[$0] }
    }

    func selectWindow(_ direction: Direction, from id: WindowID) -> WindowID? {
        guard let rect = windows[id]?.frame else { return nil }
        let candidates = activeWindowList().compactMap { window -> WindowCandidate? in
            // Only the selected tab of a stack can take focus this way.
            if let stack = autoTiler?.findStack(window.id)?.stack, stack.active != window.id { return nil }
            guard window.id != id, let frame = window.frame else { return nil }
            return WindowCandidate(id: window.id, rect: frame)
        }
        return FocusSelector.select(direction, from: rect, among: candidates)
    }

    /// Focuses a window, and moves the cursor onto it if enabled.
    func activate(_ id: WindowID, moveCursor: Bool = true) {
        guard let window = windows[id] else { return }
        if let stack = autoTiler?.findStack(id)?.stack, stack.active != id {
            stack.active = id
            scheduleStacksRefresh()
        }
        window.focus()
        if moveCursor, settings.mouseCursorFollowsActiveWindow, let frame = window.frame {
            let point = settings.mouseCursorFocusLocation.point(in: frame)
            CGWarpMouseCursorPosition(CGPoint(x: point.x, y: point.y))
            CGAssociateMouseAndMouseCursorPosition(1)
        }
    }

    // MARK: - Active hint

    /// Updates the outline and the wallpaper dims soon, once for many calls.
    func scheduleHint() {
        guard !hintScheduled else { return }
        hintScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.hintScheduled = false
                self?.updateHint()
                self?.updateWallpaperDims()
            }
        }
    }

    private func updateHint() {
        guard settings.activeHint, tileMode == nil,
              let id = prevFocused[1], let window = windows[id],
              NSWorkspace.shared.frontmostApplication.flatMap(Processes.pid(of:)) == window.pid,
              // The window server knows the frame without asking the app, which may be busy.
              // A window that glides to a new frame has its outline glide there too.
              var frame = Displays.onScreenFrame(of: id).map({ animator.target(of: id) ?? $0 }), !window.isFullscreen
        else {
            hint.hide()
            return
        }
        // A hidden outline waits for its window to arrive, instead of appearing around an empty tile.
        if animator.target(of: id) != nil, !hint.surrounds(id) {
            hint.hide()
            return
        }
        // In Mission Control and App Exposé, and while they close, the window server
        // reports the frame of the window's thumbnail. Wait for the real frame.
        if animator.target(of: id) == nil, let real = window.frame, !real.approximatelyEquals(frame, tolerance: 2) {
            hint.hide()
            retryHint()
            return
        }
        hintWaitStart = nil
        if let autoTiler, autoTiler.findStack(id) != nil {
            // The outline holds the stack's tab bar too.
            frame.y -= autoTiler.forest.tabHeight
            frame.height += autoTiler.forest.tabHeight
        }
        hint.show(around: frame, of: id)
        tabs.reorder(above: id)
    }

    /// Darkens the wallpaper of each display that shows exactly one window.
    ///
    /// The tabs of a stack count as one window, because only the selected tab is in view.
    private func updateWallpaperDims() {
        var counts: [MonitorID: Int] = [:]
        if settings.wallpaperDim > 0 {
            for (id, frame) in Displays.onScreenFrames() where windows[id] != nil {
                if let stack = autoTiler?.findStack(id)?.stack, stack.active != id { continue }
                // Hidden stack tabs and windows off screen do not count.
                guard let display = displays.first(where: { $0.frame.contains(frame.center) }) else { continue }
                counts[display.id, default: 0] += 1
            }
        }
        for display in displays where counts[display.id] == 1 {
            let dim = wallpaperDims[display.id] ?? WallpaperDimWindow()
            wallpaperDims[display.id] = dim
            dim.show(on: display, darkness: settings.wallpaperDim / 100)
        }
        for (id, dim) in wallpaperDims where counts[id] != 1 {
            dim.hide()
        }
    }

    /// Updates the outline again soon, for up to 3 seconds after it started to wait.
    private func retryHint() {
        let start = hintWaitStart ?? Date()
        hintWaitStart = start
        guard Date().timeIntervalSince(start) < 3 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated { self?.scheduleHint() }
        }
    }

    // MARK: - Stacks

    func scheduleStacksRefresh() {
        guard !stacksScheduled else { return }
        stacksScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.stacksScheduled = false
                self?.refreshStacks()
            }
        }
    }

    /// Draws a tab bar above each stack on the visible Spaces.
    private func refreshStacks() {
        guard let autoTiler else {
            tabs.removeAll()
            return
        }

        let visible = Set(displays.map { currentKey(of: $0) })
        let height = autoTiler.forest.tabHeight
        let entries = autoTiler.forest.allStacks().compactMap { stack -> StackTabsController.Entry? in
            guard let rect = stack.rect, let fork = autoTiler.findStack(stack.active)?.fork,
                  visible.contains(autoTiler.forest.toplevel(of: fork).workspace)
            else { return nil }
            let tabs = stack.entities.compactMap { id -> StackTabBar.Tab? in
                guard let window = windows[id] else { return nil }
                return StackTabBar.Tab(id: id, title: window.title, icon: window.app.icon)
            }
            return StackTabsController.Entry(stack: stack, frame: Rect(rect.x, rect.y - height, rect.width, height - 2), tabs: tabs)
        }

        tabs.sync(entries, color: accentColor) { [weak self] id in
            MainActor.assumeIsolated { self?.activate(id, moveCursor: false) }
        } onDrag: { [weak self] stack, phase in
            MainActor.assumeIsolated {
                switch phase {
                case .moved: self?.stackDragMoved(stack)
                case let .ended(flags): self?.stackDragEnded(stack, flags: flags)
                }
            }
        }
        scheduleHint()
    }

    /// Shows where a stack that is dragged by its tab bar would land.
    private func stackDragMoved(_ stack: StackNode) {
        // Finding the windows under the cursor asks every app for its frames. Keep it rare.
        guard let autoTiler, Date().timeIntervalSince(stackPreviewTime) > 0.05 else { return }
        stackPreviewTime = Date()
        let cursor = Displays.cursor
        guard let display = Displays.display(at: cursor, in: displays),
              let preview = autoTiler.dropPreview(
                  of: stack, cursor: cursor, key: currentKey(of: display),
                  merge: holdsSuper(CGEventSource.flagsState(.combinedSessionState))
              )
        else {
            overlay.hide()
            return
        }
        overlay.show(preview.area, like: stack.active, label: label(for: preview.action, windows: "windows"))
    }

    /// Moves a stack that was dropped after a drag by its tab bar.
    private func stackDragEnded(_ stack: StackNode, flags: CGEventFlags) {
        overlay.hide()
        stackPreviewTime = .distantPast
        let cursor = Displays.cursor
        guard let autoTiler, let display = Displays.display(at: cursor, in: displays) else { return }
        autoTiler.onDrop(stack, cursor: cursor, key: currentKey(of: display), merge: holdsSuper(flags))
        activate(stack.active, moveCursor: false)
    }

    /// True if exactly the Super modifiers are held in `flags`.
    func holdsSuper(_ flags: CGEventFlags) -> Bool {
        let wanted = CGEventFlags(modifiers: settings.superModifiers)
        return !wanted.isEmpty && flags.intersection(.modifiers) == wanted
    }

    // MARK: - Mouse

    /// Shows where a dragged window would land.
    func dragPreview(_ id: WindowID) {
        guard let autoTiler, autoTiler.isAttached(id) else {
            overlay.hide()
            return
        }
        let cursor = Displays.cursor
        // Holding the Super modifiers stacks instead of swaps.
        let stack = holdsSuper(CGEventSource.flagsState(.combinedSessionState))
        guard let display = Displays.display(at: cursor, in: displays),
              let preview = autoTiler.dropPreview(id, cursor: cursor, key: currentKey(of: display), stack: stack)
        else {
            overlay.hide()
            return
        }
        overlay.show(preview.area, like: id, label: label(for: preview.action, windows: "window"))
    }

    /// The label in the middle of a drop preview. Only a swap or a stack has one.
    private func label(for action: AutoTiler.DropPreview.Action, windows: String) -> OverlayWindow.Label? {
        switch action {
        case .move: nil
        case .swap: OverlayWindow.Label(symbol: "rectangle.2.swap", text: "Switch windows")
        case .stack: OverlayWindow.Label(symbol: "square.stack", text: "Stack \(windows)")
        }
    }

    /// True if Pop Mac set the window's frame after `date`.
    func wasMovedByPopMac(_ id: WindowID, since date: Date) -> Bool {
        (lastSet[id] ?? .distantPast) > date
    }

    /// Handles the end of a mouse drag or resize of a window.
    ///
    /// - Parameter stack: True if the Super modifiers were held at the drop, so a drop on a window's center stacks.
    func onGrabEnd(_ id: WindowID, original: Rect, stack: Bool = false) {
        overlay.hide()
        defer { scheduleHint() }
        guard let window = windows[id], let current = window.frame else { return }
        if current.approximatelyEquals(original, tolerance: 1) { return }
        Log.debug("grab end \(id): \(original) -> \(current)")
        maximized.removeValue(forKey: id)
        // The window took this size, so it is not too small for it.
        forgetMinimum(id, accepted: current)

        guard let autoTiler else {
            if settings.snapToGrid { snap(window) }
            return
        }
        guard autoTiler.isAttached(id) else { return }

        // A mouse resize keeps the corner opposite the grabbed one in place, so one
        // horizontal and one vertical edge stay put. In a move every edge moves, even
        // when macOS changes the window's size during the drag.
        let near = { (a: Double, b: Double) in abs(a - b) <= 2 }
        let isResize = (near(current.x, original.x) || near(current.maxX, original.maxX))
            && (near(current.y, original.y) || near(current.maxY, original.maxY))
        if isResize {
            autoTiler.resizeByMouse(id, from: original, to: current)
        } else {
            let cursor = Displays.cursor
            guard let display = Displays.display(at: cursor, in: displays) else { return }
            let key = currentKey(of: display)
            let previous = autoTiler.attached[id].map { autoTiler.forest.toplevel(of: $0).workspace }
            autoTiler.onDrop(id, cursor: cursor, key: key, viaOverview: previous?.monitor != key.monitor, stack: stack)
        }
    }

    /// Snaps a floating window to the display grid.
    func snap(_ window: ManagedWindow) {
        guard let frame = window.frame, let display = Displays.display(for: frame, in: displays) else { return }
        let cell = Grid.cell(monitor: display.workArea, columnSize: settings.columnSize, rowSize: settings.rowSize)
        let snapped = Grid.change(frame, cell: cell, dx: 0, dy: 0, dw: 0, dh: 0, monitors: displays.map(\.workArea))
        move(window, to: snapped)
    }

    // MARK: - Debugging

    func dumpTree() -> String {
        guard let autoTiler else { return "Auto-tiling is off" }
        return autoTiler.forest.debugDescription { [weak self] id in self?.windows[id]?.frame }
    }
}

// MARK: - TilingEnvironment

extension WindowManager: @preconcurrency TilingEnvironment {
    var gapOuter: Double { settings.gapOuter }
    var smartGaps: Bool { settings.smartGaps }

    func minimumSize(_ window: WindowID) -> Size? {
        minimumSizes[window]
    }

    func workArea(_ monitor: MonitorID) -> Rect? {
        display(monitor)?.workArea
    }

    /// The window server's frame of a window on screen, which needs no call to the app.
    func windowRect(_ window: WindowID) -> Rect? {
        guard let managed = windows[window] else { return nil }
        return Displays.onScreenFrame(of: window) ?? managed.frame
    }

    func workspaceKey(of window: WindowID) -> WorkspaceKey? {
        if let fork = autoTiler?.attached[window] {
            return autoTiler?.forest.toplevel(of: fork).workspace
        }
        return actualKey(of: window)
    }

    func previouslyFocused(excluding window: WindowID) -> WindowID? {
        for index in [1, 0] {
            if let prev = prevFocused[index], prev != window, windows[prev] != nil {
                return prev
            }
        }
        return nil
    }

    func isMinimized(_ window: WindowID) -> Bool {
        windows[window]?.isMinimized ?? true
    }

    /// The managed windows under a point, from front to back.
    ///
    /// The frames come from the window server, so a drag preview never waits for an app.
    func windows(at point: Point, key: WorkspaceKey) -> [WindowID] {
        Displays.onScreenFrames().compactMap { id, frame in
            guard windows[id] != nil, frame.contains(point), workspaceKey(of: id) == key else { return nil }
            return id
        }
    }

    func applyLayout(_ moves: [(WindowID, Rect)]) {
        // Only the selected tab of a moving stack glides. The windows behind it would trail
        // out of step and show at its edges, so they wait out of sight and arrive with it.
        var selectedTab: [WindowID: WindowID] = [:]
        if Motion.isOn, let autoTiler {
            let moving = Set(moves.map(\.0))
            for stack in autoTiler.forest.allStacks() where moving.contains(stack.active) {
                for id in stack.entities where id != stack.active {
                    selectedTab[id] = stack.active
                }
            }
        }
        var followers: [WindowID: [(id: WindowID, target: Rect)]] = [:]

        for (id, rect) in moves {
            guard let window = windows[id], maximized[id] == nil, !window.isFullscreen else { continue }
            var target = rect.rounded()
            let maxWidth = settings.maxWindowWidth
            if maxWidth > 0, target.width > maxWidth {
                target.x += ((target.width - maxWidth) / 2).rounded()
                target.width = maxWidth
            }
            lastApplied[id] = target
            if animator.target(of: id) == target { continue }
            if animator.target(of: id) == nil, let frame = Displays.onScreenFrame(of: id) ?? window.frame,
               frame.approximatelyEquals(target, tolerance: 1) { continue }
            lastSet[id] = Date()
            if let active = selectedTab[id], let hidden = hidingPlace(for: id) {
                animator.animate(window, from: hidden, to: hidden, duration: 0) {}
                followers[active, default: []].append((id, target))
                continue
            }
            move(window, to: target) { [weak self] in
                guard let self else { return }
                arrived(id, at: target)
                placeFollowers(of: id)
            }
        }
        for (active, list) in followers {
            stackFollowers[active] = list
            // A selected tab that is in place already does not glide, so its followers come at once.
            if animator.target(of: active) == nil { placeFollowers(of: active) }
        }
        if tileMode != nil { refreshTileOverlay() }
        scheduleHint()
        scheduleVerify()
    }

    /// Records that Pop Mac moved a window to its tile, and checks the frame soon.
    private func arrived(_ id: WindowID, at target: Rect) {
        // The window's own move events trail the move.
        lastSet[id] = Date()
        pendingVerify[id] = (target, false)
        scheduleVerify()
        scheduleHint()
    }

    /// Stops a gliding window where it is. Windows that wait for it go to their tiles at once.
    private func stopAnimation(_ id: WindowID) {
        animator.cancel(id)
        placeFollowers(of: id)
    }

    /// Moves the windows behind a stack's selected tab to their tile, now that the selected window is there.
    private func placeFollowers(of active: WindowID) {
        for follower in stackFollowers.removeValue(forKey: active) ?? [] {
            guard let window = windows[follower.id] else { continue }
            animator.animate(window, from: follower.target, to: follower.target, duration: 0) { [weak self] in
                self?.arrived(follower.id, at: follower.target)
            }
        }
    }

    /// A place just off the bottom-right corner of a window's display, where the window is out of sight.
    ///
    /// macOS keeps a sliver of the window on screen there. Nil if the window is not on screen.
    private func hidingPlace(for id: WindowID) -> Rect? {
        guard let frame = Displays.onScreenFrame(of: id), let display = Displays.display(for: frame, in: displays) else { return nil }
        return Rect(display.frame.maxX - 1, display.frame.maxY - 1, frame.width, frame.height)
    }

    /// Moves a window to `rect`. A window on screen glides there while animations are on.
    ///
    /// `done` runs when the window arrives, but not if another move replaces this one.
    func move(_ window: ManagedWindow, to rect: Rect, done: @escaping @MainActor () -> Void = {}) {
        if Motion.isOn, let from = Displays.onScreenFrame(of: window.id) {
            animator.animate(window, from: from, to: rect, done: done)
        } else {
            animator.cancel(window.id)
            window.setFrame(rect)
            done()
        }
    }

    /// Checks moved windows again after a moment, and fixes the ones that missed.
    ///
    /// macOS clamps a window to its old display while it crosses to another one,
    /// and some apps apply a new frame asynchronously, so a miss is retried once.
    /// A window that is still larger after the retry refuses that size: its size
    /// becomes its learned minimum, and its tree is tiled again around it.
    private func scheduleVerify() {
        guard !pendingVerify.isEmpty, !verifyScheduled else { return }
        verifyScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated { self?.verify() }
        }
    }

    private func verify() {
        verifyScheduled = false
        let pending = pendingVerify
        pendingVerify.removeAll()
        var retile = Set<WindowID>()

        for (id, entry) in pending {
            let target = entry.target
            // Skip windows that left the tree or got a new tile meanwhile.
            guard let window = windows[id], maximized[id] == nil,
                  autoTiler?.isAttached(id) == true, lastApplied[id] == target,
                  let frame = window.frame
            else { continue }

            if frame.approximatelyEquals(target, tolerance: 2) {
                forgetMinimum(id, accepted: frame)
            } else if !entry.retried {
                Log.debug("window \(id) missed its frame \(target), got \(frame); retrying")
                lastSet[id] = Date()
                window.setFrame(target)
                pendingVerify[id] = (target, true)
            } else if learnMinimum(id, target: target, frame: frame) {
                retile.insert(id)
            }
        }

        scheduleVerify()
        scheduleHint()
        for id in retile {
            autoTiler?.reflow(id)
        }
    }

    /// Records the size a window kept instead of a smaller target. Returns true if it is new.
    ///
    /// A target that fills the display along a side says nothing about a minimum
    /// on that side: some apps grow a window to the full display height.
    private func learnMinimum(_ id: WindowID, target: Rect, frame: Rect) -> Bool {
        let old = minimumSizes[id] ?? Size(width: 0, height: 0)
        var size = old
        let work = Displays.display(for: target, in: displays)?.workArea
        let full = 2 * settings.gapOuter + 2
        if frame.width > target.width + 2, target.width < (work?.width ?? .infinity) - full {
            size.width = max(size.width, frame.width)
        }
        if frame.height > target.height + 2, target.height < (work?.height ?? .infinity) - full {
            size.height = max(size.height, frame.height)
        }
        guard size != old else { return false }
        Log.debug("window \(id) needs at least \(size.width) x \(size.height)")
        minimumSizes[id] = size
        return true
    }

    /// Lowers a learned minimum when the window accepted a smaller size after all.
    private func forgetMinimum(_ id: WindowID, accepted frame: Rect) {
        guard var size = minimumSizes[id] else { return }
        size.width = min(size.width, frame.width)
        size.height = min(size.height, frame.height)
        minimumSizes[id] = size
    }

    /// Called after every layout change.
    func updateStacks(_: [StackNode]) {
        scheduleStacksRefresh()
        scheduleLayoutSave()
    }
}
