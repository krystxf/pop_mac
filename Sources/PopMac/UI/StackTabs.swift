import AppKit
import PopCore

/// The tab bar drawn above a stack of windows.
///
/// A click on a tab focuses its window. A drag moves the whole stack.
/// The bar glides along when its stack moves.
final class StackTabBar: NSPanel, GlidingWindow {
    private let stackView = NSStackView()
    var targetFrame: NSRect?
    var fadeGeneration = 0
    var isFadingOut = false
    var onSelect: ((WindowID) -> Void)?
    var onDrag: ((DragPhase) -> Void)?

    enum DragPhase {
        case moved
        /// The drag ended, with the modifiers held at mouse-up.
        case ended(CGEventFlags)
    }

    struct Tab: Equatable {
        let id: WindowID
        let title: String
        let icon: NSImage?
    }

    /// The stack's selected window, which the bar stays above.
    private(set) var window: WindowID?

    /// What the bar shows now, so an unchanged bar is not rebuilt.
    private var shown: (tabs: [Tab], active: WindowID, color: NSColor)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        level = .normal
        collectionBehavior = [.transient, .ignoresCycle]

        stackView.orientation = .horizontal
        stackView.distribution = .fillEqually
        stackView.spacing = 4
        stackView.edgeInsets = NSEdgeInsets(top: 1, left: 0, bottom: 1, right: 0)
        if #available(macOS 26, *) {
            // The tabs' glass blends where they meet, like one bar.
            let container = NSGlassEffectContainerView()
            container.spacing = 6
            container.contentView = stackView
            contentView = container
        } else {
            contentView = stackView
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func update(tabs: [Tab], active: WindowID, color: NSColor, frame: Rect, above window: WindowID) {
        if shown?.tabs != tabs || shown?.active != active || shown?.color != color {
            shown = (tabs, active, color)
            for view in stackView.arrangedSubviews {
                stackView.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            for tab in tabs {
                let button = TabButton(tab: tab, isActive: tab.id == active, color: color)
                button.onClick = { [weak self] in self?.onSelect?(tab.id) }
                button.onDrag = { [weak self] in self?.onDrag?($0) }
                stackView.addArrangedSubview(button)
                // A horizontal stack view does not stretch its views to its height.
                let insets = stackView.edgeInsets.top + stackView.edgeInsets.bottom
                button.heightAnchor.constraint(equalTo: stackView.heightAnchor, constant: -insets).isActive = true
            }
        }

        self.window = window
        appear(at: Displays.toCocoa(frame))
        order(.above, relativeTo: Int(window))
    }
}

private final class TabButton: NSView {
    var onClick: (() -> Void)?
    var onDrag: ((StackTabBar.DragPhase) -> Void)?
    private var downPoint: NSPoint?
    private var isDragging = false
    private var glass: NSView?

    init(tab: StackTabBar.Tab, isActive: Bool, color: NSColor) {
        super.init(frame: .zero)

        // Liquid Glass on macOS 26 and later, with the selected tab in the accent color.
        // A solid rounded rectangle before.
        let body: NSView
        let textColor: NSColor
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            self.glass = glass
            glass.tintColor = isActive ? color.withAlphaComponent(0.8) : nil
            glass.translatesAutoresizingMaskIntoConstraints = false
            body = NSView()
            glass.contentView = body
            addSubview(glass)
            NSLayoutConstraint.activate([
                glass.leadingAnchor.constraint(equalTo: leadingAnchor),
                glass.trailingAnchor.constraint(equalTo: trailingAnchor),
                glass.topAnchor.constraint(equalTo: topAnchor),
                glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            textColor = isActive ? color.contrastingText : .labelColor
        } else {
            wantsLayer = true
            layer?.cornerRadius = 6
            layer?.backgroundColor = isActive
                ? color.cgColor
                : NSColor(srgbRed: 0.61, green: 0.56, blue: 0.54, alpha: 0.95).cgColor
            body = self
            textColor = isActive ? color.contrastingText : .white
        }

        let label = NSTextField(labelWithString: tab.title.isEmpty ? "Untitled" : tab.title)
        label.font = .systemFont(ofSize: 11, weight: isActive ? .semibold : .regular)
        label.textColor = textColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let icon = NSImageView(image: tab.icon ?? NSImage())
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown

        body.addSubview(icon)
        body.addSubview(label)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: body.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
            label.trailingAnchor.constraint(lessThanOrEqualTo: body.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: body.centerYAnchor),
        ])
    }

    required init?(coder _: NSCoder) { nil }

    override func layout() {
        super.layout()
        // A pill: fully round ends at any height.
        if #available(macOS 26, *), let glass = glass as? NSGlassEffectView {
            glass.cornerRadius = bounds.height / 2
        }
    }

    /// The tab takes every click inside it, so its label and glass never swallow one.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    /// Pop Mac is never the active app, so the first click must count.
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        downPoint = event.locationInWindow
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let downPoint else { return }
        let point = event.locationInWindow
        if !isDragging, hypot(point.x - downPoint.x, point.y - downPoint.y) > 4 {
            isDragging = true
        }
        if isDragging { onDrag?(.moved) }
    }

    override func mouseUp(with event: NSEvent) {
        if isDragging {
            onDrag?(.ended(CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))))
        } else if downPoint != nil {
            onClick?()
        }
        downPoint = nil
        isDragging = false
    }
}

/// Keeps one tab bar per stack on the visible Spaces.
@MainActor
final class StackTabsController {
    struct Entry {
        let stack: StackNode
        /// The bar's frame, above the stack.
        let frame: Rect
        let tabs: [StackTabBar.Tab]
    }

    private var bars: [Int: StackTabBar] = [:]

    func sync(
        _ entries: [Entry], color: NSColor,
        onSelect: @escaping (WindowID) -> Void,
        onDrag: @escaping (StackNode, StackTabBar.DragPhase) -> Void
    ) {
        var seen = Set<Int>()
        for entry in entries {
            seen.insert(entry.stack.id)
            let bar = bars[entry.stack.id] ?? StackTabBar()
            bars[entry.stack.id] = bar
            bar.onSelect = onSelect
            let stack = entry.stack
            bar.onDrag = { onDrag(stack, $0) }
            bar.update(tabs: entry.tabs, active: entry.stack.active, color: color, frame: entry.frame, above: entry.stack.active)
        }
        for (id, bar) in bars where !seen.contains(id) {
            bar.disappear()
            bars.removeValue(forKey: id)
        }
    }

    /// Orders the tab bar of the stack whose selected window is `window` above that window again.
    func reorder(above window: WindowID) {
        for bar in bars.values where bar.window == window && bar.isVisible {
            bar.order(.above, relativeTo: Int(window))
        }
    }

    func removeAll() {
        for bar in bars.values { bar.disappear() }
        bars.removeAll()
    }
}
