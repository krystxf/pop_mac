import AppKit
import PopCore

/// Pop Shell's launcher: search and switch windows, launch apps, run commands.
///
/// - Plain text searches open windows and installed applications.
/// - `=` evaluates arithmetic, for example `=2*(3+4)`.
/// - `:` runs a shell command, for example `:open ~/Downloads`.
/// - `/` or `~` browses files and opens the selection.
@MainActor
final class Launcher: NSObject {
    enum Kind {
        case window(WindowID)
        case app(URL)
        case command(String)
        case calc(String)
        case file(URL)
    }

    struct Item {
        let kind: Kind
        let title: String
        let subtitle: String
        let icon: NSImage?
    }

    private weak var manager: WindowManager?
    private let panel = LauncherPanel()
    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var items: [Item] = []
    private var apps: [URL] = []
    private static let maxResults = 9
    private static let rowHeight: CGFloat = 44
    private static let width: CGFloat = 640

    init(manager: WindowManager) {
        self.manager = manager
        super.init()
        build()
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        isVisible ? close(restoreFocus: true) : open()
    }

    func open() {
        manager?.exitTileMode()
        apps = Self.scanApplications()
        field.stringValue = ""
        refresh()

        let display = Displays.display(at: Displays.cursor) ?? Displays.all().first
        if let display {
            let screen = Displays.toCocoa(display.workArea)
            let x = screen.midX - Self.width / 2
            let y = screen.maxY - screen.height / 4
            panel.setFrameTopLeftPoint(NSPoint(x: x, y: y))
        }

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    func close(restoreFocus: Bool) {
        panel.orderOut(nil)
        if restoreFocus { NSApp.hide(nil) }
    }

    // MARK: - Layout

    private func build() {
        let content = NSVisualEffectView()
        content.material = .hudWindow
        content.state = .active
        content.blendingMode = .behindWindow
        content.wantsLayer = true
        content.layer?.cornerRadius = 12
        content.layer?.masksToBounds = true
        panel.contentView = content

        field.placeholderString = "Type to search apps, or use ? for help"
        field.font = .systemFont(ofSize: 20)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(activateSelection)
        table.action = #selector(activateSelection)

        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(field)
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6),
        ])

        panel.onResignKey = { [weak self] in self?.close(restoreFocus: false) }
    }

    private func resize() {
        let rows = CGFloat(items.count)
        let height = 14 + 26 + 10 + rows * (Self.rowHeight + 2) + (rows > 0 ? 6 : 4)
        var frame = panel.frame
        let top = frame.maxY
        frame.size = NSSize(width: Self.width, height: height)
        frame.origin.y = top - height
        panel.setFrame(frame, display: true)
    }

    // MARK: - Search

    private func refresh() {
        items = search(field.stringValue)
        table.reloadData()
        if !items.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        resize()
    }

    private func search(_ query: String) -> [Item] {
        let text = query.trimmingCharacters(in: .whitespaces)

        if text == "?" {
            return [
                Item(kind: .command(""), title: "=  Calculate", subtitle: "=2*(3+4) copies the result", icon: nil),
                Item(kind: .command(""), title: ":  Run a command", subtitle: ":open ~/Downloads", icon: nil),
                Item(kind: .command(""), title: "/  or  ~  Open a file", subtitle: "~/Documents/report.pdf", icon: nil),
                Item(kind: .command(""), title: "Search", subtitle: "Type a name to switch windows or launch apps", icon: nil),
            ]
        }

        if text.hasPrefix("=") {
            let expression = String(text.dropFirst())
            let result = Calculator.evaluate(expression).map(Calculator.format) ?? "…"
            return [Item(kind: .calc(result), title: result, subtitle: "Press Return to copy", icon: NSImage(systemSymbolName: "function", accessibilityDescription: nil))]
        }

        if text.hasPrefix(":") {
            let command = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
            return [Item(kind: .command(command), title: command.isEmpty ? "Run a command" : command, subtitle: "Run in a login shell", icon: NSImage(systemSymbolName: "terminal", accessibilityDescription: nil))]
        }

        if text.hasPrefix("/") || text.hasPrefix("~") {
            return fileItems(text)
        }

        var scored: [(Double, Item)] = []

        for window in manager?.activeWindowList() ?? [] {
            let title = window.title.isEmpty ? window.appName : window.title
            let haystack = "\(window.appName) \(window.title)"
            let score = text.isEmpty ? 1 : Fuzzy.score(text, haystack)
            if score > 0 {
                scored.append((score + 0.5, Item(kind: .window(window.id), title: title, subtitle: window.appName, icon: window.app.icon)))
            }
        }

        if !text.isEmpty {
            for url in apps {
                let name = url.deletingPathExtension().lastPathComponent
                let score = Fuzzy.score(text, name)
                if score > 0 {
                    let icon = NSWorkspace.shared.icon(forFile: url.path)
                    scored.append((score, Item(kind: .app(url), title: name, subtitle: url.path, icon: icon)))
                }
            }
        }

        // A stable sort keeps the front-to-back window order for equal scores.
        return scored.enumerated()
            .sorted { $0.element.0 != $1.element.0 ? $0.element.0 > $1.element.0 : $0.offset < $1.offset }
            .prefix(Self.maxResults)
            .map(\.element.1)
    }

    private func fileItems(_ text: String) -> [Item] {
        let expanded = (text as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        let isDirectory = text.hasSuffix("/")
        let directory = isDirectory ? url : url.deletingLastPathComponent()
        let prefix = isDirectory ? "" : url.lastPathComponent.lowercased()

        let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return entries
            .filter { prefix.isEmpty || $0.lastPathComponent.lowercased().hasPrefix(prefix) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .prefix(Self.maxResults)
            .map { Item(kind: .file($0), title: $0.lastPathComponent, subtitle: $0.path, icon: NSWorkspace.shared.icon(forFile: $0.path)) }
    }

    static func scanApplications() -> [URL] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let roots = [
            "/Applications", "/Applications/Utilities", "/System/Applications",
            "/System/Applications/Utilities", "\(home)/Applications",
        ]
        var seen = Set<String>()
        var result: [URL] = [URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")]
        for root in roots {
            let urls = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil)) ?? []
            for url in urls where url.pathExtension == "app" && seen.insert(url.lastPathComponent).inserted {
                result.append(url)
            }
        }
        return result
    }

    // MARK: - Activation

    @objc private func activateSelection() {
        let row = table.selectedRow
        guard items.indices.contains(row) else { return }
        let item = items[row]

        switch item.kind {
        case .window(let id):
            close(restoreFocus: false)
            manager?.activate(id)
        case .app(let url):
            close(restoreFocus: false)
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        case .command(let command):
            guard !command.isEmpty else { return }
            close(restoreFocus: true)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]
            try? process.run()
        case .calc(let result):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(result, forType: .string)
            close(restoreFocus: true)
        case .file(let url):
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue, !url.path.hasSuffix(".app") {
                field.stringValue = (url.path as NSString).abbreviatingWithTildeInPath + "/"
                refresh()
                return
            }
            close(restoreFocus: false)
            NSWorkspace.shared.open(url)
        }
    }

    private func moveSelection(_ delta: Int) {
        guard !items.isEmpty else { return }
        let row = (table.selectedRow + delta + items.count) % items.count
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }
}

