import AppKit
import PopCore

extension TabColor {
    /// The two stops of the color's gradient, from left to right, close to the system colors.
    ///
    /// The second stop shifts the hue a little, so the tab has a soft sheen, not a flat fill.
    var stops: (NSColor, NSColor) {
        switch self {
        case .red: (.hex(0xFF453A), .hex(0xFF6A4D))
        case .orange: (.hex(0xFF9F0A), .hex(0xFFB83D))
        case .yellow: (.hex(0xFFD60A), .hex(0xEDE23B))
        case .green: (.hex(0x30D158), .hex(0x3DD68C))
        case .teal: (.hex(0x40C8E0), .hex(0x4AAFF0))
        case .blue: (.hex(0x0A84FF), .hex(0x5B7BFF))
        case .purple: (.hex(0xBF5AF2), .hex(0xD95FE0))
        case .pink: (.hex(0xFF375F), .hex(0xFF5A8C))
        }
    }

    /// Black or white, whichever reads better on the color.
    var text: NSColor { stops.0.contrastingText }

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

    /// A small circle of the color, for a menu item.
    static func swatch(_ color: TabColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            NSGradient(starting: color.stops.0, ending: color.stops.1)?.draw(in: circle, angle: 0)
            return true
        }
    }

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
