// Draws Headroom's app icon (the "Clean teal" capsule) at every size macOS
// needs, packs them into AppIcon.icns, and writes AppIcon.png for the README.
// Run from the repo root:
//
//   swift icon/make-icon.swift
//
// Coordinates are on Apple's 1024 grid: an 824 pt body with a 100 pt margin.
import AppKit

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func roundedRect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
    CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
}

// Fills `path` with a top-to-bottom gradient.
func fillVertical(_ ctx: CGContext, _ path: CGPath, _ stops: [(CGFloat, CGColor)]) {
    let box = path.boundingBox
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: box.minY), end: CGPoint(x: 0, y: box.maxY), options: [])
    ctx.restoreGState()
}

func render(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    let scale = CGFloat(pixels) / 1024
    // Top-down coordinates on the 1024 grid, like the design sketches.
    ctx.translateBy(x: 0, y: CGFloat(pixels))
    ctx.scaleBy(x: scale, y: -scale)

    let body = roundedRect(100, 100, 824, 824, 185)

    // Soft drop shadow under the body (offset is in pixels, y up).
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14 * scale), blur: 32 * scale, color: color(0x000000, 0.28))
    ctx.addPath(body)
    ctx.setFillColor(color(0x0c3d41))
    ctx.fillPath()
    ctx.restoreGState()

    fillVertical(ctx, body, [(0, color(0x145a5f)), (1, color(0x072326))])
    fillVertical(ctx, body, [(0, color(0xffffff, 0.22)), (0.5, color(0xffffff, 0))])

    // The capsule, and the level sitting low inside it: the empty space is the headroom.
    let capsule = roundedRect(382, 224, 260, 576, 130)
    ctx.addPath(capsule)
    ctx.setFillColor(color(0xffffff, 0.07))
    ctx.fillPath()
    ctx.addPath(capsule)
    ctx.setStrokeColor(color(0xffffff, 0.8))
    ctx.setLineWidth(24)
    ctx.strokePath()

    fillVertical(ctx, roundedRect(418, 530, 188, 234, 94), [(0, color(0x9bf9d6)), (1, color(0x2fbf8c))])
    return rep
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon")
let iconset = root.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
    for (scale, suffix) in [(1, ""), (2, "@2x")] {
        let png = render(pixels: points * scale).representation(using: .png, properties: [:])!
        try! png.write(to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}

// A standalone PNG for the README.
try! render(pixels: 256).representation(using: .png, properties: [:])!
    .write(to: root.appendingPathComponent("AppIcon.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("AppIcon.icns").path]
try! iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print("Wrote \(root.path)/AppIcon.icns")
