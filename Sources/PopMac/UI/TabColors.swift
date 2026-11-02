import AppKit
import PopCore

extension TabColor {
    /// The two pastel stops of the color's gradient, from left to right.
    ///
    /// The second stop shifts the hue a little, so the tab has a soft sheen, not a flat fill.
    var stops: (NSColor, NSColor) {
        switch self {
        case .rose: (.hex(0xF6C1CC), .hex(0xF8D3C6))
        case .peach: (.hex(0xF9CDAF), .hex(0xF8DEB2))
        case .butter: (.hex(0xF4E3A1), .hex(0xE9EDB0))
        case .mint: (.hex(0xBBE5CB), .hex(0xC3E9DD))
        case .aqua: (.hex(0xB3E3E0), .hex(0xBEDDEE))
        case .sky: (.hex(0xBBD6F5), .hex(0xC9D4F6))
        case .lavender: (.hex(0xD4CAF3), .hex(0xE2C9F0))
        case .lilac: (.hex(0xEAC6E5), .hex(0xF3CDDA))
        }
    }

    var name: String { rawValue.capitalized }

    /// The gradient's colors, at `alpha`.
    func gradient(alpha: CGFloat) -> [NSColor] {
        [stops.0.withAlphaComponent(alpha), stops.1.withAlphaComponent(alpha)]
    }
}

private extension NSColor {
    static func hex(_ value: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// A row of color swatches for a menu: one for no color, then one per pastel color.
///
/// A click picks the color and closes the menu.
final class TabColorPicker: NSView {
    private let selected: TabColor?
    private let onPick: (TabColor?) -> Void
    private var hovered: Int?

    private static let diameter: CGFloat = 16
    private static let spacing: CGFloat = 7
    private static let inset: CGFloat = 14
    /// No color first, then the colors.
    private static let choices: [TabColor?] = [nil] + TabColor.allCases

    init(selected: TabColor?, onPick: @escaping (TabColor?) -> Void) {
        self.selected = selected
        self.onPick = onPick
        let count = CGFloat(Self.choices.count)
        let width = Self.inset * 2 + count * Self.diameter + (count - 1) * Self.spacing
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 28))
        setAccessibilityRole(.group)
        setAccessibilityLabel("Tab color")
    }

    required init?(coder _: NSCoder) { nil }

    private func rect(at index: Int) -> NSRect {
        let x = Self.inset + CGFloat(index) * (Self.diameter + Self.spacing)
        return NSRect(x: x, y: (bounds.height - Self.diameter) / 2, width: Self.diameter, height: Self.diameter)
    }

    private func index(at point: NSPoint) -> Int? {
        Self.choices.indices.first { rect(at: $0).insetBy(dx: -Self.spacing / 2, dy: -6).contains(point) }
    }

    override func draw(_: NSRect) {
        for (index, choice) in Self.choices.enumerated() {
            let rect = rect(at: index)
            let circle = NSBezierPath(ovalIn: rect)
            if let choice {
                NSGradient(starting: choice.stops.0, ending: choice.stops.1)?.draw(in: circle, angle: 0)
                NSColor.black.withAlphaComponent(0.12).setStroke()
                circle.lineWidth = 0.5
                circle.stroke()
            } else {
                // No color: an empty circle with a slash.
                NSColor.secondaryLabelColor.setStroke()
                let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
                ring.lineWidth = 1.5
                ring.stroke()
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: rect.minX + 4, y: rect.minY + 4))
                slash.line(to: NSPoint(x: rect.maxX - 4, y: rect.maxY - 4))
                slash.lineWidth = 1.5
                slash.stroke()
            }
            // A ring marks the current color, and a fainter one the swatch under the mouse.
            let isSelected = choice == selected
            if isSelected || index == hovered {
                let ring = NSBezierPath(ovalIn: rect.insetBy(dx: -3, dy: -3))
                ring.lineWidth = 1.5
                (isSelected ? NSColor.labelColor : NSColor.tertiaryLabelColor).setStroke()
                ring.stroke()
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways], owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        let index = index(at: convert(event.locationInWindow, from: nil))
        if index != hovered {
            hovered = index
            needsDisplay = true
        }
    }

    override func mouseExited(with _: NSEvent) {
        hovered = nil
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let index = index(at: convert(event.locationInWindow, from: nil)) else { return }
        enclosingMenuItem?.menu?.cancelTracking()
        onPick(Self.choices[index])
    }
}

/// A menu item that runs a closure.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder _: NSCoder) { fatalError("not used") }

    @objc private func run() {
        handler()
    }
}
