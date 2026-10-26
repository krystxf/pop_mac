// Draws the app icon and writes Resources/AppIcon.icns.
//
// Run from the repository root: swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ hex: UInt32) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: 1
    )
}

/// Draws the icon at `size` pixels: a rounded square with three tiles.
func draw(size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let s = CGFloat(size)
    // macOS icons leave a margin around the rounded square.
    let body = NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
    let shape = NSBezierPath(roundedRect: body, xRadius: s * 0.18, yRadius: s * 0.18)

    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.01)
    shadow.shadowBlurRadius = s * 0.025
    shadow.set()
    color(0xF08C3C).setFill()
    shape.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    NSGradient(starting: color(0xFBB86C), ending: color(0xEE7A35))!.draw(in: shape, angle: -90)

    // Three tiles: a tall one on the left, two stacked on the right.
    let inset = s * 0.2, gap = s * 0.045, radius = s * 0.05
    let area = body.insetBy(dx: inset - s * 0.1, dy: inset - s * 0.1)
    let half = (area.width - gap) / 2
    let tiles = [
        NSRect(x: area.minX, y: area.minY, width: half, height: area.height),
        NSRect(x: area.minX + half + gap, y: area.minY + (area.height + gap) / 2, width: half, height: (area.height - gap) / 2),
        NSRect(x: area.minX + half + gap, y: area.minY, width: half, height: (area.height - gap) / 2),
    ]
    for (index, tile) in tiles.enumerated() {
        NSColor.white.withAlphaComponent(index == 0 ? 0.97 : 0.82).setFill()
        NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let data = draw(size: base * scale).representation(using: .png, properties: [:])!
        try data.write(to: iconset.appendingPathComponent(name))
    }
}

let output = root.appendingPathComponent("Resources/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(output.path)")
