import Foundation

/// A node is either a fork or a window.
public enum Node {
    case fork(Fork)
    case window(WindowID)

    public func isFork(_ fork: Fork) -> Bool {
        if case .fork(let f) = self { return f === fork }
        return false
    }

    public func isWindow(_ window: WindowID) -> Bool {
        if case .window(let w) = self { return w == window }
        return false
    }

    public var windowID: WindowID? {
        if case .window(let w) = self { return w }
        return nil
    }

    public var forkValue: Fork? {
        if case .fork(let f) = self { return f }
        return nil
    }

    /// Calculates the future arrangement of windows in this node.
    func measure(_ forest: Forest, area: Rect) {
        switch self {
        case .fork(let fork):
            fork.measure(forest, area: area)
        case .window(let window):
            forest.record(window, area)
        }
    }
}

/// A tiling fork contains two children nodes.
///
/// These nodes may either be windows or sub-forks.
public final class Fork {
    public let id: Int
    unowned let forest: Forest

    public var left: Node {
        didSet { forest.adopt(left, into: self) }
    }

    public var right: Node? {
        didSet { if let right { forest.adopt(right, into: self) } }
    }

    public var area: Rect
    public var workspace: WorkspaceKey
    public var lengthLeft: Double
    public var prevLengthLeft: Double
    public var prevRatio: Double = 0.5
    public var orientation: Orientation
    var orientationChanged = false
    public internal(set) var isToplevel = false
    public var smartGapped = false
    public internal(set) weak var parent: Fork?
    var isDeleted = false

    /// Tracks toggle count so that we may swap branches when toggled twice.
    private var nToggled = 0

    init(id: Int, forest: Forest, left: Node, right: Node?, area: Rect, workspace: WorkspaceKey, orientation: Orientation) {
        self.id = id
        self.forest = forest
        self.left = left
        self.right = right
        self.area = area
        self.workspace = workspace
        self.orientation = orientation
        self.lengthLeft = orientation == .horizontal ? area.width / 2 : area.height / 2
        self.prevLengthLeft = lengthLeft
        forest.adopt(left, into: self)
        if let right { forest.adopt(right, into: self) }
    }

    public var isHorizontal: Bool { orientation == .horizontal }

    /// The length of the fork along its orientation.
    public var length: Double { isHorizontal ? area.width : area.height }

    /// The length of the fork across its orientation.
    public var depth: Double { isHorizontal ? area.height : area.width }

    /// The calculated area of the left branch.
    public func areaOfLeft() -> Rect {
        let half = forest.gapInner / 2
        return isHorizontal
            ? Rect(area.x, area.y, lengthLeft - half, area.height)
            : Rect(area.x, area.y, area.width, lengthLeft - half)
    }

    /// The calculated area of the right branch.
    public func areaOfRight() -> Rect {
        let half = forest.gapInner / 2
        if isHorizontal {
            let x = area.x + lengthLeft + half
            return Rect(x, area.y, area.maxX - x, area.height)
        } else {
            let y = area.y + lengthLeft + half
            return Rect(area.x, y, area.width, area.maxY - y)
        }
    }

    /// Sets the length of the left branch, within sane limits.
    @discardableResult
    public func setRatio(_ leftLength: Double) -> Fork {
        let minimum = min(256, length / 4)
        let clamped = max(minimum, min(length - minimum, leftLength)).rounded()
        prevLengthLeft = clamped
        lengthLeft = clamped
        return self
    }

    public func setOrientation(_ o: Orientation) {
        if o != orientation {
            orientation = o
            orientationChanged = true
        }
    }

    /// Picks the orientation that matches the shape of the fork's area.
    public func rebalanceOrientation() {
        setOrientation(area.height > area.width ? .vertical : .horizontal)
    }

    /// Swaps the left branch with the right branch, if there is a right branch.
    public func swapBranches() {
        if let r = right {
            right = left
            left = r
        }
    }

    /// Toggles the orientation. Every second toggle also swaps the branches,
    /// so that four toggles cycle through every arrangement.
    public func toggleOrientation() {
        orientation = orientation.toggled
        orientationChanged = true
        if nToggled == 1 {
            swapBranches()
            nToggled = 0
        } else {
            nToggled += 1
        }
    }

    /// Finds the branch that holds the window.
    public func findBranch(_ window: WindowID) -> Node? {
        if left.isWindow(window) { return left }
        if let right, right.isWindow(window) { return right }
        return nil
    }

    /// Calculates the future arrangement of windows in this fork.
    func measure(_ forest: Forest, area: Rect) {
        var ratio: Double?
        let manuallyMoved = forest.manuallyMoved

        if !isToplevel {
            if orientationChanged {
                orientationChanged = false
                ratio = lengthLeft / depth
            } else {
                ratio = lengthLeft / length
            }
            self.area = area
        } else if orientationChanged {
            orientationChanged = false
            ratio = lengthLeft / depth
        }

        if let ratio, ratio.isFinite, ratio > 0 {
            lengthLeft = (ratio * length).rounded()
            if manuallyMoved { prevRatio = ratio }
        } else if manuallyMoved, length > 0 {
            prevRatio = lengthLeft / length
        }

        guard let right else {
            left.measure(forest, area: self.area)
            return
        }

        let total = length
        let gapHalf = forest.gapInner / 2
        let split = lengthLeft.rounded()

        var region = self.area
        if isHorizontal {
            region.width = split - gapHalf
            left.measure(forest, area: region)
            region.x = self.area.x + split + gapHalf
            region.width = total - split - gapHalf
        } else {
            region.height = split - gapHalf
            left.measure(forest, area: region)
            region.y = self.area.y + split + gapHalf
            region.height = total - split - gapHalf
        }
        right.measure(forest, area: region)
    }
}
