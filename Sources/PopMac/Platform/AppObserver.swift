import AppKit
import ApplicationServices

/// Accessibility events that the window manager reacts to.
enum AXEvent {
    case windowCreated(AXUIElement)
    case windowDestroyed(AXUIElement)
    case focusedWindowChanged(AXUIElement)
    case windowMinimized(AXUIElement)
    case windowDeminimized(AXUIElement)
    case windowMoved(AXUIElement)
    case windowResized(AXUIElement)
    case titleChanged(AXUIElement)
    case appHidden
    case appShown

    /// The window that the event is about, unless the event is about the whole app.
    var window: AXUIElement? {
        switch self {
        case let .windowCreated(element), let .windowDestroyed(element), let .focusedWindowChanged(element),
             let .windowMinimized(element), let .windowDeminimized(element), let .windowMoved(element),
             let .windowResized(element), let .titleChanged(element):
            element
        case .appHidden, .appShown:
            nil
        }
    }
}

/// Watches one application for window events.
final class AppObserver {
    let app: NSRunningApplication
    let pid: pid_t
    let element: AXUIElement
    private var observer: AXObserver?
    private let handler: (AppObserver, AXEvent) -> Void

    private static let appNotifications = [
        kAXWindowCreatedNotification,
        kAXFocusedWindowChangedNotification,
        kAXApplicationHiddenNotification,
        kAXApplicationShownNotification,
    ]

    private static let windowNotifications = [
        kAXUIElementDestroyedNotification,
        kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification,
        kAXWindowMovedNotification,
        kAXWindowResizedNotification,
        kAXTitleChangedNotification,
    ]

    init?(app: NSRunningApplication, pid: pid_t, handler: @escaping (AppObserver, AXEvent) -> Void) {
        self.app = app
        self.pid = pid
        element = AXUIElementCreateApplication(pid)
        self.handler = handler

        AXUIElementSetMessagingTimeout(element, 1.0)

        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let this = Unmanaged<AppObserver>.fromOpaque(refcon).takeUnretainedValue()
            this.dispatch(element, notification as String)
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else {
            return nil
        }
        self.observer = observer

        var registered = false
        for name in Self.appNotifications {
            let error = AXObserverAddNotification(observer, element, name as CFString, Unmanaged.passUnretained(self).toOpaque())
            registered = registered || error == .success
        }
        guard registered else { return nil }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    deinit {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
    }

    /// Subscribes to the events of one window.
    func watch(_ window: AXUIElement) {
        guard let observer else { return }
        for name in Self.windowNotifications {
            AXObserverAddNotification(observer, window, name as CFString, Unmanaged.passUnretained(self).toOpaque())
        }
    }

    /// The application's windows on the current Spaces.
    func windows() -> [AXUIElement] {
        AX.elements(element, kAXWindowsAttribute)
    }

    func focusedWindow() -> AXUIElement? {
        AX.element(element, kAXFocusedWindowAttribute)
    }

    private func dispatch(_ element: AXUIElement, _ notification: String) {
        // An event shows that the app is alive, even if its last call got no answer.
        AX.heard(from: pid)
        let event: AXEvent
        switch notification {
        case kAXWindowCreatedNotification: event = .windowCreated(element)
        case kAXUIElementDestroyedNotification: event = .windowDestroyed(element)
        case kAXFocusedWindowChangedNotification: event = .focusedWindowChanged(element)
        case kAXWindowMiniaturizedNotification: event = .windowMinimized(element)
        case kAXWindowDeminiaturizedNotification: event = .windowDeminimized(element)
        case kAXWindowMovedNotification: event = .windowMoved(element)
        case kAXWindowResizedNotification: event = .windowResized(element)
        case kAXTitleChangedNotification: event = .titleChanged(element)
        case kAXApplicationHiddenNotification: event = .appHidden
        case kAXApplicationShownNotification: event = .appShown
        default: return
        }
        handler(self, event)
    }
}
