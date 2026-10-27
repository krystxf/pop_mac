import AppKit
import PopCore

/// A connected display, with rectangles in top-left-origin global coordinates.
struct Display {
    let id: MonitorID
    let uuid: String
    let frame: Rect
    /// The frame without the menu bar and the Dock.
    let workArea: Rect
    let isMain: Bool
}

enum Displays {
    /// The height of the primary display, which anchors both coordinate systems.
    static var primaryHeight: Double {
        Double(NSScreen.screens.first?.frame.height ?? 0)
    }

    static func all() -> [Display] {
        NSScreen.screens.enumerated().compactMap { index, screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let id = number.uint32Value
            return Display(
                id: id,
                uuid: uuid(of: id),
                frame: toQuartz(screen.frame),
                workArea: toQuartz(screen.visibleFrame),
                isMain: index == 0
            )
        }
    }

    static func uuid(of display: CGDirectDisplayID) -> String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() else { return "" }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// Converts an AppKit rectangle (bottom-left origin) to top-left origin.
    static func toQuartz(_ rect: NSRect) -> Rect {
        Rect(
            Double(rect.origin.x),
            primaryHeight - Double(rect.origin.y + rect.height),
            Double(rect.width),
            Double(rect.height)
        )
    }

    /// Converts a top-left-origin rectangle to an AppKit rectangle.
    static func toCocoa(_ rect: Rect) -> NSRect {
        NSRect(x: rect.x, y: primaryHeight - rect.y - rect.height, width: rect.width, height: rect.height)
    }

    /// The display that holds most of the rectangle.
    static func display(for rect: Rect, in displays: [Display] = all()) -> Display? {
        if let containing = displays.first(where: { $0.frame.contains(rect.center) }) {
            return containing
        }
        return displays.max { a, b in
            (a.frame.intersection(rect)?.area ?? 0) < (b.frame.intersection(rect)?.area ?? 0)
        } ?? displays.first
    }

    static func display(at point: Point, in displays: [Display] = all()) -> Display? {
        displays.first { $0.frame.contains(point) } ?? displays.first
    }

    /// The cursor position in top-left-origin coordinates.
    static var cursor: Point {
        let p = NSEvent.mouseLocation
        return Point(Double(p.x), primaryHeight - Double(p.y))
    }

    /// The current Space of a display.
    static func currentSpace(of display: Display) -> SpaceID {
        let spaces = Spaces.currentSpaces()
        return spaces[display.uuid] ?? spaces["Main"] ?? Spaces.activeSpace
    }

    /// A window's frame, or nil if the window is not on screen, for example while it is minimized.
    static func onScreenFrame(of id: CGWindowID) -> Rect? {
        guard let entry = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first,
              entry[kCGWindowIsOnscreen as String] as? Bool == true,
              let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict)
        else { return nil }
        return Rect(Double(bounds.origin.x), Double(bounds.origin.y), Double(bounds.width), Double(bounds.height))
    }

    /// The frames of every window that is visible on screen, from front to back.
    ///
    /// The window server answers at once, while an app may be busy for a while.
    static func onScreenFrames() -> [(id: CGWindowID, frame: Rect)] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return info.compactMap { entry in
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  let id = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict)
            else { return nil }
            return (id, Rect(Double(bounds.origin.x), Double(bounds.origin.y), Double(bounds.width), Double(bounds.height)))
        }
    }

    /// The ids of every window that is visible on screen, from front to back.
    static func onScreenWindowIDs() -> [CGWindowID] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return info.compactMap { entry in
            guard (entry[kCGWindowLayer as String] as? Int) == 0 else { return nil }
            return (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        }
    }
}
