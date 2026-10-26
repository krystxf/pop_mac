import Foundation

/// What the auto-tiler needs to know about the outside world.
public protocol TilingEnvironment: AnyObject {
    var gapOuter: Double { get }
    var smartGaps: Bool { get }

    /// The usable area of a display, without the menu bar and the Dock.
    func workArea(_ monitor: MonitorID) -> Rect?
    func windowRect(_ window: WindowID) -> Rect?
    func workspaceKey(of window: WindowID) -> WorkspaceKey?
    /// The most recently focused window that is not `window`.
    func previouslyFocused(excluding window: WindowID) -> WindowID?
    func isTilable(_ window: WindowID) -> Bool
    func isMinimized(_ window: WindowID) -> Bool
    /// Windows below a point on a workspace, from front to back.
    func windows(at point: Point, key: WorkspaceKey) -> [WindowID]

    /// Moves windows to their calculated positions.
    func applyLayout(_ moves: [(WindowID, Rect)])
}

/// Where a window should go when it is moved with the keyboard.
public enum MoveTarget: Equatable {
    case window(WindowID)
    case workspace(WorkspaceKey)
}

/// Automatically arranges windows into a tree of forks.
public final class AutoTiler {
    public let forest = Forest()
    public unowned let env: TilingEnvironment

    public init(env: TilingEnvironment, gapInner: Double) {
        self.env = env
        forest.gapInner = gapInner
    }

    public var attached: [WindowID: Fork] { forest.attached }

    public func isAttached(_ window: WindowID) -> Bool {
        forest.attached[window] != nil
    }

    // MARK: - Layout

    /// Measures a fork, and moves the windows into their new positions.
    public func tile(_ fork: Fork, area: Rect) {
        forest.measure(fork, area: area)
        arrange()
    }

    /// Re-tiles the whole tree that a fork belongs to.
    public func retile(_ fork: Fork) {
        let top = forest.toplevel(of: fork)
        tile(top, area: top.area)
    }

    /// Re-tiles the tree that a window belongs to.
    public func reflow(_ window: WindowID) {
        if let fork = forest.attached[window] { retile(fork) }
    }

    /// Applies every calculated position.
    public func arrange() {
        let moves = forest.requested
        forest.requested.removeAll()
        env.applyLayout(moves)
    }

    private func outerArea(_ monitor: MonitorID) -> Rect? {
        env.workArea(monitor)?.inset(by: env.gapOuter)
    }

    /// Recalculates the area of a top-level fork, after a display or gap change.
    public func updateToplevel(_ fork: Fork) {
        guard var rect = env.workArea(fork.workspace.monitor) else { return }
        fork.smartGapped = env.smartGaps && fork.right == nil
        if !fork.smartGapped {
            rect = rect.inset(by: env.gapOuter)
        }
        fork.area = rect
        fork.lengthLeft = (fork.prevRatio * fork.length).rounded()
        tile(fork, area: fork.area)
    }

    /// Recalculates every tree.
    public func updateAllToplevels() {
        for fork in forest.toplevels.values {
            updateToplevel(fork)
        }
    }

    /// Clears the smart gap of a top-level fork when it gains a second branch.
    private func unsmartGap(_ fork: Fork) {
        if fork.isToplevel && fork.smartGapped, let rect = outerArea(fork.workspace.monitor) {
            fork.smartGapped = false
            fork.area = rect
        }
    }

    // MARK: - Attaching

    /// Makes the window the only tile of a new tree on a display.
    public func attachToMonitor(_ window: WindowID, key: WorkspaceKey) {
        // A workspace has one tree. Never replace a tree that still holds windows.
        if let top = forest.findToplevel(key),
           let onto = forest.windows(in: top).first(where: { $0 != window }),
           attachToWindow(onto, window, moveBy: .auto) {
            return
        }
        guard var rect = env.workArea(key.monitor) else { return }
        let smart = env.smartGaps
        if !smart {
            rect = rect.inset(by: env.gapOuter)
        }
        let fork = forest.createToplevel(window: window, area: rect, workspace: key)
        fork.smartGapped = smart
        tile(fork, area: rect)
    }

    /// Tiles a window into another window's place.
    @discardableResult
    public func attachToWindow(_ onto: WindowID, _ window: WindowID, moveBy: MoveBy) -> Bool {
        guard let fork = forest.attachWindow(onto: onto, new: window, placeBy: moveBy) else {
            return false
        }
        if fork.right != nil { unsmartGap(fork) }
        tile(fork, area: fork.area)
        return true
    }

    /// Tiles a window onto the largest window of a workspace, or onto the display.
    public func attachToWorkspace(_ window: WindowID, key: WorkspaceKey) {
        if let top = forest.findToplevel(key),
           let onto = forest.largestWindow(in: top, rect: tilableRect)
               ?? forest.windows(in: top).first(where: { $0 != window }),
           attachToWindow(onto, window, moveBy: .auto) {
            return
        }
        attachToMonitor(window, key: key)
    }

