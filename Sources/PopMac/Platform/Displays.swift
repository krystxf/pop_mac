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
              entry[kCGWindowIsOnscreen as String] as? Bool == true
        else { return nil }
        return frame(in: entry)
    }

    /// A window as the window server lists it.
    struct OnScreenWindow {
        let id: CGWindowID
        let frame: Rect
    }

    /// Every normal window that is visible on screen, from front to back.
    ///
    /// The window server answers at once, while an app may be busy for a while.
    static func onScreenWindows() -> [OnScreenWindow] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return info.compactMap { entry in
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  let id = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let frame = frame(in: entry)
            else { return nil }
            return OnScreenWindow(id: id, frame: frame)
        }
    }

    /// The ids of every normal window that is visible on screen, from front to back.
    static func onScreenWindowIDs() -> [CGWindowID] {
        onScreenWindows().map(\.id)
    }

    /// Every window that exists, on every Space, minimized or not.
    ///
    /// Nil if the window server did not answer, which is not the same as no windows.
    static func allWindowIDs() -> Set<CGWindowID>? {
        guard let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        return Set(info.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
    }

    /// The frame in an entry of the window server's list.
    private static func frame(in entry: [String: Any]) -> Rect? {
        guard let dictionary = entry[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: dictionary)
        else { return nil }
        return Rect(Double(bounds.origin.x), Double(bounds.origin.y), Double(bounds.width), Double(bounds.height))
    }
}
