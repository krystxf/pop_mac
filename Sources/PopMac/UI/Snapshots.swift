import AppKit

/// Saves images of Pop Mac's own windows, for checking the UI during development.
///
/// An app can capture its own windows without the Screen Recording permission.
@MainActor
enum Snapshots {
    private typealias CreateImage = @convention(c) (CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption) -> Unmanaged<CGImage>?

    /// Writes a PNG of the window. Looked up at runtime, because the function is deprecated.
    @discardableResult
    static func save(_ window: NSWindow, to url: URL) -> Bool {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return false }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        // Capture exactly the window's frame; letting the window server pick the bounds
        // crops the wrong region for windows with the current design.
        let frame = Displays.toQuartz(window.frame)
        let rect = CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
        guard let image = create(rect, .optionIncludingWindow, CGWindowID(window.windowNumber), [.bestResolution])?.takeRetainedValue(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { return false }
        return (try? data.write(to: url)) != nil
    }
}
