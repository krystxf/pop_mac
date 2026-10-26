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

    private var nextID = 1

    public init() {}

    // MARK: - Bookkeeping

    /// Records the fork as the owner of the node's contents.
    func adopt(_ node: Node, into fork: Fork) {
        switch node {
        case .fork(let child):
            child.parent = fork
        case .window(let window):
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

    /// Moves a top-level fork to another workspace key.
    public func rekeyToplevel(_ fork: Fork, to key: WorkspaceKey) {
        guard fork.isToplevel else { return }
        if toplevels[fork.workspace] === fork {
            toplevels.removeValue(forKey: fork.workspace)
        }
        fork.workspace = key
        for node in iter(fork) {
            if case .fork(let f) = node { f.workspace = key }
        }
        toplevels[key] = fork
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
            if case .fork(let f) = current.left { pending.append(f) }
            nodes.append(current.left)
            if let right = current.right {
                if case .fork(let f) = right { pending.append(f) }
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
            case .cursor(let orientation, let swap):
                fork.setOrientation(orientation)
                if swap { fork.swapBranches() }
            case .keyboard(let src):
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
                if case .keyboard(let src) = placeBy { placeByKeyboard(fork, src) }
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
                if case .fork(let child) = right {
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
                if case .fork(let child) = fork.left {
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

    /// Replaces a fork with one of its branches in the fork's parent.
    public func reassignToParent(_ child: Fork, _ node: Node) {
        guard let parent = child.parent else { return }
        if parent.left.isFork(child) {
            parent.left = node
        } else {
            parent.right = node
        }
        deleteFork(child)
    }

    // MARK: - Resizing

    /// Resizes a window's fork, so that the window takes the area `crect`.
    public func resize(fork: Fork, window: WindowID, movement: Movement, crect: Rect) {
        let isLeft = fork.left.isWindow(window)
        if movement.contains(.shrink) {
            shrinkSibling(fork, isLeft: isLeft, movement: movement, crect: crect)
        } else {
            growSibling(fork, isLeft: isLeft, movement: movement, crect: crect)
        }
    }

    private func growSibling(_ fork: Fork, isLeft: Bool, movement: Movement, crect: Rect) {
        let resizeFork = { self.resizeFork(fork, crect: crect, movement: movement, shrunk: false) }

        if fork.isHorizontal {
            if !movement.isDisjoint(with: [.down, .up]) {
                resizeFork()
            } else if isLeft {
                if movement.contains(.right) {
                    readjustByLeft(fork, crect.width)
                } else {
                    resizeFork()
                }
            } else if movement.contains(.right) {
                resizeFork()
            } else {
                readjustByRight(fork, crect.width)
            }
        } else {
            if !movement.isDisjoint(with: [.left, .right]) {
                resizeFork()
            } else if isLeft {
                if movement.contains(.down) {
                    readjustByLeft(fork, crect.height)
                } else {
                    resizeFork()
                }
            } else if movement.contains(.down) {
                resizeFork()
            } else {
                readjustByRight(fork, crect.height)
            }
        }
    }

    private func shrinkSibling(_ fork: Fork, isLeft: Bool, movement: Movement, crect: Rect) {
        let resizeFork = { self.resizeFork(fork, crect: crect, movement: movement, shrunk: true) }

        if fork.isHorizontal {
            if !movement.isDisjoint(with: [.down, .up]) {
                resizeFork()
            } else if isLeft {
                if movement.contains(.left) {
                    readjustByLeft(fork, crect.width)
                } else {
                    resizeFork()
                }
            } else if movement.contains(.left) {
                resizeFork()
            } else {
                readjustByRight(fork, crect.width)
            }
        } else {
            if !movement.isDisjoint(with: [.left, .right]) {
                resizeFork()
            } else if isLeft {
                if movement.contains(.up) {
                    readjustByLeft(fork, crect.height)
                } else {
                    resizeFork()
                }
            } else if movement.contains(.up) {
                resizeFork()
            } else {
                readjustByRight(fork, crect.height)
            }
        }
    }

    /// Readjusts the division of space between the siblings of a fork.
    private func readjustByLeft(_ fork: Fork, _ leftLength: Double) {
        fork.setRatio(leftLength)
        fork.measure(self, area: fork.area)
    }

    /// Readjusts the division of space, based on the new length of the right sibling.
    private func readjustByRight(_ fork: Fork, _ rightLength: Double) {
        readjustByLeft(fork, fork.length - rightLength)
    }

    /// Walks up the tree to find the fork whose split lies in the direction
    /// of the movement, and moves that split.
    private func resizeFork(_ start: Fork, crect: Rect, movement mov: Movement, shrunk: Bool) {
        guard var parent = start.parent else {
            start.measure(self, area: start.area)
            return
        }

        let source = start
        var childFork = start
        var current = start
        var isLeft = false

        while true {
            current = parent
            isLeft = current.left.isFork(childFork)

            if current.area.contains(crect) {
                if mov.contains(.up) {
                    if shrunk {
                        if current.area.maxY > source.area.maxY { break }
                    } else if !current.isHorizontal || !isLeft {
                        break
                    }
                } else if mov.contains(.down) {
                    if shrunk {
                        if current.area.y < source.area.y { break }
                    } else if current.isHorizontal || isLeft {
                        break
                    }
                } else if mov.contains(.left) {
                    if shrunk {
                        if current.area.maxX > source.area.maxX { break }
                    } else if !current.isHorizontal || !isLeft {
                        break
                    }
                } else if mov.contains(.right) {
                    if shrunk {
                        if current.area.x < source.area.x { break }
                    } else if !current.isHorizontal || isLeft {
                        break
                    }
                }
            }

            guard let next = current.parent else { break }
            childFork = current
            parent = next
        }

        let length: Double
        if current.isHorizontal {
            length = isLeft ? crect.maxX - current.area.x : crect.x - current.area.x
        } else {
            length = isLeft ? crect.maxY - current.area.y : crect.y - current.area.y
        }

        current.setRatio(length)
        current.measure(self, area: current.area)
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
        case .fork(let f): return describe(f, scope: scope, rect: rect)
        case .window(let w): return "Window(\(w)) \(rect(w).map { "\($0)" } ?? "?")"
        }
    }
}
