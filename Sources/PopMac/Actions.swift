import AppKit
import PopCore

/// State of tile mode, where the arrow keys move and resize the focused window.
struct TileMode {
    var window: WindowID
    var overlay: Rect
    /// The window selected for a swap with the tile-swap keys.
    var swapWindow: WindowID?
}

extension WindowManager {
    // MARK: - Key bindings

    /// Registers the bindings for the current mode.
    ///
    /// Tile mode replaces the global bindings, except the launcher and tile-enter.
    func registerHotkeys() {
        hotkeys.unregisterAll()
        let inTileMode = tileMode != nil
        for action in Action.allCases {
            let active = inTileMode
                ? (action.isTileMode || action == .activateLauncher || action == .tileEnter)
                : !action.isTileMode
            guard active else { continue }
            for combo in settings.combos(for: action) {
                hotkeys.register(combo) { [weak self] in
                    MainActor.assumeIsolated { self?.perform(action) }
                }
            }
        }
    }

    func perform(_ action: Action) {
        Log.debug("action \(action.rawValue)")
        switch action {
        case .activateLauncher: launcher.toggle()
        case .tileEnter: tileMode == nil ? enterTileMode() : acceptTileMode()
        case .focusLeft: focus(.left)
        case .focusDown: focus(.down)
        case .focusUp: focus(.up)
        case .focusRight: focus(.right)
        case .tileOrientation: toggleOrientation()
        case .toggleFloating: toggleFloating()
        case .toggleTiling: toggleTiling()
        case .toggleStackingGlobal: toggleStacking()
        case .tileMoveLeftGlobal: moveFocused(.left)
        case .tileMoveDownGlobal: moveFocused(.down)
        case .tileMoveUpGlobal: moveFocused(.up)
        case .tileMoveRightGlobal: moveFocused(.right)
        case .monitorLeft: moveToMonitor(.left)
        case .monitorRight: moveToMonitor(.right)
        case .monitorUp: moveToMonitor(.up)
        case .monitorDown: moveToMonitor(.down)
        case .workspaceUp: moveToSpace(next: false)
        case .workspaceDown: moveToSpace(next: true)
        case .toggleMaximize: toggleMaximize()
        case .closeWindow: focusedWindow()?.close()
        case .minimizeWindow: focusedWindow()?.minimize()
        case .managementOrientation: tileModeOrientation()
        case .toggleStacking: tileModeStacking()
        case .tileMoveLeft: tileModeMove(.left)
        case .tileMoveDown: tileModeMove(.down)
        case .tileMoveUp: tileModeMove(.up)
        case .tileMoveRight: tileModeMove(.right)
        case .tileResizeLeft: tileModeResize(.left)
        case .tileResizeDown: tileModeResize(.down)
        case .tileResizeUp: tileModeResize(.up)
        case .tileResizeRight: tileModeResize(.right)
        case .tileSwapLeft: tileModeSwap(.left)
        case .tileSwapDown: tileModeSwap(.down)
        case .tileSwapUp: tileModeSwap(.up)
        case .tileSwapRight: tileModeSwap(.right)
        case .tileAccept: acceptTileMode()
        case .tileReject: exitTileMode()
        }
    }

    // MARK: - Focus

    /// Focuses the nearest window in a direction. Left and right first cycle through stack tabs.
    func focus(_ direction: Direction) {
        guard let focused = focusedWindow() else { return }

        if direction == .left || direction == .right,
           let stack = autoTiler?.findStack(focused.id)?.stack,
           let index = stack.entities.firstIndex(of: focused.id) {
            let next = direction == .left ? index - 1 : index + 1
            if stack.entities.indices.contains(next) {
                activate(stack.entities[next])
                return
            }
        }

        if let next = selectWindow(direction, from: focused.id) {
            activate(next)
        }
    }

    // MARK: - Tiling actions

    func toggleOrientation() {
        guard let focused = focusedWindow(), let autoTiler else { return }
        if maximized[focused.id] != nil { return }
        autoTiler.toggleOrientation(focused.id)
    }

