import Foundation

/// A saved tiling layout, so that Pop Mac can rebuild its trees after a restart.
///
/// Windows are saved by their window number. The number stays the same while
/// the window's app keeps running, so a restart of Pop Mac finds every window
/// again. Windows that are gone by then drop out, and their neighbors fill the space.
public struct SavedLayout: Codable, Equatable {
    public var trees: [SavedTree]

    public init(trees: [SavedTree]) {
        self.trees = trees
    }

    public static var defaultURL: URL {
        Settings.defaultURL.deletingLastPathComponent().appendingPathComponent("layout.json")
    }

    public static func load(from url: URL = defaultURL) -> SavedLayout? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SavedLayout.self, from: data)
    }

    public func save(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

/// The tree of one display on one Space.
public struct SavedTree: Codable, Equatable {
    public var monitor: MonitorID
    public var space: SpaceID
    public var root: SavedFork

    public var key: WorkspaceKey { WorkspaceKey(monitor: monitor, space: space) }
}

public struct SavedFork: Codable, Equatable {
    public var orientation: Orientation
    /// The share of the fork's length that the left branch takes.
    public var ratio: Double
    public var left: SavedNode
    public var right: SavedNode?
}

public indirect enum SavedNode: Codable, Equatable {
    case window(WindowID)
    case stack(windows: [WindowID], active: WindowID)
    case fork(SavedFork)
}

extension Forest {
    /// Every tree, in a form that can be saved.
    public func snapshot() -> SavedLayout {
        func save(_ fork: Fork) -> SavedFork {
            let ratio = fork.length > 0 ? fork.lengthLeft / fork.length : 0.5
            return SavedFork(orientation: fork.orientation, ratio: ratio, left: save(fork.left), right: fork.right.map(save))
        }
        func save(_ node: Node) -> SavedNode {
            switch node {
            case let .window(window): .window(window)
            case let .stack(stack): .stack(windows: stack.entities, active: stack.active)
            case let .fork(fork): .fork(save(fork))
            }
        }
        let trees = toplevels.map { key, fork in SavedTree(monitor: key.monitor, space: key.space, root: save(fork)) }
        return SavedLayout(trees: trees.sorted { ($0.monitor, $0.space) < ($1.monitor, $1.space) })
    }

    /// Rebuilds a saved tree in `area`, with only the windows that `keep` accepts.
    ///
    /// A fork that lost one branch becomes its other branch, and a stack of one becomes a window.
    /// Returns the new top-level fork, or nil if no window is left or the workspace has a tree already.
    func rebuild(_ tree: SavedTree, area: Rect, keep: (WindowID) -> Bool) -> Fork? {
        let key = tree.key
        guard findToplevel(key) == nil else { return nil }

        func usable(_ window: WindowID) -> Bool {
            keep(window) && attached[window] == nil
        }

        func build(_ node: SavedNode, area: Rect) -> Node? {
            switch node {
            case let .window(window):
                return usable(window) ? .window(window) : nil
            case let .stack(windows, active):
                let kept = windows.filter(usable)
                guard let first = kept.first else { return nil }
                guard kept.count > 1 else { return .window(first) }
                let stack = createStack(window: first)
                stack.entities = kept
                stack.active = kept.contains(active) ? active : first
                return .stack(stack)
            case let .fork(saved):
                let ratio = saved.ratio.isFinite && saved.ratio > 0 && saved.ratio < 1 ? saved.ratio : 0.5
                let horizontal = saved.orientation == .horizontal
                let split = ((horizontal ? area.width : area.height) * ratio).rounded()
                let leftArea = horizontal ? Rect(area.x, area.y, split, area.height) : Rect(area.x, area.y, area.width, split)
                let rightArea = horizontal
                    ? Rect(area.x + split, area.y, area.width - split, area.height)
                    : Rect(area.x, area.y + split, area.width, area.height - split)

                let left = build(saved.left, area: leftArea)
                let right = saved.right.flatMap { build($0, area: rightArea) }
                guard let left, let right else { return left ?? right }

                let fork = createFork(left: left, right: right, area: area, workspace: key)
                fork.orientation = saved.orientation
                fork.lengthLeft = split
                fork.prevRatio = ratio
                return .fork(fork)
            }
        }

        guard let node = build(.fork(tree.root), area: area) else { return nil }
        let root: Fork = if case let .fork(fork) = node {
            fork
        } else {
            createFork(left: node, right: nil, area: area, workspace: key)
        }
        setToplevel(root)
        return root
    }
}
