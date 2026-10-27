import AppKit
import PopCore
import ServiceManagement
import SwiftUI

/// Connects the settings window to the window manager.
///
/// Every change goes through `WindowManager.update`, which saves the config file.
@MainActor
final class SettingsModel: ObservableObject {
    private weak var manager: WindowManager?
    @Published private(set) var settings: PopCore.Settings
    @Published private(set) var launchAtLogin = false
    @Published var launchAtLoginError: String?

    init(manager: WindowManager) {
        self.manager = manager
        settings = manager.settings
        refresh()
    }

    /// Reads the current state, for example after the config file changed.
    func refresh() {
        if let manager { settings = manager.settings }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func binding<T>(_ keyPath: WritableKeyPath<PopCore.Settings, T>) -> Binding<T> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { value in self.update { $0[keyPath: keyPath] = value } }
        )
    }

    func update(_ change: (inout PopCore.Settings) -> Void) {
        manager?.update(change)
        refresh()
    }

    var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { self.launchAtLogin },
            set: { enable in
                do {
                    if enable {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                    self.launchAtLoginError = nil
                } catch {
                    self.launchAtLoginError = error.localizedDescription
                }
                self.refresh()
            }
        )
    }

    func openConfigFile() {
        let url = PopCore.Settings.defaultURL
        if !FileManager.default.fileExists(atPath: url.path) { manager?.save() }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Window

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, layout, appearance, shortcuts, floating

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .layout: "Layout"
        case .appearance: "Appearance"
        case .shortcuts: "Shortcuts"
        case .floating: "Floating Windows"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "How Pop Mac starts and follows your focus."
        case .layout: "Gaps between tiles, and how wide a tile can get."
        case .appearance: "The highlight that shows where a window will go."
        case .shortcuts: "The keys behind Super and Primary, and every shortcut."
        case .floating: "Rules for windows that float instead of tile."
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .layout: "rectangle.split.3x1.fill"
        case .appearance: "paintpalette.fill"
        case .shortcuts: "keyboard.fill"
        case .floating: "macwindow.on.rectangle"
        }
    }

    var color: Color {
        switch self {
        case .general: .gray
        case .layout: .orange
        case .appearance: .pink
        case .shortcuts: .blue
        case .floating: .teal
        }
    }
}

/// The settings window, which hosts `SettingsView`.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private var model: SettingsModel?
    private let selection = SettingsTabSelection()

    func show(manager: WindowManager, tab: SettingsTab? = nil) {
        if let tab { selection.tab = tab }
        if window == nil {
            let model = SettingsModel(manager: manager)

            // An AppKit sidebar item gets the floating Liquid Glass sidebar on macOS 26.
            let split = NSSplitViewController()
            let sidebar = NSSplitViewItem(sidebarWithViewController: NSHostingController(rootView: SettingsSidebar(selection: selection)))
            sidebar.minimumThickness = 200
            sidebar.maximumThickness = 240
            sidebar.canCollapse = false
            let detail = NSSplitViewItem(viewController: NSHostingController(rootView: SettingsDetail(model: model, selection: selection)))
            detail.minimumThickness = 480
            split.addSplitViewItem(sidebar)
            split.addSplitViewItem(detail)

            let window = NSWindow(contentViewController: split)
            window.title = "Pop Mac Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            // An empty unified toolbar places the traffic lights over the sidebar, like System Settings.
            window.toolbar = NSToolbar(identifier: "settings")
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 780, height: 580))
            window.center()
            self.window = window
            self.model = model
        }
        model?.refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Updates an open window after the settings changed elsewhere.
    func refresh() {
        model?.refresh()
    }

    /// Saves an image of every page into a folder, for development.
    func snapshotPages(manager: WindowManager, to folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (index, tab) in SettingsTab.allCases.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 1.2) { [weak self] in
                MainActor.assumeIsolated {
                    self?.show(manager: manager, tab: tab)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        MainActor.assumeIsolated {
                            guard let window = self?.window else { return }
                            let url = folder.appendingPathComponent("settings-\(tab.rawValue).png")
                            Log.info(Snapshots.save(window, to: url) ? "saved \(url.path)" : "could not save \(url.path)")
                        }
                    }
                }
            }
        }
    }
}

