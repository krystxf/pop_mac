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

enum SettingsTab: Hashable {
    case general, layout, appearance, shortcuts, floating
}

/// The settings window, which hosts `SettingsView`.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private var model: SettingsModel?
    private var selection = SettingsTabSelection()

    func show(manager: WindowManager, tab: SettingsTab? = nil) {
        if let tab { selection.tab = tab }
        if window == nil {
            let model = SettingsModel(manager: manager)
            let host = NSHostingController(rootView: SettingsView(model: model, selection: selection))
            let window = NSWindow(contentViewController: host)
            window.title = "Pop Mac Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
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
}

/// The selected tab, shared between the window controller and the view.
@MainActor
final class SettingsTabSelection: ObservableObject {
    @Published var tab: SettingsTab = .general
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var selection: SettingsTabSelection

    var body: some View {
        TabView(selection: $selection.tab) {
            GeneralSettings(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            LayoutSettings(model: model)
                .tabItem { Label("Layout", systemImage: "rectangle.split.3x1") }
                .tag(SettingsTab.layout)
            AppearanceSettings(model: model)
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
                .tag(SettingsTab.appearance)
            ShortcutSettings(model: model)
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
                .tag(SettingsTab.shortcuts)
            FloatingSettings(model: model)
                .tabItem { Label("Floating", systemImage: "macwindow.on.rectangle") }
                .tag(SettingsTab.floating)
        }
        .frame(width: 560, height: 500)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @ObservedObject var model: SettingsModel

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
                Text("Applies when you move focus or windows with the keyboard, and when you pick a window in the launcher.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Snap floating windows to the grid", isOn: model.binding(\.snapToGrid))
            } footer: {
                Text("When tiling is off, windows you drop snap to a grid of \(Int(model.settings.columnSize)) × \(Int(model.settings.rowSize)) points.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Config file") {
                    Button("Open") { model.openConfigFile() }
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
                Stepper(value: model.binding(\.gapInner), in: 0 ... 64, step: 2) {
                    LabeledContent("Gap between windows", value: "\(Int(model.settings.gapInner)) pt")
                }
                Stepper(value: model.binding(\.gapOuter), in: 0 ... 64, step: 2) {
                    LabeledContent("Gap at the screen edges", value: "\(Int(model.settings.gapOuter)) pt")
                }
                Toggle("Smart gaps", isOn: model.binding(\.smartGaps))
            } footer: {
                Text("Smart gaps remove the gap at the screen edges when a display shows only one window.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Limit the width of tiled windows", isOn: Binding(
                    get: { model.settings.maxWindowWidth > 0 },
                    set: { enabled in model.update { $0.maxWindowWidth = enabled ? 1600 : 0 } }
                ))
                if model.settings.maxWindowWidth > 0 {
                    Stepper(value: model.binding(\.maxWindowWidth), in: 400 ... 4000, step: 100) {
                        LabeledContent("Maximum width", value: "\(Int(model.settings.maxWindowWidth)) pt")
                    }
                }
            } footer: {
                Text("A wider tile centers its window. Useful on ultrawide displays.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Appearance

private struct AppearanceSettings: View {
    @ObservedObject var model: SettingsModel

    private static let presets: [(String, String)] = [
        ("Pop Orange", "#FBB86C"), ("Blue", "#3D8BFD"), ("Teal", "#2BC4B6"), ("Green", "#5CC06E"),
        ("Purple", "#A77BF3"), ("Pink", "#F06EAA"), ("Red", "#EF5B5B"), ("Graphite", "#8E8E93"),
    ]

    private var color: NSColor {
        let value = model.settings.overlayColor
        if value == "accent" { return .controlAccentColor }
        return NSColor(hex: value) ?? .orange
    }

    var body: some View {
        Form {
            Section {
                Toggle("Use the system accent color", isOn: Binding(
                    get: { model.settings.overlayColor == "accent" },
                    set: { useAccent in model.update { $0.overlayColor = useAccent ? "accent" : "#FBB86C" } }
                ))

                if model.settings.overlayColor != "accent" {
                    ColorPicker("Highlight color", selection: Binding(
                        get: { Color(nsColor: color) },
                        set: { newColor in model.update { $0.overlayColor = NSColor(newColor).hexString } }
                    ), supportsOpacity: false)

                    LabeledContent("Presets") {
                        HStack(spacing: 6) {
                            ForEach(Self.presets, id: \.1) { name, hex in
                                Button {
                                    model.update { $0.overlayColor = hex }
                                } label: {
                                    Circle().fill(Color(nsColor: NSColor(hex: hex) ?? .gray)).frame(width: 18, height: 18)
                                }
                                .buttonStyle(.plain)
                                .help(name)
                            }
                        }
                    }
                }
            } footer: {
                Text("The highlight shows where a window will go in tile mode and while you drag it.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Preview") {
                HStack {
                    Spacer()
                    RoundedRectangle(cornerRadius: model.settings.overlayBorderRadius)
                        .fill(Color(nsColor: color).opacity(0.25))
                        .overlay(
                            RoundedRectangle(cornerRadius: model.settings.overlayBorderRadius)
                                .stroke(Color(nsColor: color), lineWidth: 3)
                        )
                        .frame(width: 220, height: 110)
                    Spacer()
                }
                .padding(.vertical, 6)
            }
        }
        .formStyle(.grouped)
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
            } footer: {
                Text("Pop Shell's shortcuts use Super and Primary. A Mac keyboard has no Super key, so pick the keys they stand for.")
                    .font(.caption).foregroundStyle(.secondary)
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
                    Text("To change a shortcut, edit `keybindings` in the config file.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Config File") { model.openConfigFile() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ action: Action) -> some View {
        let combos = model.settings.combos(for: action).map(\.description)
        return LabeledContent(action.summary) {
            Text(combos.isEmpty ? "None" : combos.joined(separator: "  "))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(combos.isEmpty ? .tertiary : .secondary)
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
                    Text("No rules. Every window tiles, except Keka, which has a fixed size.")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(model.settings.floatRules.enumerated()), id: \.offset) { index, rule in
                    HStack {
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
                        .buttonStyle(.borderless)
                        .help("Remove this rule")
                    }
                }
            } header: {
                Text("Rules")
            } footer: {
                Text("The first matching rule wins. ⌃⌥G floats or tiles a single window.")
                    .font(.caption).foregroundStyle(.secondary)
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
                    .disabled(problem != nil)
                }
            } header: {
                Text("New rule")
            } footer: {
                Text("Both fields are case-insensitive regular expressions. `Slack` also matches “Slack Beta”; use `^Slack$` for an exact match.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func describe(_ rule: FloatRule) -> String {
        [rule.app.map { "App: \($0)" }, rule.title.map { "Title: \($0)" }].compactMap(\.self).joined(separator: "   ")
    }
}
