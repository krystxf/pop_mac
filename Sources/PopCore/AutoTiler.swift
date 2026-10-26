import Foundation

/// What the auto-tiler needs to know about the outside world.
public protocol TilingEnvironment: AnyObject {
    var gapOuter: Double { get }
    var smartGaps: Bool { get }
    /// Allows dropping a window onto the center of another to stack them.
    var stackingWithMouse: Bool { get }

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
    /// Called after a layout with every stack in the forest.
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
        forest.stackUpdates.removeAll()
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
        if fork.isToplevel && fork.smartGapped, let rect = outerArea(fork.workspace.monitor) {
            fork.smartGapped = false
            fork.area = rect
        }
    }

    // MARK: - Attaching

    /// Makes the window the only tile of a new tree on a display.
    public func attachToMonitor(_ window: WindowID, key: WorkspaceKey) {
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
    public func attachToWindow(_ onto: WindowID, _ window: WindowID, moveBy: MoveBy, stackFromLeft: Bool = true) -> Bool {
        guard let fork = forest.attachWindow(onto: onto, new: window, placeBy: moveBy, stackFromLeft: stackFromLeft) else {
            return false
        }
        if fork.right != nil { unsmartGap(fork) }
        tile(fork, area: fork.area)
        return true
    }

    /// Tiles a window onto the largest window of a workspace, or onto the display.
    public func attachToWorkspace(_ window: WindowID, key: WorkspaceKey) {
        if let top = forest.findToplevel(key),
           let onto = forest.largestWindow(in: top, rect: tilableRect),
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
        guard let reflow = forest.detach(fork, window: window) else {
            env.updateStacks(forest.allStacks())
            return
        }
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
        env.updateStacks([])
    }

    // MARK: - Queries

    public func windowsAreSiblings(_ a: WindowID, _ b: WindowID) -> Fork? {
        if let fa = forest.attached[a], let fb = forest.attached[b], fa === fb { return fa }
        return nil
    }

    /// Finds the stack that holds a window: its fork, the stack, and whether it is the left branch.
    public func findStack(_ window: WindowID) -> (fork: Fork, stack: StackNode, isLeft: Bool)? {
        guard let fork = forest.attached[window] else { return nil }
        if let s = fork.left.stack, s.contains(window) { return (fork, s, true) }
        if let s = fork.right?.stack, s.contains(window) { return (fork, s, false) }
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
            if let s = fork.left.stack, let i = s.entities.firstIndex(of: x) {
                return { s.entities[i] = y; if s.active == x { s.active = y }; self.forest.setAttached(y, fork) }
            }
            if let right = fork.right {
                if right.isWindow(x) { return { fork.right = .window(y) } }
                if let s = right.stack, let i = s.entities.firstIndex(of: x) {
                    return { s.entities[i] = y; if s.active == x { s.active = y }; self.forest.setAttached(y, fork) }
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

    // MARK: - Stacking

    /// Toggles stacking for the window's branch.
    public func toggleStacking(_ window: WindowID) {
        guard let fork = forest.attached[window] else { return }
        unstack(fork, window: window, toggled: true)
    }

    /// Turns a window into a stack, or a single-window stack back into a window.
    public func unstack(_ fork: Fork, window: WindowID, toggled: Bool) {
        if toggled && fork.left.isWindow(window) {
            fork.left = .stack(forest.createStack(window: window, workspace: fork.workspace))
        } else if let s = fork.left.stack, s.contains(window) {
            if s.entities.count == 1 {
                fork.left = .window(window)
                if fork.right == nil {
                    forest.reassignToParent(fork, fork.left)
                }
            }
        } else if toggled, let right = fork.right, right.isWindow(window) {
            fork.right = .stack(forest.createStack(window: window, workspace: fork.workspace))
        } else if let s = fork.right?.stack, s.contains(window) {
            if s.entities.count == 1 {
                fork.right = .window(window)
            }
        }

        reflow(window)
    }

    /// Converts a window into a stack, if it was not already stacked.
    public func createStack(_ window: WindowID) {
        guard let fork = forest.attached[window] else { return }
        if fork.left.isWindow(window) {
            fork.left = .stack(forest.createStack(window: window, workspace: fork.workspace))
        } else if let right = fork.right, right.isWindow(window) {
            fork.right = .stack(forest.createStack(window: window, workspace: fork.workspace))
        }
    }

    /// Splits a window out of a stack into a new fork beside the stack.
    @discardableResult
    private func unstackFromFork(_ fork: Fork, left: Node, right: Node, isLeft: Bool) -> Fork {
        let child = forest.createFork(left: left, right: right, area: fork.area, workspace: fork.workspace)
        if isLeft {
            fork.left = .fork(child)
        } else {
            fork.right = .fork(child)
        }
        return child
    }

    private func orientationAndReverse(_ direction: Direction) -> (Orientation, Bool) {
        switch direction {
        case .left: return (.horizontal, false)
        case .right: return (.horizontal, true)
        case .up: return (.vertical, false)
        case .down: return (.vertical, true)
        }
    }

    /// Moves a window within its stack, or out of the stack.
    public func moveFromStack(_ window: WindowID, direction: Direction, forceDetach: Bool = false) {
        guard let (fork, stack, isLeft) = findStack(window) else { return }

        if stack.entities.count == 1 {
            toggleStacking(window)
            return
        }

        unsmartGap(fork)

        func detach(_ orientation: Orientation, _ reverse: Bool) {
            let branch: Node = .stack(stack)
            var target = fork
            if fork.right != nil {
                let (l, r): (Node, Node) = reverse ? (branch, .window(window)) : (.window(window), branch)
                target = unstackFromFork(fork, left: l, right: r, isLeft: isLeft)
            } else if reverse {
                fork.right = .window(window)
            } else {
                fork.right = fork.left
                fork.left = .window(window)
            }
            target.setOrientation(orientation)
            retile(fork)
        }

        let (orientation, reverse) = orientationAndReverse(direction)
        let index = stack.entities.firstIndex(of: window) ?? 0

        switch direction {
        case .left, .right:
            let edge = direction == .left ? 0 : stack.entities.count - 1
            if !forceDetach && index != edge {
                // Move the tab within the stack.
                let other = direction == .left ? index - 1 : index + 1
                stack.entities.swapAt(index, other)
                stack.active = window
                retile(fork)
                return
            }
        case .up, .down:
            break
        }

        stack.entities.removeAll { $0 == window }
        stack.autoActivate()
        detach(orientation, reverse)
    }

    /// Places a window beside a stack, in the given direction.
    public func moveAlongsideStack(_ window: WindowID, stackMember: WindowID, direction: Direction) {
        detachWindow(window)
        guard let (fork, stack, isLeft) = findStack(stackMember) else { return }

        unsmartGap(fork)

        let (orientation, reverse) = orientationAndReverse(direction)
        let branch: Node = .stack(stack)
        var target = fork

        if fork.right != nil {
            let (l, r): (Node, Node) = reverse ? (branch, .window(window)) : (.window(window), branch)
            target = unstackFromFork(fork, left: l, right: r, isLeft: isLeft)
        } else if reverse {
            fork.right = .window(window)
        } else {
            fork.right = fork.left
            fork.left = .window(window)
        }

        target.setOrientation(orientation)
        retile(fork)
    }

    // MARK: - Keyboard movement

    /// Moves the focused window onto another window, or onto another display.
    public func moveAuto(_ focused: WindowID, to target: MoveTarget, stackFromLeft: Bool = true) {
        switch target {
        case .window(let moveTo):
            if findStack(moveTo) != nil {
                detachWindow(focused)
                attachToWindow(moveTo, focused, moveBy: .auto, stackFromLeft: stackFromLeft)
                return
            }

            if let parent = windowsAreSiblings(focused, moveTo), parent.right != nil {
                parent.swapBranches()
                retile(parent)
                return
            }

            guard let src = env.windowRect(focused) else { return }
            detachWindow(focused)
            if !attachToWindow(moveTo, focused, moveBy: .keyboard(src: src), stackFromLeft: false),
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
              var crect = env.windowRect(window)
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
    public func resizeByMouse(_ window: WindowID, from original: Rect, to crect: Rect) {
        guard let fork = forest.attached[window] else { return }
        var crect = crect
        if findStack(window) != nil {
            crect.y -= forest.tabHeight
            crect.height += forest.tabHeight
        }
        crect.clamp(forest.toplevel(of: fork).area)

        var original = original
        if findStack(window) != nil {
            original.y -= forest.tabHeight
            original.height += forest.tabHeight
        }

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

    /// Derives how a window attaches from the cursor position.
    ///
    /// Returns nil when the window should be stacked instead.
    public func cursorPlacement(area: Rect, cursor: Point) -> MoveBy? {
        let (_, side) = Geom.nearestSide(cursor, area, allowCenter: env.stackingWithMouse)
        switch side {
        case .left: return .cursor(orientation: .horizontal, swap: true)
        case .right: return .cursor(orientation: .horizontal, swap: false)
        case .top: return .cursor(orientation: .vertical, swap: true)
        case .bottom: return .cursor(orientation: .vertical, swap: false)
        case .center: return nil
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

    /// The area that the overlay shows while a window is dragged.
    public func dropPreview(_ window: WindowID, cursor: Point, key: WorkspaceKey) -> Rect? {
        guard let fork = forest.attached[window] else { return nil }

        if largestOnWorkspace(key) == nil {
            return outerArea(key.monitor)
        }

        guard let target = dropTarget(window, cursor: cursor, key: key) else { return nil }

        let isSibling = windowsAreSiblings(window, target) != nil
        let area: Rect
        if findStack(window) == nil && isSibling {
            area = fork.area
        } else if let r = env.windowRect(target) {
            area = r
        } else {
            return nil
        }

        guard case .cursor(let orientation, let swap)? = cursorPlacement(area: area, cursor: cursor) else {
            return area
        }

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
            placeOrStack(window, attachTo: attachTo, cursor: cursor)
        } else {
            detachWindow(window)
            attachMonitor()
        }
    }

    @discardableResult
    public func placeOrStack(_ window: WindowID, attachTo: WindowID, cursor: Point) -> Bool {
        guard let fork = forest.attached[attachTo] else { return true }

        let isSibling = windowsAreSiblings(window, attachTo) != nil
        let windowStack = findStack(window)?.stack
        let targetStack = findStack(attachTo)

        let attachArea: Rect
        if windowStack == nil && isSibling {
            attachArea = fork.area
        } else if let r = env.windowRect(attachTo) {
            attachArea = r
        } else {
            return true
        }

        var placement = cursorPlacement(area: attachArea, cursor: cursor)
        let matchingStack = windowStack != nil && windowStack === targetStack?.stack

        func swap(_ orientation: Orientation, _ direction: Direction) {
            fork.setOrientation(orientation)
            let isLeft = fork.left.isWindow(window)
            let shouldSwap = (isLeft && (direction == .right || direction == .down))
                || (!isLeft && (direction == .left || direction == .up))
            if shouldSwap { fork.swapBranches() }
            retile(fork)
        }

        if case .cursor(let orientation, let swapSides)? = placement {
            let direction: Direction = orientation == .horizontal
                ? (swapSides ? .left : .right)
                : (swapSides ? .up : .down)

            if targetStack != nil {
                if matchingStack {
                    moveFromStack(window, direction: direction, forceDetach: true)
                } else if isSibling && windowStack == nil {
                    swap(orientation, direction)
                } else {
                    moveAlongsideStack(window, stackMember: attachTo, direction: direction)
                }
                return true
            } else if isSibling && windowStack == nil {
                swap(orientation, direction)
                return true
            } else if fork.isToplevel && fork.right == nil {
                detachWindow(window)
                attachToWindow(attachTo, window, moveBy: placement!)
                if let newFork = forest.attached[window] {
                    newFork.setOrientation(orientation)
                    let isLeft = newFork.left.isWindow(window)
                    let shouldSwap = (isLeft && (direction == .right || direction == .down))
                        || (!isLeft && (direction == .left || direction == .up))
                    if shouldSwap { newFork.swapBranches() }
                    retile(newFork)
                }
                return true
            }
        } else if matchingStack {
            retile(fork)
            return true
        } else {
            if targetStack == nil { createStack(attachTo) }
            placement = .auto
        }

        detachWindow(window)
        return attachToWindow(attachTo, window, moveBy: placement ?? .auto)
    }

    // MARK: - Minimize

    /// Remembers where a window was so that it can return there.
    public enum Attachment {
        case branch(fork: Fork, isLeft: Bool)
        case stack(fork: Fork, stack: StackNode)
    }

    public func attachment(of window: WindowID) -> Attachment? {
        guard let fork = forest.attached[window] else { return nil }
        if let (f, s, _) = findStack(window) { return .stack(fork: f, stack: s) }
        return .branch(fork: fork, isLeft: fork.left.isWindow(window))
    }

    /// Restores a window to where it was before it was minimized.
    ///
    /// Returns false if that place no longer exists.
    public func restore(_ window: WindowID, to attachment: Attachment) -> Bool {
        switch attachment {
        case .branch(let fork, let isLeft):
            guard !fork.isDeleted else { return false }
            forest.attachFork(fork, window: window, isLeft: isLeft)
            retile(fork)
            return true
        case .stack(let fork, let stack):
            guard !fork.isDeleted, !stack.entities.isEmpty, let member = stack.entities.first,
                  let (f, _, _) = findStack(member)
            else { return false }
            forest.attachStack(stack, fork: f, window: window, stackFromLeft: true)
            retile(f)
            return true
        }
    }
}
