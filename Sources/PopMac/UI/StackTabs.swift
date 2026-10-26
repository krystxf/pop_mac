import AppKit
import PopCore

/// The tab bar drawn above a stack of windows.
final class StackTabBar: NSPanel {
    private let stackView = NSStackView()
    var onSelect: ((WindowID) -> Void)?

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
        stackView.spacing = 2
        stackView.edgeInsets = NSEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)
        contentView = stackView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    struct Tab {
        let id: WindowID
        let title: String
        let icon: NSImage?
    }

    func update(tabs: [Tab], active: WindowID, color: NSColor, frame: Rect, above window: WindowID) {
        for view in stackView.arrangedSubviews {
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for tab in tabs {
            let button = TabButton(tab: tab, isActive: tab.id == active, color: color)
            button.onClick = { [weak self] in self?.onSelect?(tab.id) }
            stackView.addArrangedSubview(button)
        }

        setFrame(Displays.toCocoa(frame), display: true)
        if !isVisible { orderFrontRegardless() }
        order(.above, relativeTo: Int(window))
    }
}

private final class TabButton: NSView {
    var onClick: (() -> Void)?

    init(tab: StackTabBar.Tab, isActive: Bool, color: NSColor) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = isActive
            ? color.cgColor
            : NSColor(srgbRed: 0.61, green: 0.56, blue: 0.54, alpha: 0.95).cgColor

        let label = NSTextField(labelWithString: tab.title.isEmpty ? "Untitled" : tab.title)
        label.font = .systemFont(ofSize: 11, weight: isActive ? .semibold : .regular)
        label.textColor = isActive ? .black : .white
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView(image: tab.icon ?? NSImage())
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown

        addSubview(icon)
        addSubview(label)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

/// Keeps one tab bar per stack on the visible Spaces.
final class StackTabsController {
    private var bars: [Int: StackTabBar] = [:]

    func sync(_ entries: [(stack: StackNode, frame: Rect, tabs: [StackTabBar.Tab])], color: NSColor, onSelect: @escaping (WindowID) -> Void) {
        var seen = Set<Int>()
        for entry in entries {
            seen.insert(entry.stack.id)
            let bar = bars[entry.stack.id] ?? StackTabBar()
            bars[entry.stack.id] = bar
            bar.onSelect = onSelect
            bar.update(tabs: entry.tabs, active: entry.stack.active, color: color, frame: entry.frame, above: entry.stack.active)
        }
        for (id, bar) in bars where !seen.contains(id) {
            bar.orderOut(nil)
            bars.removeValue(forKey: id)
        }
    }

    func removeAll() {
        for bar in bars.values { bar.orderOut(nil) }
        bars.removeAll()
    }
}
