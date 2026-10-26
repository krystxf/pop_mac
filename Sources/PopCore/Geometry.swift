import Foundation

/// Identifier of a window (the CoreGraphics window number on macOS).
public typealias WindowID = UInt32

/// Identifier of a display (the CoreGraphics display id on macOS).
public typealias MonitorID = UInt32

/// Identifier of a workspace (a macOS Space id).
public typealias SpaceID = UInt64

/// Each display on each workspace owns its own tiling tree.
public struct WorkspaceKey: Hashable, CustomStringConvertible {
    public var monitor: MonitorID
    public var space: SpaceID

    public init(monitor: MonitorID, space: SpaceID) {
        self.monitor = monitor
        self.space = space
    }

    public var description: String { "(\(monitor), \(space))" }
}

public enum Orientation: Int, Codable {
    case horizontal = 0
    case vertical = 1

    public var toggled: Orientation { self == .horizontal ? .vertical : .horizontal }
}

public enum Direction: CaseIterable {
    case left, up, right, down
}

public enum Side {
    case left, top, right, bottom, center
}

/// A rectangle in global screen coordinates with a top-left origin
/// (the coordinate space used by the Accessibility API).
public struct Rect: Equatable, Hashable, Codable, CustomStringConvertible {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(_ x: Double, _ y: Double, _ width: Double, _ height: Double) {
        self.init(x: x, y: y, width: width, height: height)
    }

    public static let zero = Rect(0, 0, 0, 0)

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var area: Double { width * height }

    public var center: Point { Point(x + width / 2, y + height / 2) }
    public var north: Point { Point(x + width / 2, y) }
    public var east: Point { Point(maxX, y + height / 2) }
    public var south: Point { Point(x + width / 2, maxY) }
    public var west: Point { Point(x, y + height / 2) }

    /// Adds the components of `other` to this rectangle.
    public mutating func apply(_ other: Rect) {
        x += other.x
        y += other.y
        width += other.width
        height += other.height
    }

    /// Clamps this rectangle so that it does not leave `other`.
    public mutating func clamp(_ other: Rect) {
        x = max(other.x, x)
        y = max(other.y, y)
        if maxX > other.maxX { width = other.maxX - x }
        if maxY > other.maxY { height = other.maxY - y }
    }

    public func contains(_ other: Rect) -> Bool {
        x <= other.x && y <= other.y && maxX >= other.maxX && maxY >= other.maxY
    }

    public func contains(_ point: Point) -> Bool {
        point.x >= x && point.x < maxX && point.y >= y && point.y < maxY
    }

    public func diff(_ other: Rect) -> Rect {
        Rect(other.x - x, other.y - y, other.width - width, other.height - height)
    }

    public func intersects(_ other: Rect) -> Bool {
        x < other.maxX && maxX > other.x && y < other.maxY && maxY > other.y
    }

    public func intersection(_ other: Rect) -> Rect? {
        let nx = max(x, other.x), ny = max(y, other.y)
        let nw = min(maxX, other.maxX) - nx, nh = min(maxY, other.maxY) - ny
        return nw > 0 && nh > 0 ? Rect(nx, ny, nw, nh) : nil
    }

    /// Shrinks the rectangle on every side by `amount`.
    public func inset(by amount: Double) -> Rect {
        Rect(x + amount, y + amount, width - amount * 2, height - amount * 2)
    }

    public func rounded() -> Rect {
        Rect(x.rounded(), y.rounded(), width.rounded(), height.rounded())
    }

    /// True when the two rectangles match within `tolerance` points.
    public func approximatelyEquals(_ other: Rect, tolerance: Double = 2) -> Bool {
        abs(x - other.x) <= tolerance && abs(y - other.y) <= tolerance
            && abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }

    public var description: String { "Rect(\(x), \(y), \(width), \(height))" }
}

public struct Point: Equatable, Codable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }
}

public enum Geom {
    public static func distance(_ a: Point, _ b: Point) -> Double {
        ((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)).squareRoot()
    }

    public static func upwardDistance(_ a: Rect, _ b: Rect) -> Double { distance(a.south, b.north) }
    public static func rightwardDistance(_ a: Rect, _ b: Rect) -> Double { distance(a.west, b.east) }
    public static func downwardDistance(_ a: Rect, _ b: Rect) -> Double { distance(a.north, b.south) }
    public static func leftwardDistance(_ a: Rect, _ b: Rect) -> Double { distance(a.east, b.west) }

    /// Finds the side of `rect` that is nearest to `origin`.
    ///
    /// The center counts only when `allowCenter` is true.
    public static func nearestSide(_ origin: Point, _ rect: Rect, allowCenter: Bool) -> (Double, Side) {
        let left = distance(origin, rect.west)
        let top = distance(origin, rect.north)
        let right = distance(origin, rect.east)
        let bottom = distance(origin, rect.south)
        let center = distance(origin, rect.center)

        var nearest: (Double, Side) = left < right ? (left, .left) : (right, .right)
        if top < nearest.0 { nearest = (top, .top) }
        if bottom < nearest.0 { nearest = (bottom, .bottom) }
        if allowCenter, center < nearest.0 { nearest = (center, .center) }
        return nearest
    }

    public static func shortestSide(_ origin: Point, _ rect: Rect) -> Double {
        min(
            distance(origin, rect.west),
            distance(origin, rect.north),
            distance(origin, rect.east),
            distance(origin, rect.south)
        )
    }

    public static func roundIncrement(_ value: Double, _ increment: Double) -> Double {
        (value / increment).rounded() * increment
    }
}

/// Describes how a window rectangle changed between two states.
public struct Movement: OptionSet {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let none: Movement = []
    public static let moved = Movement(rawValue: 1 << 0)
    public static let grow = Movement(rawValue: 1 << 1)
    public static let shrink = Movement(rawValue: 1 << 2)
    public static let left = Movement(rawValue: 1 << 3)
    public static let up = Movement(rawValue: 1 << 4)
    public static let right = Movement(rawValue: 1 << 5)
    public static let down = Movement(rawValue: 1 << 6)

    /// Calculates which edge of `from` moved to produce `change`.
    public static func calculate(from: Rect, change: Rect) -> Movement {
        let xpos = from.x == change.x
        let ypos = from.y == change.y

        if xpos, ypos {
            if from.width == change.width {
                if from.height == change.height {
                    return .none
                } else if from.height < change.height {
                    return [.grow, .down]
                } else {
                    return [.shrink, .up]
                }
            } else if from.width < change.width {
                return [.grow, .right]
            } else {
                return [.shrink, .left]
            }
        } else if xpos {
            return from.height < change.height ? [.grow, .up] : [.shrink, .down]
        } else if ypos {
            return from.width < change.width ? [.grow, .left] : [.shrink, .right]
        } else {
            return .moved
        }
    }
}
