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
    /// Windows that match a float rule, but that the user made tile.
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
    private let tabs = StackTabsController()
    let hotkeys = HotkeyManager()
    private(set) lazy var launcher = Launcher(manager: self)
    private var mouse: MouseMonitor?
    var tileMode: TileMode?
    private var hintScheduled = false
    private var stacksScheduled = false
    private var spaceScanScheduled = false

    init(settings: Settings) {
        self.settings = settings
    }

    // MARK: - Startup

    func start() {
        applyStyles()
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

        let mouse = MouseMonitor(manager: self)
        mouse.start()
        self.mouse = mouse
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
            MainActor.assumeIsolated { self?.removeApp(app.processIdentifier) }
        }
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let focused = self.focusedWindow() else { return }
                self.onFocused(focused)
            }
        }
        center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onSpaceChanged() }
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
        if settings.superModifiers != old.superModifiers || settings.primaryModifiers != old.primaryModifiers
            || settings.keybindings != old.keybindings {
            registerHotkeys()
        }
        if settings.tileByDefault != old.tileByDefault {
            settings.tileByDefault ? autoTileOn() : autoTileOff()
        }
        if let autoTiler, settings.gapInner != old.gapInner || settings.gapOuter != old.gapOuter
            || settings.smartGaps != old.smartGaps || settings.maxWindowWidth != old.maxWindowWidth
            || settings.floatRules != old.floatRules {
            autoTiler.forest.gapInner = settings.gapInner
            retileAll()
        }
        scheduleStacksRefresh()
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

    var hintColor: NSColor {
        NSColor(hex: settings.hintColor) ?? NSColor(srgbRed: 0.98, green: 0.72, blue: 0.42, alpha: 1)
    }

    private func applyStyles() {
        overlay.style(color: hintColor, radius: settings.activeHintBorderRadius)
        hint.style(color: hintColor, width: settings.activeHintWidth, radius: settings.activeHintBorderRadius)
    }

    // MARK: - Applications

    private func addApp(_ app: NSRunningApplication, attempt: Int = 0) {
        let pid = app.processIdentifier
        guard observers[pid] == nil, pid != ProcessInfo.processInfo.processIdentifier,
              app.activationPolicy == .regular, !app.isTerminated
        else { return }

        guard let observer = AppObserver(app: app, handler: { [weak self] observer, event in
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

        let window = ManagedWindow(id: id, element: element, app: observer.app, appElement: observer.element)
        // Minimized windows report the dialog subrole until they are restored.
        guard window.isStandard || (window.role == kAXWindowRole && window.isMinimized) else { return nil }

        windows[id] = window
        observer.watch(element)
        Log.debug("registered \(window.appName): \(window.title) (\(id))")
        return window
    }

    /// Finds the tracked window for an element, even after it was destroyed.
    private func lookup(_ element: AXUIElement, pid: pid_t) -> WindowID? {
        if let id = AX.windowID(element), windows[id] != nil { return id }
        return windows.values.first { $0.pid == pid && CFEqual($0.element, element) }?.id
    }

    func focusedWindow() -> ManagedWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let observer = observers[app.processIdentifier],
              let element = observer.focusedWindow()
        else { return nil }
        if let id = lookup(element, pid: app.processIdentifier) { return windows[id] }
        return register(element, observer)
    }

    private func handle(_ observer: AppObserver, _ event: AXEvent) {
        let pid = observer.app.processIdentifier

        switch event {
        case .windowCreated(let element):
            // Give the application a moment to set the window's final frame.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                MainActor.assumeIsolated { self?.onWindowCreated(element, observer) }
            }

        case .windowDestroyed(let element):
            if let id = lookup(element, pid: pid) { onDestroy(id) }

        case .focusedWindowChanged(let element):
            var id = lookup(element, pid: pid)
            if id == nil, let window = register(element, observer) {
                // A window that was not standard when it was created.
                id = window.id
                autoTileIfNeeded(window.id)
            }
            if let id, let window = windows[id], NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                onFocused(window)
            }

        case .windowMinimized(let element):
            if let id = lookup(element, pid: pid) { onMinimize(id, minimized: true) }

        case .windowDeminimized(let element):
            if let id = lookup(element, pid: pid) { onMinimize(id, minimized: false) }

        case .windowMoved(let element), .windowResized(let element):
            if let id = lookup(element, pid: pid) {
                if id == prevFocused[1] { scheduleHint() }
                if autoTiler?.findStack(id) != nil { scheduleStacksRefresh() }
            }

        case .titleChanged(let element):
            if let id = lookup(element, pid: pid), autoTiler?.findStack(id) != nil {
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

    private func autoTileIfNeeded(_ id: WindowID) {
        guard let autoTiler, !autoTiler.isAttached(id), isTilable(id) else { return }
        autoTiler.autoTile(id, ignoreFocus: false)
    }

    private func onDestroy(_ id: WindowID) {
        if tileMode?.window == id { exitTileMode() }

        if prevFocused[0] == id {
            prevFocused[0] = nil
        } else if prevFocused[1] == id {
            prevFocused[1] = prevFocused[0]
            prevFocused[0] = nil
        }

        windows.removeValue(forKey: id)
        autoTiler?.detachWindow(id)
        floating.remove(id)
        forceTile.remove(id)
        maximized.removeValue(forKey: id)
        prevRect.removeValue(forKey: id)
        minimizedAttachments.removeValue(forKey: id)
        scheduleHint()
    }

    func onFocused(_ window: ManagedWindow) {
        if prevFocused[1] != window.id {
            prevFocused[0] = prevFocused[1]
            prevFocused[1] = window.id
        }

        if let stack = autoTiler?.findStack(window.id)?.stack, stack.active != window.id {
            stack.active = window.id
            scheduleStacksRefresh()
        }

        scheduleHint()

        if settings.logOnFocus {
            var message = window.describe()
            if let fork = autoTiler?.attached[window.id] {
                message += "\n  fork: \(fork.id), workspace: \(fork.workspace)"
            }
            Log.info(message)
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
            if let attachment = minimizedAttachments.removeValue(forKey: id), autoTiler.restore(id, to: attachment) {
                return
            }
            autoTiler.autoTile(id)
        }
    }

    // MARK: - Spaces and displays

    private func onSpaceChanged() {
        exitTileMode()
        hint.hide()
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

    /// Finds new windows on the visible Spaces, and fixes windows that changed Space.
    func scanVisibleWindows() {
        displays = Displays.all()
        for observer in observers.values {
            for element in observer.windows() {
                register(element, observer)
            }
        }

        if let autoTiler {
            let visible = Displays.onScreenWindowIDs()
            for id in visible.reversed() {
                guard windows[id] != nil else { continue }
                if let fork = autoTiler.attached[id] {
                    let key = autoTiler.forest.toplevel(of: fork).workspace
                    if let actual = actualKey(of: id), actual != key {
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
        guard let window = windows[id], let frame = window.frame,
              let display = Displays.display(for: frame, in: displays)
        else { return nil }
        let space = Spaces.space(of: id) ?? Displays.currentSpace(of: display)
        return WorkspaceKey(monitor: display.id, space: space)
    }

    // MARK: - Tiling state

    func isTilable(_ id: WindowID) -> Bool {
        guard let window = windows[id], !floating.contains(id) else { return false }
        guard window.isStandard, !window.isMinimized, !window.isFullscreen, !window.isHidden else { return false }
        if FloatRules.windowShallFloat(appName: window.appName, bundleID: window.bundleID, title: window.title, userRules: settings.floatRules) {
            return forceTile.contains(id)
        }
        return window.isResizable
    }

    /// True if the window matches a float rule.
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

        // Tile from back to front, so the frontmost window is split last.
        for id in Displays.onScreenWindowIDs().reversed() where windows[id] != nil && isTilable(id) {
            tiler.autoTile(id, ignoreFocus: true)
        }
        onStateChange?()
    }

    func autoTileOff() {
        guard let tiler = autoTiler else { return }
        exitTileMode()
        tiler.destroy()
        autoTiler = nil
        tabs.removeAll()
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
        if let rect = pendingRestore.removeValue(forKey: id) {
            prevRect[id] = rect
        } else if prevRect[id] == nil, let frame = windows[id]?.frame {
            prevRect[id] = frame
        }
    }

    /// Returns a window to its pre-tiling frame, unless it is re-attached in the same turn.
    private func onTileDetach(_ id: WindowID) {
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
            window.setFrame(rect)
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

    // MARK: - Focus

    /// Windows that are visible on screen, from front to back.
    func activeWindowList() -> [ManagedWindow] {
        Displays.onScreenWindowIDs().compactMap { windows[$0] }
    }

    func selectWindow(_ direction: Direction, from id: WindowID) -> WindowID? {
        guard let rect = windows[id]?.frame else { return nil }
        let candidates = activeWindowList().compactMap { window -> WindowCandidate? in
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
        if moveCursor && settings.mouseCursorFollowsActiveWindow, let frame = window.frame {
            let point = settings.mouseCursorFocusLocation.point(in: frame)
            CGWarpMouseCursorPosition(CGPoint(x: point.x, y: point.y))
            CGAssociateMouseAndMouseCursorPosition(1)
        }
    }

    // MARK: - Decorations

    func scheduleHint() {
        guard !hintScheduled else { return }
        hintScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.hintScheduled = false
                self?.updateHint()
            }
        }
    }

    private func updateHint() {
        guard settings.activeHint, tileMode == nil,
              let id = prevFocused[1], let window = windows[id],
              NSWorkspace.shared.frontmostApplication?.processIdentifier == window.pid,
              !window.isMinimized, !window.isHidden, !window.isFullscreen,
              let frame = window.frame
        else {
            hint.hide()
            return
        }
        hint.show(around: frame, above: id)
    }

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

    private func refreshStacks() {
        guard let autoTiler, settings.showStackTabs else {
            tabs.removeAll()
            return
        }

        let current = Set(displays.map { currentKey(of: $0) })
        let height = autoTiler.forest.tabHeight
        let entries = autoTiler.forest.allStacks().compactMap { stack -> (stack: StackNode, frame: Rect, tabs: [StackTabBar.Tab])? in
            guard let rect = stack.rect, current.contains(stack.workspace), !stack.entities.isEmpty else { return nil }
            let tabs = stack.entities.compactMap { id -> StackTabBar.Tab? in
                guard let window = windows[id] else { return nil }
                return StackTabBar.Tab(id: id, title: window.title, icon: window.app.icon)
            }
            return (stack, Rect(rect.x, rect.y - height, rect.width, height - 2), tabs)
        }

        tabs.sync(entries, color: hintColor) { [weak self] id in
            MainActor.assumeIsolated { self?.activate(id, moveCursor: false) }
        }
    }

    // MARK: - Mouse

    /// Shows where a dragged window would land.
    func dragPreview(_ id: WindowID) {
        guard let autoTiler, autoTiler.isAttached(id) else {
            overlay.hide()
            return
        }
        let cursor = Displays.cursor
        guard let display = Displays.display(at: cursor, in: displays),
              let rect = autoTiler.dropPreview(id, cursor: cursor, key: currentKey(of: display))
        else {
            overlay.hide()
            return
        }
        overlay.show(rect)
    }

    /// Handles the end of a mouse drag or resize of a window.
    func onGrabEnd(_ id: WindowID, original: Rect) {
        overlay.hide()
        guard let window = windows[id], let current = window.frame else { return }
        if current.approximatelyEquals(original, tolerance: 1) { return }

        guard let autoTiler else {
            if settings.snapToGrid { snap(window) }
            return
        }
        guard autoTiler.isAttached(id) else { return }

        let sizeChanged = abs(current.width - original.width) > 2 || abs(current.height - original.height) > 2
        if sizeChanged {
            autoTiler.resizeByMouse(id, from: original, to: current)
        } else {
            let cursor = Displays.cursor
            guard let display = Displays.display(at: cursor, in: displays) else { return }
            let key = currentKey(of: display)
            let previous = autoTiler.attached[id].map { autoTiler.forest.toplevel(of: $0).workspace }
            autoTiler.onDrop(id, cursor: cursor, key: key, viaOverview: previous?.monitor != key.monitor)
        }
        scheduleHint()
    }

    /// Snaps a floating window to the display grid.
    func snap(_ window: ManagedWindow) {
        guard let frame = window.frame, let display = Displays.display(for: frame, in: displays) else { return }
        let cell = Grid.cell(monitor: display.workArea, columnSize: settings.columnSize, rowSize: settings.rowSize)
        let snapped = Grid.change(frame, cell: cell, dx: 0, dy: 0, dw: 0, dh: 0, monitors: displays.map(\.workArea))
        window.setFrame(snapped)
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
    var stackingWithMouse: Bool { settings.stackingWithMouse }

    func workArea(_ monitor: MonitorID) -> Rect? {
        display(monitor)?.workArea
    }

    func windowRect(_ window: WindowID) -> Rect? {
        windows[window]?.frame
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

    func windows(at point: Point, key: WorkspaceKey) -> [WindowID] {
        Displays.onScreenWindowIDs().filter { id in
            guard let frame = windows[id]?.frame, frame.contains(point) else { return false }
            return workspaceKey(of: id) == key
        }
    }

    func applyLayout(_ moves: [(WindowID, Rect)]) {
        for (id, rect) in moves {
            guard let window = windows[id], maximized[id] == nil else { continue }
            var target = rect.rounded()
            let maxWidth = settings.maxWindowWidth
            if maxWidth > 0 && target.width > maxWidth {
                target.x += ((target.width - maxWidth) / 2).rounded()
                target.width = maxWidth
            }
            if let frame = window.frame, frame.approximatelyEquals(target, tolerance: 1) { continue }
            window.setFrame(target)
        }
        if tileMode != nil { refreshTileOverlay() }
        scheduleHint()
    }

    func updateStacks(_ stacks: [StackNode]) {
        scheduleStacksRefresh()
    }
}
