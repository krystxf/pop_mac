import AppKit
import ApplicationServices
import PopCore

/// A top-level window of another application, reached through Accessibility.
final class ManagedWindow {
    let id: WindowID
    let element: AXUIElement
    let pid: pid_t
    let app: NSRunningApplication
    let appElement: AXUIElement

    init(id: WindowID, element: AXUIElement, app: NSRunningApplication, appElement: AXUIElement) {
        self.id = id
        self.element = element
        self.pid = app.processIdentifier
        self.app = app
        self.appElement = appElement
    }

    var appName: String { app.localizedName ?? "" }
    var bundleID: String { app.bundleIdentifier ?? "" }
    var title: String { AX.get(element, kAXTitleAttribute) ?? "" }
    var subrole: String? { AX.get(element, kAXSubroleAttribute) }
    var role: String? { AX.get(element, kAXRoleAttribute) }
    var frame: Rect? { AX.frame(element) }
    var isMinimized: Bool { AX.get(element, kAXMinimizedAttribute) ?? false }
    var isFullscreen: Bool { AX.get(element, "AXFullScreen") ?? false }
    var isHidden: Bool { app.isHidden }
    var isResizable: Bool { AX.isSettable(element, kAXSizeAttribute) }

    /// True for normal document windows, as opposed to panels, sheets and dialogs.
    var isStandard: Bool {
        role == kAXWindowRole && subrole == kAXStandardWindowSubrole
    }

    /// True while the window still exists.
    var isAlive: Bool {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value)
        return error != .invalidUIElement && !app.isTerminated
    }

    /// Moves and resizes the window.
    ///
    /// The size is set twice, because macOS clamps a window to its current display
    /// while it moves.
    func setFrame(_ rect: Rect) {
        let enhanced: Bool = AX.get(appElement, "AXEnhancedUserInterface") ?? false
        if enhanced { AX.set(appElement, "AXEnhancedUserInterface", kCFBooleanFalse) }
        defer { if enhanced { AX.set(appElement, "AXEnhancedUserInterface", kCFBooleanTrue) } }

        let size = CGSize(width: rect.width, height: rect.height)
        AX.setSize(element, size)
        AX.setPosition(element, CGPoint(x: rect.x, y: rect.y))
        AX.setSize(element, size)
    }

    /// Raises the window and gives it keyboard focus.
    func focus() {
        AX.set(appElement, kAXFrontmostAttribute, kCFBooleanTrue)
        AX.set(element, kAXMainAttribute, kCFBooleanTrue)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        app.activate(options: [])
    }

    /// Raises the window above its application's other windows, without focus.
    func raise() {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }

    func minimize() {
        AX.set(element, kAXMinimizedAttribute, kCFBooleanTrue)
    }

    func unminimize() {
        AX.set(element, kAXMinimizedAttribute, kCFBooleanFalse)
    }

    func close() {
        if let button = AX.element(element, kAXCloseButtonAttribute) {
            AXUIElementPerformAction(button, kAXPressAction as CFString)
        }
    }

    func describe() -> String {
        """
        Window(\(id)) {
          app: "\(appName)" (\(bundleID)),
          title: "\(title)",
          role: \(role ?? "-"), subrole: \(subrole ?? "-"),
          frame: \(frame.map { "\($0)" } ?? "-"),
          resizable: \(isResizable), minimized: \(isMinimized), fullscreen: \(isFullscreen)
        }
        """
    }
}