extension Launcher: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        refresh()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertTab(_:)):
            moveSelection(1)
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.insertBacktab(_:)):
            moveSelection(-1)
        case #selector(NSResponder.insertNewline(_:)):
            activateSelection()
        case #selector(NSResponder.cancelOperation(_:)):
            close(restoreFocus: true)
        default:
            return false
        }
        return true
    }
}

extension Launcher: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let cell = NSTableCellView()

        let icon = NSImageView(image: item.icon ?? NSImage())
        icon.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: item.title)
        title.font = .systemFont(ofSize: 14, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false
        let subtitle = NSTextField(labelWithString: item.subtitle)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingMiddle
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(icon)
        cell.addSubview(title)
        cell.addSubview(subtitle)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            title.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -10),
            title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 5),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -10),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
        ])
        return cell
    }
}

/// A borderless panel that can take keyboard focus.
final class LauncherPanel: NSPanel {
    var onResignKey: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 640, height: 60), styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .modalPanel
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
    }

    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

/// A simple fuzzy matcher: prefixes beat word starts, which beat substrings and subsequences.
enum Fuzzy {
    static func score(_ query: String, _ text: String) -> Double {
        let q = query.lowercased()
        let t = text.lowercased()
        guard !q.isEmpty else { return 1 }

        if t.hasPrefix(q) { return 100 - Double(t.count - q.count) * 0.1 }
        if let range = t.range(of: q) {
            let atWord = range.lowerBound == t.startIndex || !t[t.index(before: range.lowerBound)].isLetter
            return (atWord ? 80 : 60) - Double(t.distance(from: t.startIndex, to: range.lowerBound)) * 0.1
        }

        // Every query character in order.
        var index = t.startIndex
        var gaps = 0
        for char in q {
            guard let found = t[index...].firstIndex(of: char) else { return 0 }
            gaps += t.distance(from: index, to: found)
            index = t.index(after: found)
        }
        return max(1, 40 - Double(gaps))
    }
}

/// Evaluates arithmetic: + - * / % ^, parentheses, and decimals.
enum Calculator {
    static func evaluate(_ text: String) -> Double? {
        var parser = Parser(chars: Array(text.filter { !$0.isWhitespace }))
        guard let value = parser.expression(), parser.index == parser.chars.count, value.isFinite else { return nil }
        return value
    }

    static func format(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e15 { return String(Int64(value)) }
        return String(format: "%.10g", value)
    }

    private struct Parser {
        let chars: [Character]
        var index = 0

        mutating func expression() -> Double? {
            guard var value = term() else { return nil }
            while index < chars.count, chars[index] == "+" || chars[index] == "-" {
                let op = chars[index]
                index += 1
                guard let rhs = term() else { return nil }
                value = op == "+" ? value + rhs : value - rhs
            }
            return value
        }

        mutating func term() -> Double? {
            guard var value = power() else { return nil }
            while index < chars.count, "*/%x".contains(chars[index]) {
                let op = chars[index]
                index += 1
                guard let rhs = power() else { return nil }
                switch op {
                case "/": value /= rhs
                case "%": value = value.truncatingRemainder(dividingBy: rhs)
                default: value *= rhs
                }
            }
            return value
        }

        mutating func power() -> Double? {
            guard let base = unary() else { return nil }
            if index < chars.count, chars[index] == "^" {
                index += 1
                guard let exponent = power() else { return nil }
                return pow(base, exponent)
            }
            return base
        }

        mutating func unary() -> Double? {
            if index < chars.count, chars[index] == "-" {
                index += 1
                return unary().map { -$0 }
            }
            if index < chars.count, chars[index] == "+" {
                index += 1
                return unary()
            }
            return primary()
        }

        mutating func primary() -> Double? {
            guard index < chars.count else { return nil }
            if chars[index] == "(" {
                index += 1
                guard let value = expression(), index < chars.count, chars[index] == ")" else { return nil }
                index += 1
                return value
            }
            let start = index
            while index < chars.count, chars[index].isNumber || chars[index] == "." {
                index += 1
            }
            return Double(String(chars[start..<index]))
        }
    }
}