    private func tilableRect(_ window: WindowID) -> Rect? {
        env.isTilable(window) ? env.windowRect(window) : nil
    }

    /// Automatically tiles a window into the tree.
    ///
    /// First tries to tile onto the previously focused window, then onto the workspace.
    public func autoTile(_ window: WindowID, ignoreFocus: Bool = false) {
        let onto = fetchMode(window, ignoreFocus: ignoreFocus)
        detachWindow(window)
        if let onto, attachToWindow(onto, window, moveBy: .auto) {
            return
        }
        guard let key = env.workspaceKey(of: window) else { return }
        attachToWorkspace(window, key: key)
    }

    private func fetchMode(_ window: WindowID, ignoreFocus: Bool) -> WindowID? {
        guard !ignoreFocus,
              let prev = env.previouslyFocused(excluding: window),
              prev != window,
              env.isTilable(prev),
              !env.isMinimized(prev),
              isAttached(prev),
              let a = env.workspaceKey(of: prev),
              let b = env.workspaceKey(of: window),
              a == b
        else { return nil }
        return prev
    }

    // MARK: - Detaching

    /// Detaches the window from the tree, if it is attached.
    public func detachWindow(_ window: WindowID) {
        guard let fork = forest.takeAttached(window) else { return }
        guard let reflow = forest.detach(fork, window: window) else { return }
        if reflow.isToplevel && env.smartGaps && reflow.right == nil, let rect = env.workArea(reflow.workspace.monitor) {
            reflow.area = rect
            reflow.smartGapped = true
        }
        tile(reflow, area: reflow.area)
    }

    /// Detaches every window, and forgets every tree.
    public func destroy() {
        for window in Array(forest.attached.keys) {
            forest.takeAttached(window)
            forest.onDetach?(window)
        }
    }

    // MARK: - Queries

    public func windowsAreSiblings(_ a: WindowID, _ b: WindowID) -> Fork? {
        if let fa = forest.attached[a], let fb = forest.attached[b], fa === fb { return fa }
        return nil
    }

    public func largestOnWorkspace(_ key: WorkspaceKey) -> WindowID? {
        guard let top = forest.findToplevel(key) else { return nil }
        return forest.largestWindow(in: top, rect: tilableRect)
    }

    // MARK: - Orientation

    /// Toggles the orientation of the fork that holds the window.
    public func toggleOrientation(_ window: WindowID) {
        guard let fork = forest.attached[window], fork.right != nil else { return }
        fork.toggleOrientation()
        forest.measure(fork, area: fork.area)
        for node in forest.iter(fork) {
            if case .fork(let child) = node {
                child.rebalanceOrientation()
                forest.measure(child, area: child.area)
            }
        }
        arrange()
    }

    // MARK: - Swapping

    /// Swaps the positions of two windows in the tree.
    public func attachSwap(_ a: WindowID, _ b: WindowID) {
        guard a != b, let aFork = forest.attached[a], let bFork = forest.attached[b] else { return }

        func replace(_ fork: Fork, _ x: WindowID, with y: WindowID) -> (() -> Void)? {
            if fork.left.isWindow(x) { return { fork.left = .window(y) } }
            if let right = fork.right, right.isWindow(x) { return { fork.right = .window(y) } }
            return nil
        }

        let fa = replace(aFork, a, with: b)
        let fb = replace(bFork, b, with: a)
        fa?()
        fb?()

        retile(aFork)
        if forest.toplevel(of: aFork) !== forest.toplevel(of: bFork) {
            retile(bFork)
        }
    }

    /// Puts `new` in the place of `old`, which leaves the tree without a reflow of its neighbors.
    ///
    /// Used for native macOS tabs: each tab is a window, and only the selected one is shown.
    @discardableResult
    public func replace(_ old: WindowID, with new: WindowID) -> Bool {
        guard old != new, let fork = forest.attached[old], forest.attached[new] == nil else { return false }

        forest.takeAttached(old)
        if fork.left.isWindow(old) {
            fork.left = .window(new)
        } else if let right = fork.right, right.isWindow(old) {
            fork.right = .window(new)
        } else {
            forest.setAttached(old, fork)
            return false
        }
        retile(fork)
        return true
    }

    // MARK: - Keyboard movement