/// The selected page, shared between the window controller and the view.
@MainActor
final class SettingsTabSelection: ObservableObject {
    @Published var tab: SettingsTab = .general
}

/// The list of pages on the left.
private struct SettingsSidebar: View {
    @ObservedObject var selection: SettingsTabSelection

    var body: some View {
        List(SettingsTab.allCases, selection: Binding(get: { selection.tab }, set: { if let tab = $0 { selection.tab = tab } })) { tab in
            Label {
                Text(tab.title)
            } icon: {
                SettingsIcon(tab: tab, size: 22)
            }
            .tag(tab)
        }
        .listStyle(.sidebar)
    }
}

/// The selected page on the right.
private struct SettingsDetail: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var selection: SettingsTabSelection

    var body: some View {
        SettingsPage(tab: selection.tab) {
            switch selection.tab {
            case .general: GeneralSettings(model: model)
            case .layout: LayoutSettings(model: model)
            case .appearance: AppearanceSettings(model: model)
            case .shortcuts: ShortcutSettings(model: model)
            case .floating: FloatingSettings(model: model)
            }
        }
        .frame(minWidth: 480, minHeight: 520)
    }
}

/// A page: a glass header card, then the page's settings.
private struct SettingsPage<Content: View>: View {
    let tab: SettingsTab
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                SettingsIcon(tab: tab, size: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text(tab.title).font(.title2.weight(.semibold))
                    Text(tab.subtitle).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(16)
            .glassCard(cornerRadius: 20, tint: tab.color)
            .padding(.horizontal, 20)
            .padding(.top, 16)

            content
        }
    }
}

/// A white symbol on a colored rounded square, like the icons in System Settings.
private struct SettingsIcon: View {
    let tab: SettingsTab
    let size: CGFloat

    var body: some View {
        Image(systemName: tab.symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .fill(tab.color.gradient)
            )
    }
}

// MARK: - Liquid Glass

private extension View {
    /// Liquid Glass on macOS 26 and later, the regular material before.
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat, tint: Color? = nil) -> some View {
        if #available(macOS 26, *) {
            glassEffect(tint.map { .regular.tint($0.opacity(0.18)) } ?? .regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    /// A Liquid Glass button on macOS 26 and later, a bordered button before.
    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else if prominent {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.bordered)
        }
    }
}

/// A standard slider with its current value after it.
private struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var unit = "pt"

    var body: some View {
        HStack {
            // Rounds to whole steps; a stepped slider would draw a tick mark per step.
            Slider(value: Binding(get: { value }, set: { value = ($0 / step).rounded() * step }), in: range) {
                Text(title)
            }
            Text("\(Int(value)) \(unit)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 52, alignment: .trailing)
        }
    }
}

