import AppKit
import PopCore

/// Prints what Pop Mac sees, without touching any window.
@MainActor
func diagnose() {
    print("Accessibility trusted: \(AX.isTrusted(prompt: false))")
    for display in Displays.all() {
        print("Display \(display.id) main=\(display.isMain) frame=\(display.frame) workArea=\(display.workArea)")
        print("  uuid=\(display.uuid) currentSpace=\(Displays.currentSpace(of: display))")
    }
    print("Spaces: \(Spaces.allSpaces())")
    let visible = Displays.onScreenWindowIDs()
    print("On-screen windows: \(visible.count)")
    if let first = visible.first {
        print("  window \(first) is on space \(Spaces.space(of: first).map(String.init) ?? "?")")
    }
    if AX.isTrusted(prompt: false) {
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let pid = Processes.pid(of: app) else { continue }
            let element = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(element, 1.0)
            for windowElement in AX.elements(element, kAXWindowsAttribute) {
                guard let id = AX.windowID(windowElement) else { continue }
                let window = ManagedWindow(id: id, element: windowElement, app: app, pid: pid, appElement: element)
                print(
                    "  [\(id)] \(window.appName) “\(window.title)” standard=\(window.isStandard) resizable=\(window.isResizable) frame=\(window.frame.map { "\($0)" } ?? "-") space=\(Spaces.space(of: id).map(String.init) ?? "?")"
                )
            }
        }
    }
    let settings = (try? Settings.load()) ?? Settings()
    for action in [Action.focusLeft, .tileEnter] {
        let combos = settings.combos(for: action)
        let codes = combos.map { "\($0)=\(KeyCodes.code(for: $0.key).map(String.init) ?? "?")" }
        print("\(action.rawValue): \(codes.joined(separator: ", "))")
    }
}

if CommandLine.arguments.contains("--version") {
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development build"
    print("Pop Mac \(version)")
    exit(0)
}

let app = NSApplication.shared
if CommandLine.arguments.contains("--diagnose") {
    MainActor.assumeIsolated { diagnose() }
    exit(0)
}

let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
