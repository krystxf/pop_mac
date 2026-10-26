import AppKit
import PopCore

/// Lists every key binding, like Pop Shell's "View All" shortcuts panel.
@MainActor
final class ShortcutsWindow {
    private var window: NSWindow?

    func show(settings: Settings) {
        let text = NSMutableAttributedString()
        let heading: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .semibold)]
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13)]
        let keys: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]

        func section(_ title: String, _ actions: [Action]) {
            text.append(NSAttributedString(string: title + "\n", attributes: heading))
            for action in actions {
                let combos = settings.combos(for: action).map(\.description)
                guard !combos.isEmpty else { continue }
                text.append(NSAttributedString(string: action.summary + "\t", attributes: body))
                text.append(NSAttributedString(string: combos.joined(separator: "  ") + "\n", attributes: keys))
            }
            text.append(NSAttributedString(string: "\n", attributes: body))
        }

        let global = Action.allCases.filter { !$0.isTileMode }
        let tile = Action.allCases.filter(\.isTileMode)
        section("Shortcuts", global)
        section("Tile mode (enter with \(settings.combos(for: .tileEnter).first?.description ?? "tile-enter"))", tile)

        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: 330)]
        paragraph.paragraphSpacing = 3
        text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))

        let window = window ?? makeWindow()
        let scroll = window.contentView as! NSScrollView
        let view = scroll.documentView as! NSTextView
        view.textStorage?.setAttributedString(text)

        self.window = window
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Pop Mac Shortcuts"
        window.isReleasedWhenClosed = false

        let scroll = NSTextView.scrollableTextView()
        let view = scroll.documentView as! NSTextView
        view.isEditable = false
        view.textContainerInset = NSSize(width: 16, height: 16)
        view.drawsBackground = false
        window.contentView = scroll
        return window
    }
}