    /// Toggles a window between floating and tiling.
    func toggleFloating() {
        guard let focused = focusedWindow(), let autoTiler else { return }
        let id = focused.id

        if matchesFloatRule(focused) {
            if forceTile.contains(id) {
                forceTile.remove(id)
                autoTiler.detachWindow(id)
            } else {
                forceTile.insert(id)
                autoTiler.autoTile(id)
            }
        } else if floating.contains(id) {
            floating.remove(id)
            autoTiler.autoTile(id)
        } else if autoTiler.isAttached(id) {
            autoTiler.detachWindow(id)
            floating.insert(id)
        }

        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.activate(id, moveCursor: false) }
        }
    }

    func toggleStacking() {
        guard let focused = focusedWindow(), let autoTiler else { return }
        if floating.contains(focused.id) {
            floating.remove(focused.id)
            autoTiler.autoTile(focused.id)
        }
        autoTiler.toggleStacking(focused.id)
    }

    /// Moves the focused tiled window in a direction, outside tile mode.
    func moveFocused(_ direction: Direction) {
        guard let focused = focusedWindow() else { return }
        moveTiled(focused.id, direction)
    }

    /// Moves a tiled window in a direction: within its stack, onto a window, or onto a display.
    func moveTiled(_ id: WindowID, _ direction: Direction) {
        guard let autoTiler, autoTiler.isAttached(id) else { return }

        if autoTiler.findStack(id) != nil {
            autoTiler.moveFromStack(id, direction: direction)
        } else if let target = moveTarget(id, direction) {
            autoTiler.moveAuto(id, to: target, stackFromLeft: direction == .left)
        }

        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.activate(id) }
        }
    }

    /// Picks the window in a direction, or the display in that direction when it is closer.
    private func moveTarget(_ id: WindowID, _ direction: Direction) -> MoveTarget? {
        guard let rect = windows[id]?.frame,
              let display = Displays.display(for: rect, in: displays)
        else { return nil }

        let candidates = displays.map { MonitorCandidate(id: $0.id, workArea: $0.workArea) }
        let nextMonitor = MonitorLocator.locate(direction, from: MonitorCandidate(id: display.id, workArea: display.workArea), among: candidates)
        let nextKey = nextMonitor.flatMap { self.display($0.id) }.map { currentKey(of: $0) }

        guard let next = selectWindow(direction, from: id) else {
            return nextKey.map { .workspace($0) }
        }

        guard let nextMonitor, let nextKey, let nextRect = windows[next]?.frame,
              Displays.display(for: nextRect, in: displays)?.id != display.id
        else { return .window(next) }

        return nextMonitor.workArea.contains(nextRect) ? .window(next) : .workspace(nextKey)
    }

    // MARK: - Displays and Spaces

    func moveToMonitor(_ direction: Direction) {
        guard let focused = focusedWindow(), let rect = focused.frame,
              let display = Displays.display(for: rect, in: displays)
        else { return }

        let candidates = displays.map { MonitorCandidate(id: $0.id, workArea: $0.workArea) }
        guard let next = MonitorLocator.locate(direction, from: MonitorCandidate(id: display.id, workArea: display.workArea), among: candidates),
              let nextDisplay = self.display(next.id)
        else { return }

        if let autoTiler, autoTiler.isAttached(focused.id) {
            autoTiler.detachWindow(focused.id)
            autoTiler.attachToWorkspace(focused.id, key: currentKey(of: nextDisplay))
        } else {
            focused.setFrame(MonitorLocator.proportionalMove(rect, from: display.workArea, to: nextDisplay.workArea).rounded())
        }

        let id = focused.id
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.activate(id) }
        }
    }

    /// Moves the focused window to the previous or next Space, and follows it.
    func moveToSpace(next: Bool) {
        guard let focused = focusedWindow() else { return }
        exitTileMode()
        detachQuietly(focused.id)

        SpaceMover.move(focused, next: next) { [weak self] in
            MainActor.assumeIsolated {
                self?.scanVisibleWindows()
                self?.activate(focused.id)
            }
        }
    }

    func toggleMaximize() {
        guard let focused = focusedWindow(), let frame = focused.frame,
              let display = Displays.display(for: frame, in: displays)
        else { return }

        if maximized.removeValue(forKey: focused.id) != nil || frame.approximatelyEquals(display.workArea, tolerance: 4) {
            if autoTiler?.isAttached(focused.id) == true {
                autoTiler?.reflow(focused.id)
            } else if let prev = prevRect[focused.id] {
                focused.setFrame(prev)
            }
        } else {
            maximized[focused.id] = frame
            focused.setFrame(display.workArea)
            focused.focus()
        }
        scheduleHint()
    }

    // MARK: - Tile mode

    func enterTileMode() {
        guard tileMode == nil, let focused = focusedWindow(), var rect = focused.frame else { return }

        if maximized.removeValue(forKey: focused.id) != nil {
            autoTiler?.reflow(focused.id)
            rect = focused.frame ?? rect
        }

        if autoTiler?.isAttached(focused.id) != true, let cell = gridCell(for: rect) {
            rect = Grid.change(rect, cell: cell, dx: 0, dy: 0, dw: 0, dh: 0, monitors: displays.map(\.workArea))
        }

        tileMode = TileMode(window: focused.id, overlay: rect, swapWindow: nil)
        hint.hide()
        overlay.show(rect)
        registerHotkeys()
    }

    func exitTileMode() {
        guard tileMode != nil else { return }
        tileMode = nil
        overlay.hide()
        registerHotkeys()
        scheduleHint()
    }

    func acceptTileMode() {
        guard let mode = tileMode, let window = windows[mode.window] else {
            exitTileMode()
            return
        }

        var treeSwapped = false
        if let swap = mode.swapWindow, let other = windows[swap] {
            if let autoTiler, autoTiler.isAttached(swap), autoTiler.isAttached(mode.window) {
                autoTiler.attachSwap(swap, mode.window)
                treeSwapped = true
            } else if let frame = window.frame {
                other.setFrame(frame)
            }
        }

        if !treeSwapped && autoTiler?.isAttached(mode.window) != true {
            window.setFrame(mode.overlay)
        }

        exitTileMode()
        activate(mode.window, moveCursor: false)
    }

    /// Keeps the overlay on the tile-mode window after the layout changed.
    func refreshTileOverlay() {
        guard var mode = tileMode, mode.swapWindow == nil,
              autoTiler?.isAttached(mode.window) == true,
              let frame = windows[mode.window]?.frame
        else { return }
        mode.overlay = frame
        tileMode = mode
        overlay.show(frame)
    }

    private func gridCell(for rect: Rect) -> Rect? {
        guard let display = Displays.display(for: rect, in: displays) else { return nil }
        return Grid.cell(monitor: display.workArea, columnSize: settings.columnSize, rowSize: settings.rowSize)
    }

    /// Moves or resizes the tile-mode overlay by grid cells, for floating windows.
    private func changeOverlay(dx: Double, dy: Double, dw: Double, dh: Double) {
        guard var mode = tileMode, let cell = gridCell(for: mode.overlay) else { return }
        mode.swapWindow = nil
        let monitors = displays.map(\.workArea)
        let changed = Grid.change(mode.overlay, cell: cell, dx: dx, dy: dy, dw: dw, dh: dh, monitors: monitors)
        mode.overlay = Grid.change(changed, cell: cell, dx: 0, dy: 0, dw: 0, dh: 0, monitors: monitors)
        tileMode = mode
        overlay.show(mode.overlay)
    }

    private func tileModeMove(_ direction: Direction) {
        guard let mode = tileMode else { return }
        if let autoTiler, autoTiler.isAttached(mode.window) {
            tileMode?.swapWindow = nil
            moveTiled(mode.window, direction)
            refreshTileOverlay()
        } else {
            switch direction {
            case .left: changeOverlay(dx: -1, dy: 0, dw: 0, dh: 0)
            case .right: changeOverlay(dx: 1, dy: 0, dw: 0, dh: 0)
            case .up: changeOverlay(dx: 0, dy: -1, dw: 0, dh: 0)
            case .down: changeOverlay(dx: 0, dy: 1, dw: 0, dh: 0)
            }
        }
    }

    private func tileModeResize(_ direction: Direction) {
        guard let mode = tileMode else { return }
        if let autoTiler, autoTiler.isAttached(mode.window) {
            tileMode?.swapWindow = nil
            autoTiler.resizeAuto(mode.window, direction: direction, step: max(settings.columnSize, 16))
            refreshTileOverlay()
        } else {
            switch direction {
            case .left: changeOverlay(dx: 0, dy: 0, dw: -1, dh: 0)
            case .right: changeOverlay(dx: 0, dy: 0, dw: 1, dh: 0)
            case .up: changeOverlay(dx: 0, dy: 0, dw: 0, dh: -1)
            case .down: changeOverlay(dx: 0, dy: 0, dw: 0, dh: 1)
            }
        }
    }

    private func tileModeSwap(_ direction: Direction) {
        guard var mode = tileMode else { return }
        let from = mode.swapWindow ?? mode.window
        guard let selected = selectWindow(direction, from: from), selected != mode.window,
              let frame = windows[selected]?.frame
        else { return }
        mode.swapWindow = selected
        mode.overlay = frame
        tileMode = mode
        overlay.show(frame)
    }

    private func tileModeOrientation() {
        guard let mode = tileMode, let autoTiler else { return }
        autoTiler.toggleOrientation(mode.window)
        refreshTileOverlay()
    }

    private func tileModeStacking() {
        guard let mode = tileMode, let autoTiler else { return }
        if floating.contains(mode.window) {
            floating.remove(mode.window)
            autoTiler.autoTile(mode.window)
        }
        autoTiler.toggleStacking(mode.window)
        refreshTileOverlay()
    }

    // MARK: - Floating exceptions

    /// Adds a float rule for the focused window's application.
    func addAppException() {
        guard let focused = focusedWindow() else { return }
        let rule = FloatRule(app: "^" + NSRegularExpression.escapedPattern(for: focused.bundleID) + "$")
        addException(rule, for: focused)
    }

    /// Adds a float rule for the focused window's application and title.
    func addWindowException() {
        guard let focused = focusedWindow() else { return }
        let rule = FloatRule(
            app: "^" + NSRegularExpression.escapedPattern(for: focused.bundleID) + "$",
            title: "^" + NSRegularExpression.escapedPattern(for: focused.title) + "$"
        )
        addException(rule, for: focused)
    }

    private func addException(_ rule: FloatRule, for window: ManagedWindow) {
        guard !settings.floatRules.contains(rule) else { return }
        forceTile.remove(window.id)
        update { $0.floatRules.append(rule) }
        for other in windows.values where autoTiler?.isAttached(other.id) == true && !isTilable(other.id) {
            autoTiler?.detachWindow(other.id)
        }
    }
}
