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
