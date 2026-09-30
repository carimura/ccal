// Draws the CCal app icon and writes every size macOS needs into the asset catalog.
// Usage: swift scripts/make-icon.swift   (from the repo root)
import AppKit

let output = "CCal/Assets.xcassets/AppIcon.appiconset"

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

/// Draws on a 1024×1024 canvas (y up), scaled to `size`.
func render(_ size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = CGFloat(size) / 1024
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()

    // macOS icon grid: 824pt rounded square centered on the 1024 canvas, with a soft drop shadow.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    color(0x3A2FB8).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(0x6A7BFF), ending: color(0x3326A8))!.draw(in: shape, angle: -90)

    // Mini month grid under a header strip, centered in the body with even margins.
    let columns = 5, rows = 4
    let margin: CGFloat = 78, gap: CGFloat = 24, headerHeight: CGFloat = 56, headerGap: CGFloat = 36
    let inset = body.minX + margin
    let tile = (body.width - 2 * margin - CGFloat(columns - 1) * gap) / CGFloat(columns)
    let contentHeight = headerHeight + headerGap + CGFloat(rows) * tile + CGFloat(rows - 1) * gap
    let contentTop = body.midY + contentHeight / 2
    let gridTop = contentTop - headerHeight - headerGap
    func tileRect(_ column: Int, _ row: Int) -> NSRect {
        NSRect(x: inset + CGFloat(column) * (tile + gap), y: gridTop - tile - CGFloat(row) * (tile + gap), width: tile, height: tile)
    }
    for row in 0..<rows {
        for column in 0..<columns {
            let today = row == 2 && column == 3
            (today ? color(0xFFD35C) : NSColor.white.withAlphaComponent(0.22)).setFill()
            NSBezierPath(roundedRect: tileRect(column, row), xRadius: 22, yRadius: 22).fill()
        }
    }

    // Header strip above the grid (the "month" bar).
    let header = NSRect(x: inset, y: contentTop - headerHeight, width: body.width - 2 * margin, height: headerHeight)
    NSColor.white.withAlphaComponent(0.92).setFill()
    NSBezierPath(roundedRect: header, xRadius: headerHeight / 2, yRadius: headerHeight / 2).fill()

    // A multi-day event bar across row 1, and a short one in row 3.
    func bar(row: Int, from: Int, through: Int, _ fill: NSColor) {
        let a = tileRect(from, row), b = tileRect(through, row)
        let rect = NSRect(x: a.minX + 10, y: a.midY - 24, width: b.maxX - a.minX - 20, height: 48)
        fill.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 24, yRadius: 24).fill()
    }
    bar(row: 1, from: 1, through: 4, color(0xFF7A59))
    bar(row: 3, from: 0, through: 1, color(0x3DDC97))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [String] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try! render(points * scale).write(to: URL(fileURLWithPath: "\(output)/\(name)"))
        images.append("""
            { "idiom" : "mac", "size" : "\(points)x\(points)", "scale" : "\(scale)x", "filename" : "\(name)" }
        """)
    }
}
let contents = "{\n  \"images\" : [\n\(images.joined(separator: ",\n"))\n  ],\n  \"info\" : { \"version\" : 1, \"author\" : \"xcode\" }\n}\n"
try! contents.write(toFile: "\(output)/Contents.json", atomically: true, encoding: .utf8)
try! "{\n  \"info\" : { \"version\" : 1, \"author\" : \"xcode\" }\n}\n"
    .write(toFile: "CCal/Assets.xcassets/Contents.json", atomically: true, encoding: .utf8)
print("Wrote \(images.count) icon images to \(output)")
