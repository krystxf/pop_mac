import Carbon
import Foundation

/// Maps Pop Shell key names (GDK names) to macOS virtual key codes.
@MainActor
enum KeyCodes {
    private static let fixed: [String: Int] = [
        "Left": kVK_LeftArrow, "Right": kVK_RightArrow, "Up": kVK_UpArrow, "Down": kVK_DownArrow,
        "KP_Left": kVK_ANSI_Keypad4, "KP_Right": kVK_ANSI_Keypad6,
        "KP_Up": kVK_ANSI_Keypad8, "KP_Down": kVK_ANSI_Keypad2,
        "Return": kVK_Return, "KP_Enter": kVK_ANSI_KeypadEnter, "Escape": kVK_Escape,
        "space": kVK_Space, "Tab": kVK_Tab, "BackSpace": kVK_Delete, "Delete": kVK_ForwardDelete,
        "Home": kVK_Home, "End": kVK_End, "Page_Up": kVK_PageUp, "Page_Down": kVK_PageDown,
        "F1": kVK_F1, "F2": kVK_F2, "F3": kVK_F3, "F4": kVK_F4, "F5": kVK_F5, "F6": kVK_F6,
        "F7": kVK_F7, "F8": kVK_F8, "F9": kVK_F9, "F10": kVK_F10, "F11": kVK_F11, "F12": kVK_F12,
    ]

    /// Key codes on a US ANSI keyboard, used when the current layout lacks a character.
    private static let ansi: [String: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
        "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
        "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
        "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y,
        "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
        "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "/": kVK_ANSI_Slash, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period, "-": kVK_ANSI_Minus,
        "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket,
        ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote, "`": kVK_ANSI_Grave, "\\": kVK_ANSI_Backslash,
    ]

    private static let symbolNames: [String: String] = [
        "slash": "/", "comma": ",", "period": ".", "minus": "-", "equal": "=",
        "bracketleft": "[", "bracketright": "]", "semicolon": ";", "apostrophe": "'",
        "grave": "`", "backslash": "\\",
    ]

    private static var layoutMap: [String: Int] = buildLayoutMap()

    /// Rebuilds the character map after the keyboard layout changes.
    static func reloadLayout() {
        layoutMap = buildLayoutMap()
    }

    static func code(for name: String) -> UInt32? {
        if let code = fixed[name] { return UInt32(code) }
        let char = symbolNames[name] ?? name.lowercased()
        guard char.count == 1 else { return nil }
        if let code = layoutMap[char] ?? ansi[char] { return UInt32(code) }
        return nil
    }

    /// Finds which key types each character in the current keyboard layout.
    private static func buildLayoutMap() -> [String: Int] {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return [:] }

        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var map: [String: Int] = [:]

        data.withUnsafeBytes { raw in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            for code in 0 ..< 128 {
                var deadKeys: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0,
                    UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeys, chars.count, &length, &chars
                )
                guard status == noErr, length > 0 else { continue }
                let string = String(utf16CodeUnits: chars, count: length).lowercased()
                // Keep the first key for a character; the keypad repeats digits.
                if map[string] == nil { map[string] = code }
            }
        }
        return map
    }
}