    /// Moves the focused window onto another window, or onto another display.
    public func moveAuto(_ focused: WindowID, to target: MoveTarget) {
        switch target {
        case .window(let moveTo):
            if let parent = windowsAreSiblings(focused, moveTo), parent.right != nil {
                parent.swapBranches()
                retile(parent)
                return
            }

            guard let src = env.windowRect(focused) else { return }
            detachWindow(focused)
            if !attachToWindow(moveTo, focused, moveBy: .keyboard(src: src)),
               let key = env.workspaceKey(of: moveTo) {
                attachToWorkspace(focused, key: key)
            }

        case .workspace(let key):
            detachWindow(focused)
            attachToWorkspace(focused, key: key)
        }
    }

    /// Grows or shrinks a tiled window by one step with the keyboard.
    ///
    /// Right and down grow the window. Left and up shrink it.
    public func resizeAuto(_ window: WindowID, direction: Direction, step: Double = 64) {
        guard let fork = forest.attached[window],
              var crect = forest.tileRects[window] ?? env.windowRect(window)
        else { return }

        let toparea = forest.toplevel(of: fork).area
        var grabRect = crect

        let moves: [Rect]
        switch direction {
        case .left: moves = [Rect(step, 0, -step, 0), Rect(0, 0, -step, 0)]
        case .right: moves = [Rect(0, 0, step, 0), Rect(-step, 0, step, 0)]
        case .up: moves = [Rect(0, step, 0, -step), Rect(0, 0, 0, -step)]
        case .down: moves = [Rect(0, 0, 0, step), Rect(0, -step, 0, step)]
        }

        forest.manuallyMoved = true
        defer { forest.manuallyMoved = false }

        for mov in moves {
            crect.apply(mov)
            let before = crect
            crect.clamp(toparea)
            let diff = before.diff(crect)
            crect.apply(Rect(0, 0, -diff.x, -diff.y))

            if crect == grabRect { continue }
            guard let current = forest.attached[window] else { break }
            forest.resize(fork: current, window: window, movement: Movement.calculate(from: grabRect, change: crect), crect: crect)
            grabRect = crect
        }

        arrange()
    }

    /// Applies a resize that the user made with the mouse.
    public func resizeByMouse(_ window: WindowID, from frame: Rect, to newFrame: Rect) {
        guard let fork = forest.attached[window] else { return }
        // The tile can be larger than the window, for example with a maximum width.
        // Move the tile's edges by as much as the window's edges moved.
        let original = forest.tileRects[window] ?? frame
        let x = original.x + (newFrame.x - frame.x)
        let y = original.y + (newFrame.y - frame.y)
        let maxX = original.maxX + (newFrame.maxX - frame.maxX)
        let maxY = original.maxY + (newFrame.maxY - frame.maxY)
        var crect = Rect(x, y, maxX - x, maxY - y)
        crect.clamp(forest.toplevel(of: fork).area)

        let movement = Movement.calculate(from: original, change: crect)
        forest.manuallyMoved = true
        defer { forest.manuallyMoved = false }
        if movement == .none || movement == .moved {
            retile(fork)
            return
        }
        forest.resize(fork: fork, window: window, movement: movement, crect: crect)
        arrange()
    }

    // MARK: - Mouse drops

    /// Derives how a window attaches from the side of `area` nearest to the cursor.
    public func cursorPlacement(area: Rect, cursor: Point) -> (orientation: Orientation, swap: Bool) {
        switch Geom.nearestSide(cursor, area, allowCenter: false).1 {
        case .left: return (.horizontal, true)
        case .top: return (.vertical, true)
        case .bottom: return (.vertical, false)
        case .right, .center: return (.horizontal, false)
        }
    }

    /// The window that a dragged window would attach to if dropped at the cursor.
    public func dropTarget(_ window: WindowID, cursor: Point, key: WorkspaceKey) -> WindowID? {
        if let found = env.windows(at: cursor, key: key).first(where: { $0 != window && isAttached($0) }) {
            return found
        }
        guard let fork = forest.attached[window] else { return nil }
        if case .window(let l) = fork.left, case .window(let r)? = fork.right {
            return l == window ? r : l
        }
        return nil
    }

    /// The target's tile, if the cursor is in the center zone of that tile.
    private func centerTile(of target: WindowID, cursor: Point) -> Rect? {
        guard let tile = forest.tileRects[target] ?? env.windowRect(target), tile.contains(cursor),
              Geom.nearestSide(cursor, tile, allowCenter: true).1 == .center
        else { return nil }
        return tile
    }

