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
    /// The smallest size that a window accepts, if known.
    func minimumSize(_ window: WindowID) -> Size?
    /// Called after the stacks changed, with every stack in the forest.
    func updateStacks(_ stacks: [StackNode])
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
        forest.minimumSize = { [unowned env] in env.minimumSize($0) }
    }

    public var attached: [WindowID: Fork] { forest.attached }

    /// While true, calculated positions wait in `forest.requested`.
    private var isBatching = false

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

    /// Runs `body`, then applies every calculated position at once, so each window moves only once.
    public func batch(_ body: () -> Void) {
        let outer = isBatching
        isBatching = true
        body()
        isBatching = outer
        arrange()
    }

    /// Applies every calculated position.
    public func arrange() {
        guard !isBatching else { return }
        let moves = forest.requested
        forest.requested.removeAll()
        env.applyLayout(moves)
        env.updateStacks(forest.allStacks())
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
        if fork.isToplevel, fork.smartGapped, let rect = outerArea(fork.workspace.monitor) {
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
           attachToWindow(onto, window, moveBy: .auto)
        {
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

    /// Tiles a window into another window's place, or into its stack.
    @discardableResult
    public func attachToWindow(_ onto: WindowID, _ window: WindowID, moveBy: MoveBy, stackAtEnd: Bool = true) -> Bool {
        guard let fork = forest.attachWindow(onto: onto, new: window, placeBy: moveBy, stackAtEnd: stackAtEnd) else {
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
           attachToWindow(onto, window, moveBy: .auto)
        {
            return
        }
        attachToMonitor(window, key: key)
    }

    /// The window's tile, or its frame if it has no tile yet.
    ///
    /// The tile is current during a batch, when windows have not moved yet.
    private func tilableRect(_ window: WindowID) -> Rect? {
        env.isTilable(window) ? forest.tileRects[window] ?? env.windowRect(window) : nil
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
        guard let reflow = forest.detach(fork, window: window) else {
            env.updateStacks(forest.allStacks())
            return
        }
        if reflow.isToplevel, env.smartGaps, reflow.right == nil, let rect = env.workArea(reflow.workspace.monitor) {
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
        env.updateStacks([])
    }

    // MARK: - Queries

    public func windowsAreSiblings(_ a: WindowID, _ b: WindowID) -> Fork? {
        if let fa = forest.attached[a], let fb = forest.attached[b], fa === fb { return fa }
        return nil
    }

    /// The stack that holds a window, with the stack's fork.
    public func findStack(_ window: WindowID) -> (fork: Fork, stack: StackNode)? {
        guard let fork = forest.attached[window], let stack = fork.stack(holding: window) else { return nil }
        return (fork, stack)
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
            if case let .fork(child) = node {
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
            if let stack = fork.stack(holding: x), let index = stack.entities.firstIndex(of: x) {
                let wasActive = stack.active == x
                return {
                    stack.entities[index] = y
                    if wasActive { stack.active = y }
                    self.forest.setAttached(y, fork)
                }
            }
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
        } else if let stack = fork.stack(holding: old), let index = stack.entities.firstIndex(of: old) {
            stack.entities[index] = new
            if stack.active == old { stack.active = new }
            forest.setAttached(new, fork)
        } else {
            forest.setAttached(old, fork)
            return false
        }
        retile(fork)
        return true
    }

    // MARK: - Stacking

    /// Turns a window into a stack of one, or splits its stack back into tiles.
    ///
    /// The windows of a split stack share the stack's place.
    public func toggleStacking(_ window: WindowID) {
        guard let fork = forest.attached[window] else { return }
        if let stack = fork.stack(holding: window) {
            let windows = stack.entities
            let first = Node.window(windows[0])
            if fork.left.stack === stack { fork.left = first } else { fork.right = first }
            for (previous, next) in zip(windows, windows.dropFirst()) {
                _ = forest.attachWindow(onto: previous, new: next, placeBy: .auto)
            }
        } else {
            makeStack(window)
        }
        retile(fork)
    }

    /// Turns the window's branch into a stack of one, unless the window is stacked already.
    @discardableResult
    private func makeStack(_ window: WindowID) -> StackNode? {
        guard let fork = forest.attached[window] else { return nil }
        if let stack = fork.stack(holding: window) { return stack }
        let stack = forest.createStack(window: window)
        if fork.left.isWindow(window) {
            fork.left = .stack(stack)
        } else if let right = fork.right, right.isWindow(window) {
            fork.right = .stack(stack)
        } else {
            return nil
        }
        return stack
    }

    /// Stacks a window onto another window: into its stack, or into a new stack with it.
    public func stack(_ window: WindowID, onto target: WindowID) {
        guard window != target, isAttached(target) else { return }
        if let stack = findStack(window)?.stack, stack.contains(target) {
            reflow(target)
            return
        }
        batch {
            makeStack(target)
            detachWindow(window)
            attachToWindow(target, window, moveBy: .auto)
        }
    }

    /// Moves a window within its stack, or out of the stack.
    ///
    /// Left and right move the window's tab, until it reaches the end of the
    /// stack. Then, or with up and down, the window leaves the stack and
    /// takes a tile beside it in that direction.
    public func moveFromStack(_ window: WindowID, direction: Direction, forceDetach: Bool = false) {
        guard let (fork, stack) = findStack(window) else { return }

        if stack.entities.count == 1 {
            toggleStacking(window)
            return
        }

        if !forceDetach, direction == .left || direction == .right, let index = stack.entities.firstIndex(of: window) {
            let other = direction == .left ? index - 1 : index + 1
            if stack.entities.indices.contains(other) {
                stack.entities.swapAt(index, other)
                stack.active = window
                env.updateStacks(forest.allStacks())
                return
            }
        }

        stack.entities.removeAll { $0 == window }
        stack.autoActivate()
        place(window, beside: stack, in: fork, direction: direction)
    }

    /// Moves a window's tab to another position in its stack, and selects it.
    public func moveInStack(_ window: WindowID, to index: Int) {
        guard let stack = findStack(window)?.stack, let from = stack.entities.firstIndex(of: window) else { return }
        stack.entities.remove(at: from)
        stack.entities.insert(window, at: min(max(index, 0), stack.entities.count))
        stack.active = window
        env.updateStacks(forest.allStacks())
    }

    /// Moves a window out of its place, and into a tile beside a stack.
    public func move(_ window: WindowID, besideStackOf member: WindowID, direction: Direction) {
        batch {
            detachWindow(window)
            guard let (fork, stack) = findStack(member) else { return }
            place(window, beside: stack, in: fork, direction: direction)
        }
    }

    /// Splits the stack's place between the stack and the window, with the window on the `direction` side.
    ///
    /// A stack with a single window left becomes a plain window.
    private func place(_ window: WindowID, beside stack: StackNode, in fork: Fork, direction: Direction) {
        unsmartGap(fork)
        let orientation: Orientation = direction == .left || direction == .right ? .horizontal : .vertical
        let windowFirst = direction == .left || direction == .up
        let rest: Node = stack.entities.count == 1 ? .window(stack.entities[0]) : .stack(stack)
        let (left, right): (Node, Node) = windowFirst ? (.window(window), rest) : (rest, .window(window))

        if fork.right != nil {
            let isLeft = fork.left.stack === stack
            let area = isLeft ? fork.areaOfLeft() : fork.areaOfRight()
            let child = forest.createFork(left: left, right: right, area: area, workspace: fork.workspace)
            if isLeft { fork.left = .fork(child) } else { fork.right = .fork(child) }
            child.setOrientation(orientation)
        } else {
            fork.left = left
            fork.right = right
            fork.setRatio(fork.length / 2)
            fork.setOrientation(orientation)
        }
        retile(fork)
    }

    // MARK: - Keyboard movement

    /// Moves the focused window onto another window, or onto another display.
    ///
    /// A window that moves onto a stacked window joins the stack, at the end it came from.
    public func moveAuto(_ focused: WindowID, to target: MoveTarget, stackAtEnd: Bool = true) {
        switch target {
        case let .window(moveTo):
            if findStack(moveTo) != nil {
                batch {
                    detachWindow(focused)
                    attachToWindow(moveTo, focused, moveBy: .auto, stackAtEnd: stackAtEnd)
                }
                return
            }

            if let parent = windowsAreSiblings(focused, moveTo), parent.right != nil {
                parent.swapBranches()
                retile(parent)
                return
            }

            guard let src = env.windowRect(focused) else { return }
            detachWindow(focused)
            if !attachToWindow(moveTo, focused, moveBy: .keyboard(src: src)),
               let key = env.workspaceKey(of: moveTo)
            {
                attachToWorkspace(focused, key: key)
            }

        case let .workspace(key):
            detachWindow(focused)
            attachToWorkspace(focused, key: key)
        }
    }

    /// An edge of a window's tile.
    public enum Edge: CaseIterable {
        case left, right, top, bottom
    }

    /// Finds the fork whose split lies along an edge of the window's tile.
    ///
    /// Walks up from the window. A right edge belongs to the first horizontal
    /// fork that holds the window in its left branch, and so on.
    public func splitFork(of window: WindowID, edge: Edge) -> Fork? {
        guard var current = forest.attached[window] else { return nil }
        var inLeft = current.left.holds(window)
        while true {
            switch edge {
            case .right where current.isHorizontal && inLeft,
                 .left where current.isHorizontal && !inLeft,
                 .bottom where !current.isHorizontal && inLeft,
                 .top where !current.isHorizontal && !inLeft:
                return current.right == nil ? nil : current
            default:
                break
            }
            guard let parent = current.parent else { return nil }
            inLeft = parent.left.isFork(current)
            current = parent
        }
    }

    /// Moves the splits next to a window, so that its tile becomes `target` where the tree allows.
    ///
    /// Each edge moves independently: dragging a corner moves two splits.
    /// Returns false if no split moved.
    @discardableResult
    public func resizeTile(_ window: WindowID, to target: Rect) -> Bool {
        guard let fork = forest.attached[window], var tile = forest.tileRects[window] else { return false }
        var target = target
        if findStack(window) != nil {
            // A stack's place starts at its tab bar.
            tile.y -= forest.tabHeight
            tile.height += forest.tabHeight
            target.y -= forest.tabHeight
            target.height += forest.tabHeight
        }
        let top = forest.toplevel(of: fork)
        let half = forest.gapInner / 2

        forest.manuallyMoved = true
        defer { forest.manuallyMoved = false }

        let edges: [(Edge, Double, Double)] = [
            (.left, tile.x, target.x), (.right, tile.maxX, target.maxX),
            (.top, tile.y, target.y), (.bottom, tile.maxY, target.maxY),
        ]

        var changed = false
        for (edge, old, new) in edges where abs(new - old) >= 1 {
            guard let split = splitFork(of: window, edge: edge) else { continue }
            // The window sits half a gap away from the split line.
            let line: Double = switch edge {
            case .left: new - half - split.area.x
            case .right: new + half - split.area.x
            case .top: new - half - split.area.y
            case .bottom: new + half - split.area.y
            }
            split.setRatio(line)
            // Update the areas of nested forks before the next edge.
            forest.measure(top, area: top.area)
            changed = true
        }

        if changed {
            forest.measure(top, area: top.area)
            arrange()
        }
        return changed
    }

    /// Grows or shrinks a tiled window by one step with the keyboard.
    ///
    /// Right and down grow the window, left and up shrink it. The edge next
    /// to a neighbor moves; a window at the screen edge moves its other edge.
    public func resizeAuto(_ window: WindowID, direction: Direction, step: Double = 64) {
        guard var target = forest.tileRects[window] else { return }

        let horizontal = direction == .left || direction == .right
        let grow = direction == .right || direction == .down
        let delta = grow ? step : -step

        if horizontal {
            if splitFork(of: window, edge: .right) != nil {
                target.width += delta
            } else if splitFork(of: window, edge: .left) != nil {
                target.x -= delta
                target.width += delta
            }
        } else {
            if splitFork(of: window, edge: .bottom) != nil {
                target.height += delta
            } else if splitFork(of: window, edge: .top) != nil {
                target.y -= delta
                target.height += delta
            }
        }

        resizeTile(window, to: target)
    }

    /// Applies a resize that the user made with the mouse.
    ///
    /// The tile's edges move by as much as the window's edges moved. The tile
    /// can be larger than the window, for example with a maximum width.
    public func resizeByMouse(_ window: WindowID, from frame: Rect, to newFrame: Rect) {
        guard let fork = forest.attached[window] else { return }
        let tile = forest.tileRects[window] ?? frame
        let x = tile.x + (newFrame.x - frame.x)
        let y = tile.y + (newFrame.y - frame.y)
        let maxX = tile.maxX + (newFrame.maxX - frame.maxX)
        let maxY = tile.maxY + (newFrame.maxY - frame.maxY)

        if !resizeTile(window, to: Rect(x, y, maxX - x, maxY - y)) {
            // Nothing could move, for example at the screen edge: snap back.
            retile(fork)
        }
    }

    // MARK: - Mouse drops

    /// Derives how a window attaches from the side of `area` nearest to the cursor.
    public func cursorPlacement(area: Rect, cursor: Point) -> (orientation: Orientation, swap: Bool) {
        switch Geom.nearestSide(cursor, area, allowCenter: false).1 {
        case .left: (.horizontal, true)
        case .top: (.vertical, true)
        case .bottom: (.vertical, false)
        case .right, .center: (.horizontal, false)
        }
    }

    /// The window that a dragged window would attach to if dropped at the cursor.
    public func dropTarget(_ window: WindowID, cursor: Point, key: WorkspaceKey) -> WindowID? {
        if let found = env.windows(at: cursor, key: key).first(where: { $0 != window && isAttached($0) }) {
            return found
        }
        guard let fork = forest.attached[window] else { return nil }
        if case let .window(l) = fork.left, case let .window(r)? = fork.right {
            return l == window ? r : l
        }
        return nil
    }

    /// The target's place, if the cursor is in the center zone of it.
    ///
    /// A stacked target's place includes its tab bar.
    private func centerTile(of target: WindowID, cursor: Point) -> Rect? {
        guard var tile = forest.tileRects[target] ?? env.windowRect(target) else { return nil }
        if findStack(target) != nil {
            tile.y -= forest.tabHeight
            tile.height += forest.tabHeight
        }
        guard tile.contains(cursor), Geom.nearestSide(cursor, tile, allowCenter: true).1 == .center else { return nil }
        return tile
    }

    /// What the overlay shows while a window is dragged.
    public struct DropPreview: Equatable {
        /// What a drop does with the dragged window and the target.
        public enum Action: Equatable {
            /// Splits a tile, fills the display, or puts the window back.
            case move
            /// Switches the places of the dragged window and the target.
            case swap
            /// Stacks the dragged window onto the target.
            case stack
        }

        public let area: Rect
        public let action: Action

        public init(area: Rect, action: Action = .move) {
            self.area = area
            self.action = action
        }
    }

    /// The area that the overlay shows while a window is dragged.
    ///
    /// - Parameter stack: True if a drop on a window's center stacks instead of swaps.
    public func dropPreview(_ window: WindowID, cursor: Point, key: WorkspaceKey, stack: Bool = false) -> DropPreview? {
        guard let fork = forest.attached[window] else { return nil }

        if largestOnWorkspace(key) == nil {
            return outerArea(key.monitor).map { DropPreview(area: $0) }
        }

        guard let target = dropTarget(window, cursor: cursor, key: key) else { return nil }

        // A drop on the center swaps or stacks, so show the target's place.
        if let tile = centerTile(of: target, cursor: cursor) {
            // A drop back on the window's own stack only puts it back.
            let sameStack = findStack(window).map { $0.stack.contains(target) } ?? false
            return DropPreview(area: tile, action: sameStack ? .move : stack ? .stack : .swap)
        }

        let area: Rect
        if findStack(window) == nil, windowsAreSiblings(window, target) != nil {
            area = fork.area
        } else if let r = env.windowRect(target) {
            area = r
        } else {
            return nil
        }

        let (orientation, swap) = cursorPlacement(area: area, cursor: cursor)
        let hw = area.width / 2, hh = area.height / 2
        let half = switch (orientation, swap) {
        case (.horizontal, true): Rect(area.x, area.y, hw, area.height)
        case (.horizontal, false): Rect(area.x + hw, area.y, hw, area.height)
        case (.vertical, true): Rect(area.x, area.y, area.width, hh)
        case (.vertical, false): Rect(area.x, area.y + hh, area.width, hh)
        }
        return DropPreview(area: half)
    }

    /// Handles a tiled window that the user dropped with the mouse.
    ///
    /// - If the window is dropped onto a window, tile onto it.
    /// - If no window is present, tile onto the display.
    /// - Parameter stack: True if a drop on a window's center stacks instead of swaps.
    public func onDrop(_ window: WindowID, cursor: Point, key: WorkspaceKey, viaOverview: Bool = false, stack: Bool = false) {
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
            if case let .window(l) = fork.left, case let .window(r)? = fork.right {
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
            place(window, onto: attachTo, cursor: cursor, stack: stack)
        } else {
            detachWindow(window)
            attachMonitor()
        }
    }

    /// Places a dropped window next to the window under the cursor.
    ///
    /// A drop on the center of a window swaps the two windows, or stacks them
    /// if `stack` is true. A drop near an edge splits the window's tile on that side.
    public func place(_ window: WindowID, onto attachTo: WindowID, cursor: Point, stack: Bool = false) {
        guard let fork = forest.attached[attachTo] else { return }

        let windowStack = findStack(window)?.stack
        let targetStack = findStack(attachTo)?.stack
        let sameStack = windowStack != nil && windowStack === targetStack

        if centerTile(of: attachTo, cursor: cursor) != nil {
            if sameStack {
                retile(fork)
            } else if stack {
                self.stack(window, onto: attachTo)
            } else {
                attachSwap(window, attachTo)
            }
            return
        }

        let isSibling = windowStack == nil && windowsAreSiblings(window, attachTo) != nil
        guard let attachArea = isSibling ? fork.area : env.windowRect(attachTo) else { return }

        let (orientation, swapSides) = cursorPlacement(area: attachArea, cursor: cursor)
        let direction: Direction = orientation == .horizontal
            ? (swapSides ? .left : .right)
            : (swapSides ? .up : .down)

        // Orders the window and its sibling in `fork` so the window is on the drop side.
        func arrange(_ fork: Fork) {
            fork.setOrientation(orientation)
            let isLeft = fork.left.isWindow(window)
            let shouldSwap = (isLeft && (direction == .right || direction == .down))
                || (!isLeft && (direction == .left || direction == .up))
            if shouldSwap { fork.swapBranches() }
            retile(fork)
        }

        if targetStack != nil {
            if sameStack {
                moveFromStack(window, direction: direction, forceDetach: true)
            } else if isSibling {
                arrange(fork)
            } else {
                move(window, besideStackOf: attachTo, direction: direction)
            }
        } else if isSibling {
            arrange(fork)
        } else if fork.isToplevel, fork.right == nil {
            detachWindow(window)
            attachToWindow(attachTo, window, moveBy: .cursor(orientation: orientation, swap: swapSides))
            if let newFork = forest.attached[window] { arrange(newFork) }
        } else {
            detachWindow(window)
            attachToWindow(attachTo, window, moveBy: .cursor(orientation: orientation, swap: swapSides))
        }
    }

    // MARK: - Moving stacks

    /// The window under the cursor that a dragged stack would land on.
    private func dropTarget(of stack: StackNode, cursor: Point, key: WorkspaceKey) -> WindowID? {
        env.windows(at: cursor, key: key).first { !stack.contains($0) && isAttached($0) }
    }

    /// The area that the overlay shows while a stack is dragged by its tab bar.
    ///
    /// - Parameter merge: True if a drop on a window's center merges instead of swaps.
    public func dropPreview(of stack: StackNode, cursor: Point, key: WorkspaceKey, merge: Bool = false) -> DropPreview? {
        guard let fork = forest.attached[stack.active] else { return nil }
        if largestOnWorkspace(key) == nil {
            return outerArea(key.monitor).map { DropPreview(area: $0) }
        }
        guard let target = dropTarget(of: stack, cursor: cursor, key: key) else { return nil }
        if let tile = centerTile(of: target, cursor: cursor) {
            return DropPreview(area: tile, action: merge ? .stack : .swap)
        }
        guard let area = forest.attached[target] === fork ? fork.area : env.windowRect(target) else { return nil }
        let (orientation, swap) = cursorPlacement(area: area, cursor: cursor)
        let hw = area.width / 2, hh = area.height / 2
        let half = switch (orientation, swap) {
        case (.horizontal, true): Rect(area.x, area.y, hw, area.height)
        case (.horizontal, false): Rect(area.x + hw, area.y, hw, area.height)
        case (.vertical, true): Rect(area.x, area.y, area.width, hh)
        case (.vertical, false): Rect(area.x, area.y + hh, area.width, hh)
        }
        return DropPreview(area: half)
    }

    /// Moves a whole stack that the user dropped with the mouse.
    ///
    /// - On an edge of a window, the stack splits that window's tile.
    /// - On the center of a window, the stack swaps places with the window, or
    ///   with the window's stack. With `merge`, the stacks become one stack.
    /// - On a display without windows, the stack fills the display.
    public func onDrop(_ stack: StackNode, cursor: Point, key: WorkspaceKey, merge: Bool) {
        guard let fork = forest.attached[stack.active], fork.stack(holding: stack.active) === stack else { return }
        let windows = stack.entities, active = stack.active

        if largestOnWorkspace(key) == nil {
            batch {
                for window in windows { detachWindow(window) }
                attachToMonitor(active, key: key)
                restack(windows, active: active)
            }
            return
        }

        guard let target = dropTarget(of: stack, cursor: cursor, key: key) else {
            retile(fork)
            return
        }

        if centerTile(of: target, cursor: cursor) != nil {
            if merge {
                batch {
                    makeStack(target)
                    for window in windows { detachWindow(window) }
                    guard let (targetFork, targetStack) = findStack(target) else { return }
                    for window in windows {
                        forest.attachStack(targetStack, fork: targetFork, window: window, atEnd: true)
                    }
                    targetStack.active = active
                    retile(targetFork)
                }
            } else {
                swap(stack, with: target)
            }
            return
        }

        // The selected window carries the move alone, and the others stack onto it again.
        batch {
            for window in windows where window != active { detachWindow(window) }
            place(active, onto: target, cursor: cursor)
            restack(windows, active: active)
        }
    }

    /// Stacks windows onto `active` again, in their old order, after they moved as one.
    private func restack(_ windows: [WindowID], active: WindowID) {
        guard let stack = makeStack(active), let fork = forest.attached[active] else { return }
        for window in windows where window != active {
            forest.attachStack(stack, fork: fork, window: window, atEnd: true)
        }
        stack.entities = windows
        stack.active = active
        retile(fork)
    }

    /// Swaps a stack with a window, or with the stack that holds the window.
    private func swap(_ stack: StackNode, with target: WindowID) {
        guard let stackFork = forest.attached[stack.active], let targetFork = forest.attached[target] else { return }
        if stackFork === targetFork {
            stackFork.swapBranches()
            retile(stackFork)
            return
        }

        let targetNode = targetFork.stack(holding: target).map(Node.stack) ?? .window(target)
        let stackIsLeft = stackFork.left.stack === stack
        let targetIsLeft = targetFork.left.holds(target)
        if stackIsLeft { stackFork.left = targetNode } else { stackFork.right = targetNode }
        if targetIsLeft { targetFork.left = .stack(stack) } else { targetFork.right = .stack(stack) }

        retile(stackFork)
        if forest.toplevel(of: stackFork) !== forest.toplevel(of: targetFork) {
            retile(targetFork)
        }
    }

    // MARK: - Saved layouts

    /// Rebuilds a saved tree with the windows that `keep` accepts, and moves them into place.
    ///
    /// Returns false if nothing was rebuilt.
    @discardableResult
    public func restore(_ tree: SavedTree, keep: (WindowID) -> Bool) -> Bool {
        guard let work = env.workArea(tree.monitor),
              let root = forest.rebuild(tree, area: work.inset(by: env.gapOuter), keep: keep)
        else { return false }
        if env.smartGaps, root.right == nil {
            root.area = work
            root.smartGapped = true
        }
        tile(root, area: root.area)
        return true
    }

    // MARK: - Minimize

    /// Remembers where a window was so that it can return there.
    public enum Attachment {
        case branch(fork: Fork, isLeft: Bool)
        case stack(fork: Fork, stack: StackNode)
    }

    /// The workspace that an attachment belongs to.
    public func workspace(of attachment: Attachment) -> WorkspaceKey {
        switch attachment {
        case let .branch(fork, _), let .stack(fork, _): forest.toplevel(of: fork).workspace
        }
    }

    public func attachment(of window: WindowID) -> Attachment? {
        guard let fork = forest.attached[window] else { return nil }
        // A stack of one leaves the tree with the window.
        if let stack = fork.stack(holding: window), stack.entities.count > 1 {
            return .stack(fork: fork, stack: stack)
        }
        return .branch(fork: fork, isLeft: fork.left.holds(window))
    }

    /// Restores a window to where it was before it was minimized.
    ///
    /// Returns false if that place no longer exists.
    public func restore(_ window: WindowID, to attachment: Attachment) -> Bool {
        switch attachment {
        case let .branch(fork, isLeft):
            guard !fork.isDeleted else { return false }
            forest.attachFork(fork, window: window, isLeft: isLeft)
            unsmartGap(forest.toplevel(of: fork))
            retile(fork)
            return true
        case let .stack(_, stack):
            // The stack may have moved to another fork since.
            guard let member = stack.entities.first, let fork = forest.attached[member], !fork.isDeleted else { return false }
            if let current = fork.stack(holding: member) {
                guard current === stack else { return false }
            } else {
                // The stack became a plain window when this window left it. Stack them again.
                guard stack.entities == [member] else { return false }
                if fork.left.isWindow(member) { fork.left = .stack(stack) } else { fork.right = .stack(stack) }
            }
            forest.attachStack(stack, fork: fork, window: window, atEnd: true)
            retile(fork)
            return true
        }
    }
}