private struct Footnote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @ObservedObject var model: SettingsModel

    /// The Super modifiers as symbols, for example ⌃⌥.
    private var superKeys: String {
        [MacModifier.control, .option, .shift, .command]
            .filter(model.settings.superModifiers.contains)
            .map(\.symbol).joined()
    }

    var body: some View {
        Form {
            Section {
                Toggle("Tile windows automatically", isOn: model.binding(\.tileByDefault))
                Toggle("Launch at login", isOn: model.launchAtLoginBinding)
                if let error = model.launchAtLoginError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }

            Section {
                Toggle("Move the cursor to the focused window", isOn: model.binding(\.mouseCursorFollowsActiveWindow))
                Picker("Cursor position", selection: model.binding(\.mouseCursorFocusLocation)) {
                    ForEach(FocusLocation.allCases, id: \.self) { location in
                        Text(location.title).tag(location)
                    }
                }
                .disabled(!model.settings.mouseCursorFollowsActiveWindow)
            } footer: {
                Footnote("Applies when you move focus or windows with the keyboard, and when you pick a window in the launcher.")
            }

            Section {
                Toggle("Move windows with \(superKeys) + drag", isOn: model.binding(\.superDragMovesWindows))
            } footer: {
                Footnote("Hold \(superKeys) and drag anywhere in a window to move it. Tiled windows drop like a title bar drag.")
            }

            Section {
                Toggle("Snap floating windows to the grid", isOn: model.binding(\.snapToGrid))
            } footer: {
                Footnote("When tiling is off, windows you drop snap to a grid of \(Int(model.settings.columnSize)) × \(Int(model.settings.rowSize)) points.")
            }

            Section {
                LabeledContent("Config file") {
                    Button("Open") { model.openConfigFile() }
                        .glassButton()
                }
            } footer: {
                Text(PopCore.Settings.defaultURL.path(percentEncoded: false))
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }
}

private extension FocusLocation {
    var title: String {
        switch self {
        case .center: "Center"
        case .topLeft: "Top left"
        case .topRight: "Top right"
        case .bottomLeft: "Bottom left"
        case .bottomRight: "Bottom right"
        }
    }
}

// MARK: - Layout

private struct LayoutSettings: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                ValueSlider(title: "Gap between windows", value: model.binding(\.gapInner), range: 0 ... 48, step: 1)
                ValueSlider(title: "Gap at the screen edges", value: model.binding(\.gapOuter), range: 0 ... 48, step: 1)
                Toggle("Smart gaps", isOn: model.binding(\.smartGaps))
            } header: {
                Text("Gaps")
            } footer: {
                Footnote("Your windows follow the sliders as you drag. Smart gaps remove the gap at the screen edges when a display shows only one window.")
            }

            Section {
                Toggle("Limit the width of tiled windows", isOn: Binding(
                    get: { model.settings.maxWindowWidth > 0 },
                    set: { enabled in model.update { $0.maxWindowWidth = enabled ? 1600 : 0 } }
                ))
                if model.settings.maxWindowWidth > 0 {
                    ValueSlider(title: "Maximum width", value: model.binding(\.maxWindowWidth), range: 600 ... 4000, step: 50)
                }
            } header: {
                Text("Width")
            } footer: {
                Footnote("A wider tile centers its window. Useful on ultrawide displays.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Appearance

private struct AppearanceSettings: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section("Preview") {
                OverlayPreview(radius: model.settings.overlayBorderRadius)
                    .frame(height: 170)
                    .listRowInsets(EdgeInsets())
            }

            Section {
                Toggle("Outline the focused window", isOn: model.binding(\.activeHint))
            } header: {
                Text("Active window")
            } footer: {
                Footnote("The outline is clear glass. Before macOS 26, it uses the accent color.")
            }
        }
        .formStyle(.grouped)
    }
}

/// Two windows on a desktop, with the highlight over the right one.
private struct OverlayPreview: View {
    let radius: Double

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(nsColor: .systemIndigo).opacity(0.55), Color(nsColor: .systemTeal).opacity(0.45)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            HStack(spacing: 10) {
                window
                window.overlay { highlight }
            }
            .padding(18)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(10)
    }

    /// Clear glass on macOS 26 and later, the accent color before, like the real highlight.
    @ViewBuilder
    private var highlight: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if #available(macOS 26, *) {
            Color.clear.glassEffect(.clear, in: shape)
        } else {
            shape.fill(Color.accentColor.opacity(0.25)).overlay(shape.stroke(Color.accentColor, lineWidth: 3))
        }
    }

    private var window: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0.opacity(0.8)).frame(width: 7, height: 7) }
                Spacer()
            }
            .padding(7)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassCard(cornerRadius: 10)
    }
}

// MARK: - Shortcuts

private struct ShortcutSettings: View {
    @ObservedObject var model: SettingsModel

    private static let superChoices: [[MacModifier]] = [
        [.control, .option], [.option], [.command], [.control, .command], [.option, .command], [.control, .option, .command],
    ]
    private static let primaryChoices: [[MacModifier]] = [[.command], [.control], [.option]]

    private func label(_ modifiers: [MacModifier]) -> String {
        let names: [MacModifier: String] = [.control: "Control", .option: "Option", .shift: "Shift", .command: "Command"]
        let order: [MacModifier] = [.control, .option, .shift, .command]
        let sorted = order.filter(modifiers.contains)
        return sorted.map(\.symbol).joined() + "  " + sorted.compactMap { names[$0] }.joined(separator: "-")
    }

