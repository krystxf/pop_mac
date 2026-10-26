import Foundation

/// A window candidate for directional focus.
public struct WindowCandidate {
    public var id: WindowID
    public var rect: Rect

    public init(id: WindowID, rect: Rect) {
        self.id = id
        self.rect = rect
    }
}

public enum FocusSelector {
    /// Selects the nearest window in a direction from the focused window.
    public static func select(_ direction: Direction, from focused: Rect, among windows: [WindowCandidate]) -> WindowID? {
        let filtered: [WindowCandidate]
        let distance: (Rect) -> Double

        switch direction {
        case .down:
            filtered = windows.filter { $0.rect.y > focused.y }
            distance = { Geom.downwardDistance($0, focused) }
        case .left:
            filtered = windows.filter { $0.rect.x < focused.x }
            distance = { Geom.leftwardDistance($0, focused) }
        case .right:
            filtered = windows.filter { $0.rect.x > focused.x }
            distance = { Geom.rightwardDistance($0, focused) }
        case .up:
            filtered = windows.filter { $0.rect.y < focused.y }
            distance = { Geom.upwardDistance($0, focused) }
        }

        return filtered.min { distance($0.rect) < distance($1.rect) }?.id
    }
}

public struct MonitorCandidate {
    public var id: MonitorID
    public var workArea: Rect

    public init(id: MonitorID, workArea: Rect) {
        self.id = id
        self.workArea = workArea
    }
}

public enum MonitorLocator {
    /// Finds the display that lies in a direction from the display `from`.
    public static func locate(_ direction: Direction, from: MonitorCandidate, among monitors: [MonitorCandidate]) -> MonitorCandidate? {
        let ref = from.workArea
        let origin: Point
        let exclude: (Rect) -> Bool

        switch direction {
        case .up:
            origin = ref.north
            exclude = { $0.y > ref.y }
        case .down:
            origin = ref.south
            exclude = { $0.y < ref.y }
        case .left:
            origin = ref.west
            exclude = { $0.x > ref.x }
        case .right:
            origin = ref.east
            exclude = { $0.x < ref.x }
        }

        var next: (MonitorCandidate, Double)?
        for monitor in monitors where monitor.id != from.id && !exclude(monitor.workArea) {
            let weight = Geom.shortestSide(origin, monitor.workArea)
            if next == nil || next!.1 > weight {
                next = (monitor, weight)
            }
        }
        return next?.0
    }

    /// Scales a floating window from one display to another, keeping its relative place.
    public static func proportionalMove(_ rect: Rect, from prev: Rect, to next: Rect) -> Rect {
        var r = rect
        let wRatio = next.width / prev.width
        let hRatio = next.height / prev.height
        r.x = next.x + (rect.x - prev.x) * wRatio
        r.y = next.y + (rect.y - prev.y) * hRatio
        r.width = rect.width * wRatio
        r.height = rect.height * hRatio
        return r
    }
}

/// The display grid that the overlay snaps to when windows are not auto-tiled.
public enum Grid {
    /// The size of one grid cell on a display.
    public static func cell(monitor: Rect, columnSize: Double, rowSize: Double) -> Rect {
        let columns = max(1, (monitor.width / columnSize).rounded(.down))
        let rows = max(1, (monitor.height / rowSize).rounded(.down))
        var tileWidth = monitor.width / columns
        var tileHeight = monitor.height / rows

        // Anything above 21:9 is considered ultrawide.
        if monitor.width * 9 >= monitor.height * 21 { tileWidth /= 2 }
        // Anything below 9:21 is probably a rotated ultrawide.
        if monitor.height * 9 >= monitor.width * 21 { tileHeight /= 2 }

        return Rect(monitor.x, monitor.y, tileWidth, tileHeight)
    }

    /// Moves or resizes `overlay` by whole grid cells, and keeps it on the displays.
    public static func change(_ overlay: Rect, cell: Rect, dx: Double, dy: Double, dw: Double, dh: Double, monitors: [Rect]) -> Rect {
        var changed = Rect(
            overlay.x + dx * cell.width,
            overlay.y + dy * cell.height,
            overlay.width + dw * cell.width,
            overlay.height + dh * cell.height
        )

        // Align to grid.
        changed.x = Geom.roundIncrement(changed.x - cell.x, cell.width) + cell.x
        changed.y = Geom.roundIncrement(changed.y - cell.y, cell.height) + cell.y
        changed.width = max(cell.width, Geom.roundIncrement(changed.width, cell.width))
        changed.height = max(cell.height, Geom.roundIncrement(changed.height, cell.height))

        let touching = monitors.filter { $0.intersects(changed) }
        guard !touching.isEmpty else { return overlay }

        let minX = touching.map(\.x).min()!
        let minY = touching.map(\.y).min()!
        let maxX = touching.map(\.maxX).max()!
        let maxY = touching.map(\.maxY).max()!

        if changed.x < minX || changed.maxX > maxX + 0.5 || changed.y < minY || changed.maxY > maxY + 0.5 {
            return overlay
        }
        return changed
    }
}
