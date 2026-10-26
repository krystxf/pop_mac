import Foundation

/// Describes how a window should be placed when it attaches to a fork.
public enum MoveBy {
    /// Placement chosen by where the cursor is relative to the target.
    case cursor(orientation: Orientation, swap: Bool)
    /// Placement chosen by where the window was before the keyboard move.
    case keyboard(src: Rect)
    /// Default placement: the new window goes on the right branch.
    case auto
}

/// A collection of forks separated into trees.
///
/// Each display on each workspace has its own tree. A tree starts at a
/// top-level fork, and branches into nested sub-forks. Each fork holds two
/// nodes and an orientation. Forks are created and removed as windows attach
/// and detach.
public final class Forest {
    /// The top-level fork of each workspace on each display.
    public private(set) var toplevels: [WorkspaceKey: Fork] = [:]

    /// The fork that each tiled window is attached to.
    public private(set) var attached: [WindowID: Fork] = [:]

    /// Window positions that were calculated, but not yet applied.
    public var requested: [(WindowID, Rect)] = []

    /// The tile that each window was last measured into.
    public private(set) var tileRects: [WindowID: Rect] = [:]

    public var gapInner: Double = 8

    /// Set while the user resizes a window, so that forks remember their ratio.
    public var manuallyMoved = false

    /// Called when a window becomes attached to the tree.
    public var onAttach: ((WindowID) -> Void)?

    /// Called when a window is detached from the tree.
    public var onDetach: ((WindowID) -> Void)?

    /// The smallest size that a window accepts, if known.
    public var minimumSize: ((WindowID) -> Size?)?

    private var nextID = 1

    public init() {}

    // MARK: - Bookkeeping

    /// Records the fork as the owner of the node's contents.
    func adopt(_ node: Node, into fork: Fork) {
        switch node {
        case let .fork(child):
            child.parent = fork
        case let .window(window):
            setAttached(window, fork)
        }
    }

    func setAttached(_ window: WindowID, _ fork: Fork) {
        let isNew = attached[window] == nil
        attached[window] = fork
        if isNew { onAttach?(window) }
    }

    /// Removes the window's attachment record, and returns its previous fork.
    @discardableResult
    public func takeAttached(_ window: WindowID) -> Fork? {
        tileRects.removeValue(forKey: window)
        return attached.removeValue(forKey: window)
    }

    func record(_ window: WindowID, _ rect: Rect) {
        tileRects[window] = rect
        if let idx = requested.firstIndex(where: { $0.0 == window }) {
            requested[idx].1 = rect
        } else {
            requested.append((window, rect))
        }
    }

    private func newID() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    // MARK: - Fork creation

    @discardableResult
    public func createFork(left: Node, right: Node?, area: Rect, workspace: WorkspaceKey) -> Fork {
        let orientation: Orientation = area.width > area.height ? .horizontal : .vertical
        return Fork(id: newID(), forest: self, left: left, right: right, area: area, workspace: workspace, orientation: orientation)
    }

    public func createToplevel(window: WindowID, area: Rect, workspace: WorkspaceKey) -> Fork {
        let fork = createFork(left: .window(window), right: nil, area: area, workspace: workspace)
        fork.isToplevel = true
        toplevels[workspace] = fork
        return fork
    }

    func deleteFork(_ fork: Fork) {
        fork.isDeleted = true
        if fork.isToplevel, toplevels[fork.workspace] === fork {
            toplevels.removeValue(forKey: fork.workspace)
        }
    }

    public func findToplevel(_ key: WorkspaceKey) -> Fork? {
        toplevels[key]
    }

    /// The top-level fork that a fork belongs to.
    public func toplevel(of fork: Fork) -> Fork {
        var current = fork
        while let parent = current.parent { current = parent }
        return current
    }

    // MARK: - Traversal

    /// Walks the tree below a fork, and yields every node.
    public func iter(_ fork: Fork) -> [Node] {
        var nodes: [Node] = []
        var pending: [Fork] = [fork]
        while let current = pending.popLast() {
            if case let .fork(f) = current.left { pending.append(f) }
            nodes.append(current.left)
            if let right = current.right {
                if case let .fork(f) = right { pending.append(f) }
                nodes.append(right)
            }
        }
        return nodes
    }

    /// Every window in the tree below a fork.
    public func windows(in fork: Fork) -> [WindowID] {
        iter(fork).compactMap(\.windowID)
    }

    /// Finds the largest tilable window below a fork.
    public func largestWindow(in fork: Fork, rect: (WindowID) -> Rect?) -> WindowID? {
        var largest: WindowID?
        var largestSize = 0.0

        func compare(_ window: WindowID) {
            if let r = rect(window), r.area > largestSize {
                largestSize = r.area
                largest = window
            }
        }

        for window in windows(in: fork) {
            compare(window)
        }
        return largest
    }

    // MARK: - Measurement

    /// The smallest length that a node needs along one axis.
    ///
    /// Forks along the same axis add up their branches and the gap between them.
    /// Forks across the axis need as much as their larger branch.
    func minimumLength(of node: Node, horizontal: Bool) -> Double {
        switch node {
        case let .window(window):
            guard let size = minimumSize?(window) else { return 0 }
            return horizontal ? size.width : size.height
        case let .fork(fork):
            let left = minimumLength(of: fork.left, horizontal: horizontal)
            guard let right = fork.right else { return left }
            let rightLength = minimumLength(of: right, horizontal: horizontal)
            if fork.isHorizontal == horizontal {
                return left + rightLength + (left > 0 || rightLength > 0 ? gapInner : 0)
            }
            return max(left, rightLength)
        }
    }

