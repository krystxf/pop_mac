import ApplicationServices
import CoreGraphics
import Foundation

// Private macOS functions. Every window manager on macOS uses these, because
// the public API offers no way to get a window's number or its Space.

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

typealias CGSConnectionID = Int32

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSGetActiveSpace")
func CGSGetActiveSpace(_ cid: CGSConnectionID) -> UInt64

@_silgen_name("CGSCopySpacesForWindows")
func CGSCopySpacesForWindows(_ cid: CGSConnectionID, _ mask: Int32, _ windows: CFArray) -> Unmanaged<CFArray>?

@_silgen_name("CGSCopyManagedDisplaySpaces")
func CGSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> Unmanaged<CFArray>?

enum Spaces {
    private static let connection = CGSMainConnectionID()

    /// The Space that a window is on, if the window server knows.
    static func space(of window: CGWindowID) -> UInt64? {
        let ids = [NSNumber(value: window)] as CFArray
        guard let spaces = CGSCopySpacesForWindows(connection, 0x7, ids)?.takeRetainedValue() as? [NSNumber] else {
            return nil
        }
        return spaces.first?.uint64Value
    }

    /// The current Space of each display, keyed by the display UUID.
    ///
    /// When displays share Spaces, the key is "Main".
    static func currentSpaces() -> [String: UInt64] {
        guard let displays = CGSCopyManagedDisplaySpaces(connection)?.takeRetainedValue() as? [[String: Any]] else {
            return [:]
        }
        var result: [String: UInt64] = [:]
        for display in displays {
            guard let identifier = display["Display Identifier"] as? String,
                  let current = display["Current Space"] as? [String: Any],
                  let id = (current["id64"] as? NSNumber)?.uint64Value ?? (current["ManagedSpaceID"] as? NSNumber)?.uint64Value
            else { continue }
            result[identifier] = id
        }
        return result
    }

    /// The ordered Space ids of each display, keyed by the display UUID.
    static func allSpaces() -> [String: [UInt64]] {
        guard let displays = CGSCopyManagedDisplaySpaces(connection)?.takeRetainedValue() as? [[String: Any]] else {
            return [:]
        }
        var result: [String: [UInt64]] = [:]
        for display in displays {
            guard let identifier = display["Display Identifier"] as? String,
                  let spaces = display["Spaces"] as? [[String: Any]]
            else { continue }
            result[identifier] = spaces.compactMap { ($0["id64"] as? NSNumber)?.uint64Value }
        }
        return result
    }

    static var activeSpace: UInt64 { CGSGetActiveSpace(connection) }
}

/// Functions of the private SkyLight framework, looked up at run time.
///
/// They may disappear in a later macOS. Then the lookup returns nil, and Pop Mac still runs.
enum SkyLight {
    private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    static func function<T>(_ name: String, as _: T.Type) -> T? {
        guard let handle, let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: T.self)
    }
}

/// Window shapes, from the window server.
enum WindowShapes {
    private typealias QueryWindows = @convention(c) (CGSConnectionID, CFArray, Int32) -> Unmanaged<CFTypeRef>?
    private typealias CopyWindows = @convention(c) (CFTypeRef) -> Unmanaged<CFTypeRef>?
    private typealias Advance = @convention(c) (CFTypeRef) -> Bool
    private typealias GetRadii = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?

    private static let queryWindows = SkyLight.function("SLSWindowQueryWindows", as: QueryWindows.self)
    private static let copyWindows = SkyLight.function("SLSWindowQueryResultCopyWindows", as: CopyWindows.self)
    private static let advance = SkyLight.function("SLSWindowIteratorAdvance", as: Advance.self)
    private static let getRadii = SkyLight.function("SLSWindowIteratorGetResolvedCornerRadii", as: GetRadii.self)

    /// The largest corner radius of a window, in points, or nil if the window server does not tell.
    static func cornerRadius(of window: CGWindowID) -> Double? {
        guard let queryWindows, let copyWindows, let advance, let getRadii,
              let query = queryWindows(CGSMainConnectionID(), [NSNumber(value: window)] as CFArray, 0)?.takeRetainedValue(),
              let iterator = copyWindows(query)?.takeRetainedValue(), advance(iterator),
              let radii = getRadii(iterator)?.takeRetainedValue() as? [Double]
        else { return nil }
        return radii.max()
    }
}

/// Tells when a window changes its place in the stacking order, for example when its app raises it.
///
/// The window server only reports the windows that `watch` names.
/// The handler runs on the main thread.
@MainActor
enum WindowReorders {
    private typealias Handler = @convention(c) (UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?) -> Void
    private typealias Register = @convention(c) (Handler, UInt32, UnsafeMutableRawPointer?) -> CGError
    private typealias Request = @convention(c) (CGSConnectionID, UnsafePointer<CGWindowID>?, Int32) -> CGError

    private static let reorderEvent: UInt32 = 808
    private static let register = SkyLight.function("SLSRegisterNotifyProc", as: Register.self)
    private static let request = SkyLight.function("SLSRequestNotificationsForWindows", as: Request.self)
    private static var onReorder: ((CGWindowID) -> Void)?

    /// Calls `handler` with each watched window that changes its place.
    static func observe(_ handler: @escaping (CGWindowID) -> Void) {
        guard onReorder == nil, let register else { return }
        onReorder = handler
        let callback: Handler = { _, data, length, _ in
            guard let data, length >= MemoryLayout<CGWindowID>.size else { return }
            let window = data.loadUnaligned(as: CGWindowID.self)
            MainActor.assumeIsolated { WindowReorders.onReorder?(window) }
        }
        if register(callback, reorderEvent, nil) != .success {
            Log.warn("could not observe window order changes")
        }
    }

    /// Replaces the watched windows.
    static func watch(_ windows: [CGWindowID]) {
        guard let request else { return }
        _ = windows.withUnsafeBufferPointer { request(CGSMainConnectionID(), $0.baseAddress, Int32($0.count)) }
    }
}
