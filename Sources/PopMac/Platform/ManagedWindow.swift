import AppKit
import ApplicationServices
import PopCore

/// A top-level window of another application, reached through Accessibility.
///
/// Reading an attribute is a call to the window's app, which waits for the app to answer.
/// The answers that say whether the window can tile are kept for a moment, because Pop Mac
/// asks for them often: for every window of a tree, many times a second during a drag.
/// An event from the window ends the moment early. While the app is silent, the last
/// answer stays good, so a window of an app that hangs keeps its tile.
final class ManagedWindow {
    let id: WindowID
    let element: AXUIElement
    let pid: pid_t
    let app: NSRunningApplication
    let appElement: AXUIElement

    /// How long an answer stays good without an event from the window.
    private static let answerLifetime: TimeInterval = 0.5
    /// The last answer for each attribute, with the time it came. Used on the main thread only.
    private var answers: [String: (value: Any?, time: TimeInterval)] = [:]
    /// A window's role never changes.
    private var knownRole: String?

    init(id: WindowID, element: AXUIElement, app: NSRunningApplication, pid: pid_t, appElement: AXUIElement) {
        self.id = id
        self.element = element
        self.pid = pid
        self.app = app
        self.appElement = appElement
    }

    var appName: String { app.localizedName ?? "" }
    var bundleID: String { app.bundleIdentifier ?? "" }
    var title: String { answer(kAXTitleAttribute) { AX.ask(element, kAXTitleAttribute) } ?? "" }
    var subrole: String? { answer(kAXSubroleAttribute) { AX.ask(element, kAXSubroleAttribute) } }
    var frame: Rect? { AX.frame(element) }
    var isMinimized: Bool { answer(kAXMinimizedAttribute) { AX.ask(element, kAXMinimizedAttribute) } ?? false }
    var isFullscreen: Bool { answer("AXFullScreen") { AX.ask(element, "AXFullScreen") } ?? false }
    var isHidden: Bool { app.isHidden }
    var isResizable: Bool { answer("resizable") { AX.askSettable(element, kAXSizeAttribute) } ?? false }

    var role: String? {
        if let knownRole { return knownRole }
        knownRole = AX.get(element, kAXRoleAttribute)
        return knownRole
    }

    /// True for normal document windows, as opposed to panels, sheets and dialogs.
    var isStandard: Bool {
        role == kAXWindowRole && subrole == kAXStandardWindowSubrole
    }

    /// Returns the answer for `key`: the kept one while it is good, or else a new one from `ask`.
    private func answer<T>(_ key: String, ask: () -> AX.Answer<T>) -> T? {
        let now = ProcessInfo.processInfo.systemUptime
        if let known = answers[key], now - known.time < Self.answerLifetime { return known.value as? T }
        switch ask() {
        case let .value(value):
            answers[key] = (value, now)
            return value
        case .none:
            answers[key] = (nil, now)
            return nil
        case .silent:
            return answers[key]?.value as? T
        }
    }

    /// Makes the next read of each attribute ask the app again, after an event that can change the answers.
    ///
    /// The old answers stay, for the case that the app is silent by then.
    func expireAnswers() {
        for key in answers.keys {
            answers[key]?.time = -.infinity
        }
    }

    /// Moves and resizes the window at once.
    func setFrame(_ rect: Rect) {
        let enhanced: Bool = AX.get(appElement, "AXEnhancedUserInterface") ?? false
        if enhanced { AX.set(appElement, "AXEnhancedUserInterface", kCFBooleanFalse) }
        defer { if enhanced { AX.set(appElement, "AXEnhancedUserInterface", kCFBooleanTrue) } }
        AX.setFrame(element, rect)
    }

    /// Moves the window without resizing it.
    func setPosition(_ point: Point) {
        AX.setPosition(element, CGPoint(x: point.x, y: point.y))
    }

    /// Raises the window and gives it keyboard focus.
    func focus() {
        // Raise first, so the application keeps this window as its key window.
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        AX.set(element, kAXMainAttribute, kCFBooleanTrue)
        AX.set(appElement, kAXFrontmostAttribute, kCFBooleanTrue)
        app.activate(options: [])
        // Some apps (Finder) focus another element when they activate. Raise again after that.
        let element = element
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
            AX.set(element, kAXMainAttribute, kCFBooleanTrue)
        }
    }

    func minimize() {
        AX.set(element, kAXMinimizedAttribute, kCFBooleanTrue)
        expireAnswers()
    }

    func close() {
        if let button = AX.element(element, kAXCloseButtonAttribute) {
            AXUIElementPerformAction(button, kAXPressAction as CFString)
        }
    }

    /// Everything about the window but its title, which can hold private data.
    func describe() -> String {
        """
        Window(\(id)) {
          app: "\(appName)" (\(bundleID)),
          role: \(role ?? "-"), subrole: \(subrole ?? "-"),
          frame: \(frame.map { "\($0)" } ?? "-"),
          resizable: \(isResizable), minimized: \(isMinimized), fullscreen: \(isFullscreen)
        }
        """
    }
}