    var body: some View {
        Form {
            Section {
                Picker("Super key", selection: model.binding(\.superModifiers)) {
                    ForEach(Self.superChoices, id: \.self) { Text(label($0)).tag($0) }
                }
                Picker("Primary key", selection: model.binding(\.primaryModifiers)) {
                    ForEach(Self.primaryChoices, id: \.self) { Text(label($0)).tag($0) }
                }
                if !Set(model.settings.superModifiers).isDisjoint(with: model.settings.primaryModifiers) {
                    Text("Super and Primary share a key, so some shortcuts collide.")
                        .font(.caption).foregroundStyle(.orange)
                }
            } header: {
                Text("Modifier keys")
            } footer: {
                Footnote("Pop Shell's shortcuts use Super and Primary. A Mac keyboard has no Super key, so pick the keys they stand for.")
            }

            Section("Shortcuts") {
                ForEach(Action.allCases.filter { !$0.isTileMode }, id: \.self) { row($0) }
            }

            Section {
                ForEach(Action.allCases.filter(\.isTileMode), id: \.self) { row($0) }
            } header: {
                Text("Tile mode")
            } footer: {
                HStack {
                    Footnote("To change a shortcut, edit `keybindings` in the config file.")
                    Spacer()
                    Button("Open Config File") { model.openConfigFile() }
                        .glassButton()
                }
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ action: Action) -> some View {
        let combos = model.settings.combos(for: action).map(\.description)
        return LabeledContent(action.summary) {
            HStack(spacing: 4) {
                if combos.isEmpty {
                    Text("None").foregroundStyle(.tertiary)
                }
                ForEach(combos, id: \.self) { combo in
                    Text(combo)
                        .font(.system(.callout, design: .rounded).weight(.medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .glassCard(cornerRadius: 6)
                }
            }
        }
    }
}

// MARK: - Floating

private struct FloatingSettings: View {
    @ObservedObject var model: SettingsModel
    @State private var app = ""
    @State private var title = ""
    @State private var tileInstead = false

    private var newRule: FloatRule {
        FloatRule(
            app: app.trimmingCharacters(in: .whitespaces).isEmpty ? nil : app.trimmingCharacters(in: .whitespaces),
            title: title.trimmingCharacters(in: .whitespaces).isEmpty ? nil : title.trimmingCharacters(in: .whitespaces),
            disabled: tileInstead ? true : nil
        )
    }

    /// Why the new rule cannot be added, if it cannot.
    private var problem: String? {
        let rule = newRule
        if rule.app == nil, rule.title == nil { return "" }
        for pattern in [rule.app, rule.title].compactMap(\.self) where (try? NSRegularExpression(pattern: pattern)) == nil {
            return "“\(pattern)” is not a valid regular expression."
        }
        return nil
    }

    var body: some View {
        Form {
            Section {
                if model.settings.floatRules.isEmpty {
                    Text("No rules. Every window tiles, except the Google Meet app and Keka, which has a fixed size.")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(model.settings.floatRules.enumerated()), id: \.offset) { index, rule in
                    HStack {
                        Image(systemName: rule.disabled == true ? "rectangle.split.2x1" : "macwindow.on.rectangle")
                            .foregroundStyle(.secondary)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(describe(rule))
                            Text(rule.disabled == true ? "Tiles" : "Floats").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            model.update { $0.floatRules.remove(at: index) }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .glassButton()
                        .help("Remove this rule")
                    }
                }
            } header: {
                Text("Rules")
            } footer: {
                Footnote("The first matching rule wins. ⌃⌥G floats or tiles a single window.")
            }

            Section {
                TextField("App name or bundle id", text: $app, prompt: Text("Calculator"))
                TextField("Window title", text: $title, prompt: Text("Optional"))
                Toggle("Make matching windows tile instead", isOn: $tileInstead)
                HStack {
                    if let problem, !problem.isEmpty {
                        Text(problem).font(.caption).foregroundStyle(.red)
                    }
                    Spacer()
                    Button("Add Rule") {
                        let rule = newRule
                        model.update { $0.floatRules.append(rule) }
                        app = ""
                        title = ""
                        tileInstead = false
                    }
                    .glassButton(prominent: true)
                    .disabled(problem != nil)
                }
            } header: {
                Text("New rule")
            } footer: {
                Footnote("Both fields are case-insensitive regular expressions. Slack also matches “Slack Beta”; use ^Slack$ for an exact match.")
            }
        }
        .formStyle(.grouped)
    }

    private func describe(_ rule: FloatRule) -> String {
        [rule.app.map { "App: \($0)" }, rule.title.map { "Title: \($0)" }].compactMap(\.self).joined(separator: "   ")
    }
}
