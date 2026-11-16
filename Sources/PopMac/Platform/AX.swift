import AppKit
import ApplicationServices
import os
import PopCore

/// Small helpers around the Accessibility API.
///
/// Every call to an app goes through `call`, which skips apps that do not answer.
/// When such an app answers again, `onRecovery` runs, so the skipped work can be done.
enum AX {
    /// How long a call waits for an app.
    static let timeout: Float = 1

    /// What an app said about an attribute.
    enum Answer<T> {
        case value(T)
        /// The app answered, and the element has no such value.
        case none
        /// The app did not answer, or was not asked because it is stalled.
        case silent
    }

    /// The apps that do not answer. The animator's queues read from apps too, hence the lock.
    private static let stalls = OSAllocatedUnfairLock(initialState: AppStalls())

    /// Runs on the main thread when an app that did not answer does so again.
    @MainActor static var onRecovery: (@MainActor (pid_t) -> Void)?

    /// Makes every call wait at most `timeout`, also on elements that Pop Mac did not set up.
    ///
    /// Without this, a call on such an element waits 6 seconds for an app that hangs.
    static func setDefaultTimeout() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), timeout)
    }

    /// Runs a call to the element's app, and notes whether the app answered.
    ///
    /// While the app is stalled, the call does not run, and the result is `.cannotComplete`,
    /// as from a call that timed out.
    private static func call(_ element: AXUIElement, _ body: () -> AXError) -> AXError {
        var elementPID: pid_t = 0
        guard AXUIElementGetPid(element, &elementPID) == .success else { return body() }
        let pid = elementPID
        let start = ProcessInfo.processInfo.systemUptime
        let health = stalls.withLock { $0.beginCall(to: pid, at: start) }
        if health == .stalled { return .cannotComplete }

        let error = body()
        let end = ProcessInfo.processInfo.systemUptime
        // An app that is gone fails at once with the same error. Only a wait is a stall.
        if error == .cannotComplete, end - start >= Double(timeout) * 0.9 {
            let pause = stalls.withLock { $0.timedOut(pid, at: end) }
            Log.info("app \(pid) does not answer; not asking it for \(Int(pause)) s")
        } else if health == .retrying {
            heard(from: pid)
        }
        return error
    }

    /// Records that an app answered or sent an event, so calls to it run again.
    static func heard(from pid: pid_t) {
        guard stalls.withLock({ $0.answered(pid) }) else { return }
        Log.info("app \(pid) answers again")
        DispatchQueue.main.async { MainActor.assumeIsolated { onRecovery?(pid) } }
    }

    /// Reads an attribute, and tells an app that is silent from a missing value.
    static func ask<T>(_ element: AXUIElement, _ attribute: String) -> Answer<T> {
        var value: CFTypeRef?
        switch call(element, { AXUIElementCopyAttributeValue(element, attribute as CFString, &value) }) {
        case .success: return (value as? T).map(Answer.value) ?? .none
        case .cannotComplete: return .silent
        default: return .none
        }
    }

    /// Asks whether an attribute can be set.
    static func askSettable(_ element: AXUIElement, _ attribute: String) -> Answer<Bool> {
        var settable: DarwinBoolean = false
        switch call(element, { AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) }) {
        case .success: return .value(settable.boolValue)
        case .cannotComplete: return .silent
        default: return .none
        }
    }

    private static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard call(element, { AXUIElementCopyAttributeValue(element, attribute as CFString, &value) }) == .success else { return nil }
        return value
    }

    static func get<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        copy(element, attribute) as? T
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copy(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        guard let array = copy(element, attribute) as? [AnyObject] else { return [] }
        return array.compactMap { item in
            CFGetTypeID(item) == AXUIElementGetTypeID() ? (item as! AXUIElement) : nil
        }
    }

    @discardableResult
    static func set(_ element: AXUIElement, _ attribute: String, _ value: CFTypeRef) -> Bool {
        call(element) { AXUIElementSetAttributeValue(element, attribute as CFString, value) } == .success
    }

    /// Does what the element offers, such as a raise or a press.
    static func perform(_ element: AXUIElement, _ action: String) {
        _ = call(element) { AXUIElementPerformAction(element, action as CFString) }
    }

    static func windowID(_ element: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        return call(element) { _AXUIElementGetWindow(element, &id) } == .success && id != 0 ? id : nil
    }

    static func position(_ element: AXUIElement) -> CGPoint? {
        guard let value = copy(element, kAXPositionAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    static func size(_ element: AXUIElement) -> CGSize? {
        guard let value = copy(element, kAXSizeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }

    static func setPosition(_ element: AXUIElement, _ point: CGPoint) {
        var p = point
        if let value = AXValueCreate(.cgPoint, &p) {
            set(element, kAXPositionAttribute, value)
        }
    }

    static func setSize(_ element: AXUIElement, _ size: CGSize) {
        var s = size
        if let value = AXValueCreate(.cgSize, &s) {
            set(element, kAXSizeAttribute, value)
        }
    }

    /// Moves and resizes a window.
    ///
    /// The size is set twice, because macOS clamps a window to its current display
    /// while it moves.
    static func setFrame(_ element: AXUIElement, _ rect: Rect) {
        let size = CGSize(width: rect.width, height: rect.height)
        setSize(element, size)
        setPosition(element, CGPoint(x: rect.x, y: rect.y))
        setSize(element, size)
    }

    static func frame(_ element: AXUIElement) -> Rect? {
        guard let p = position(element), let s = size(element) else { return nil }
        return Rect(Double(p.x), Double(p.y), Double(s.width), Double(s.height))
    }

    static func isTrusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }
}