    public func measure(_ fork: Fork, area: Rect) {
        fork.measure(self, area: area)
    }

    // MARK: - Attaching

    /// Attaches a window to a fork, on the left or the right branch.
    ///
    /// Used to restore a window to its previous place after it was minimized.
    public func attachFork(_ fork: Fork, window: WindowID, isLeft: Bool) {
        let node = Node.window(window)
        if isLeft {
            if let right = fork.right {
                let child = createFork(left: fork.left, right: right, area: fork.areaOfRight(), workspace: fork.workspace)
                fork.right = .fork(child)
            } else {
                fork.right = fork.left
            }
            fork.left = node
        } else {
            if let right = fork.right {
                let child = createFork(left: fork.left, right: right, area: fork.areaOfLeft(), workspace: fork.workspace)
                fork.left = .fork(child)
            }
            fork.right = node
        }
    }

    /// Attaches a new window to the fork that `onto` is attached to.
    ///
    /// Returns the fork that must be re-tiled.
    public func attachWindow(onto: WindowID, new: WindowID, placeBy: MoveBy) -> Fork? {
        guard let fork = attached[onto] else { return nil }

        func halves(_ fork: Fork) -> (Rect, Rect) {
            let a = fork.area
            return fork.isHorizontal
                ? (Rect(a.x, a.y, a.width / 2, a.height), Rect(a.x + a.width / 2, a.y, a.width / 2, a.height))
                : (Rect(a.x, a.y, a.width, a.height / 2), Rect(a.x, a.y + a.height / 2, a.width, a.height / 2))
        }

        // Place a window in a fork based on where the window was originally located.
        func placeByKeyboard(_ fork: Fork, _ src: Rect) {
            let (left, right) = halves(fork)
            let from = src.center
            if Geom.shortestSide(from, left) < Geom.shortestSide(from, right) {
                fork.swapBranches()
            }
        }

        func place(_ fork: Fork) {
            switch placeBy {
            case let .cursor(orientation, swap):
                fork.setOrientation(orientation)
                if swap { fork.swapBranches() }
            case let .keyboard(src):
                placeByKeyboard(fork, src)
            case .auto:
                break
            }
        }

        let rightNode = Node.window(new)

        if fork.left.isWindow(onto) {
            if fork.right != nil {
                let child = createFork(left: fork.left, right: rightNode, area: fork.areaOfLeft(), workspace: fork.workspace)
                fork.left = .fork(child)
                place(child)
            } else {
                fork.right = rightNode
                fork.setRatio(fork.length / 2)
                if case let .keyboard(src) = placeBy { placeByKeyboard(fork, src) }
            }
            return fork
        } else if let right = fork.right, right.isWindow(onto) {
            let child = createFork(left: right, right: rightNode, area: fork.areaOfRight(), workspace: fork.workspace)
            fork.right = .fork(child)
            place(child)
            return fork
        }

        return nil
    }

    // MARK: - Detaching

    /// Detaches a window from a fork, and re-arranges the tree as necessary.
    ///
    /// Returns the fork that must be re-tiled.
    public func detach(_ fork: Fork, window: WindowID) -> Fork? {
        var reflow: Fork?
        let parent = fork.parent

        if fork.left.isWindow(window) {
            if let parent, let right = fork.right {
                reflow = reassignChildToParent(child: fork, parent: parent, branch: right)
            } else if let right = fork.right {
                reflow = fork
                if case let .fork(child) = right {
                    reassignChildrenToParent(fork, child: child)
                } else {
                    fork.left = right
                    fork.right = nil
                }
            } else {
                deleteFork(fork)
            }
        } else if let right = fork.right, right.isWindow(window) {
            if let parent {
                reflow = reassignChildToParent(child: fork, parent: parent, branch: fork.left)
            } else {
                reflow = fork
                if case let .fork(child) = fork.left {
                    reassignChildrenToParent(fork, child: child)
                } else {
                    fork.right = nil
                }
            }
        }

        onDetach?(window)
        reflow?.rebalanceOrientation()

        return reflow
    }

    /// Replaces the child fork in its parent with `branch`.
    private func reassignChildToParent(child: Fork, parent: Fork, branch: Node) -> Fork {
        if parent.left.isFork(child) {
            parent.left = branch
        } else {
            parent.right = branch
        }
        deleteFork(child)
        return parent
    }

    /// Moves the children of `child` into `fork`.
    private func reassignChildrenToParent(_ fork: Fork, child: Fork) {
        fork.left = child.left
        fork.right = child.right
        deleteFork(child)
    }

    // MARK: - Debugging

    public func debugDescription(rect: (WindowID) -> Rect?) -> String {
        var out = ""
        for (key, fork) in toplevels {
            out += "Workspace \(key):\n" + describe(fork, scope: 1, rect: rect) + "\n"
        }
        return out
    }

    private func describe(_ fork: Fork, scope: Int, rect: (WindowID) -> Rect?) -> String {
        let pad = String(repeating: "  ", count: scope)
        var out = "Fork(\(fork.id)) \(fork.orientation) \(fork.area) {\n"
        out += pad + "  left: " + describe(fork.left, scope: scope + 1, rect: rect) + "\n"
        if let right = fork.right {
            out += pad + "  right: " + describe(right, scope: scope + 1, rect: rect) + "\n"
        }
        return out + pad + "}"
    }

    private func describe(_ node: Node, scope: Int, rect: (WindowID) -> Rect?) -> String {
        switch node {
        case let .fork(f): describe(f, scope: scope, rect: rect)
        case let .window(w): "Window(\(w)) \(rect(w).map { "\($0)" } ?? "?")"
        }
    }
}