    /// The area that the overlay shows while a window is dragged.
    public func dropPreview(_ window: WindowID, cursor: Point, key: WorkspaceKey) -> Rect? {
        guard let fork = forest.attached[window] else { return nil }

        if largestOnWorkspace(key) == nil {
            return outerArea(key.monitor)
        }

        guard let target = dropTarget(window, cursor: cursor, key: key) else { return nil }

        // A drop on the center swaps, so show the target's tile.
        if let tile = centerTile(of: target, cursor: cursor) {
            return tile
        }

        let area: Rect
        if windowsAreSiblings(window, target) != nil {
            area = fork.area
        } else if let r = env.windowRect(target) {
            area = r
        } else {
            return nil
        }

        let (orientation, swap) = cursorPlacement(area: area, cursor: cursor)
        let hw = area.width / 2, hh = area.height / 2
        switch (orientation, swap) {
        case (.horizontal, true): return Rect(area.x, area.y, hw, area.height)
        case (.horizontal, false): return Rect(area.x + hw, area.y, hw, area.height)
        case (.vertical, true): return Rect(area.x, area.y, area.width, hh)
        case (.vertical, false): return Rect(area.x, area.y + hh, area.width, hh)
        }
    }

    /// Handles a tiled window that the user dropped with the mouse.
    ///
    /// - If the window is dropped onto a window, tile onto it.
    /// - If no window is present, tile onto the display.
    public func onDrop(_ window: WindowID, cursor: Point, key: WorkspaceKey, viaOverview: Bool = false) {
        var viaOverview = viaOverview
        if let r = env.windowRect(window), r.contains(cursor) {
            viaOverview = false
        }

        let attachMonitor = {
            if let onto = self.largestOnWorkspace(key), onto != window {
                self.attachToWindow(onto, window, moveBy: .auto)
            } else {
                self.attachToMonitor(window, key: key)
            }
        }

        if viaOverview {
            detachWindow(window)
            attachMonitor()
            return
        }

        var attachTo = env.windows(at: cursor, key: key).first { $0 != window && isAttached($0) }

        guard let fork = forest.attached[window] else { return }

        let windowless = largestOnWorkspace(key) == nil

        // If the window is not over anything, assume that it attaches to its sibling.
        if attachTo == nil {
            if case .window(let l) = fork.left, case .window(let r)? = fork.right {
                attachTo = l == window ? r : l
            } else if !windowless {
                retile(fork)
                return
            }
        }

        if windowless {
            detachWindow(window)
            attachToMonitor(window, key: key)
        } else if let attachTo {
            place(window, onto: attachTo, cursor: cursor)
        } else {
            detachWindow(window)
            attachMonitor()
        }
    }

    /// Places a dropped window next to the window under the cursor.
    ///
    /// A drop on the center of a window swaps the two windows. A drop near an
    /// edge splits the window's tile on that side.
    public func place(_ window: WindowID, onto attachTo: WindowID, cursor: Point) {
        guard let fork = forest.attached[attachTo] else { return }

        if centerTile(of: attachTo, cursor: cursor) != nil {
            attachSwap(window, attachTo)
            return
        }

        let isSibling = windowsAreSiblings(window, attachTo) != nil
        guard let attachArea = isSibling ? fork.area : env.windowRect(attachTo) else { return }

        let (orientation, swapSides) = cursorPlacement(area: attachArea, cursor: cursor)
        let direction: Direction = orientation == .horizontal
            ? (swapSides ? .left : .right)
            : (swapSides ? .up : .down)

        /// Orders the window and its sibling in `fork` so the window is on the drop side.
        func arrange(_ fork: Fork) {
            fork.setOrientation(orientation)
            let isLeft = fork.left.isWindow(window)
            let shouldSwap = (isLeft && (direction == .right || direction == .down))
                || (!isLeft && (direction == .left || direction == .up))
            if shouldSwap { fork.swapBranches() }
            retile(fork)
        }

        if isSibling {
            arrange(fork)
        } else if fork.isToplevel && fork.right == nil {
            detachWindow(window)
            attachToWindow(attachTo, window, moveBy: .cursor(orientation: orientation, swap: swapSides))
            if let newFork = forest.attached[window] { arrange(newFork) }
        } else {
            detachWindow(window)
            attachToWindow(attachTo, window, moveBy: .cursor(orientation: orientation, swap: swapSides))
        }
    }

    // MARK: - Minimize

    /// Remembers where a window was so that it can return there.
    public struct Attachment {
        let fork: Fork
        let isLeft: Bool
    }

    /// The workspace that an attachment belongs to.
    public func workspace(of attachment: Attachment) -> WorkspaceKey {
        forest.toplevel(of: attachment.fork).workspace
    }

    public func attachment(of window: WindowID) -> Attachment? {
        guard let fork = forest.attached[window] else { return nil }
        return Attachment(fork: fork, isLeft: fork.left.isWindow(window))
    }

    /// Restores a window to where it was before it was minimized.
    ///
    /// Returns false if that place no longer exists.
    public func restore(_ window: WindowID, to attachment: Attachment) -> Bool {
        let fork = attachment.fork
        guard !fork.isDeleted else { return false }
        forest.attachFork(fork, window: window, isLeft: attachment.isLeft)
        unsmartGap(forest.toplevel(of: fork))
        retile(fork)
        return true
    }
}
