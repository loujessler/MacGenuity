import AppKit
import Foundation

let outputURL = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.icns")
let workURL = outputURL
    .deletingLastPathComponent()
    .appendingPathComponent("AppIcon.iconset", isDirectory: true)

try? FileManager.default.removeItem(at: workURL)
try FileManager.default.createDirectory(at: workURL, withIntermediateDirectories: true)

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for item in sizes {
    let image = NSImage(size: NSSize(width: item.pixels, height: item.pixels))
    image.lockFocus()
    drawIcon(in: NSRect(x: 0, y: 0, width: item.pixels, height: item.pixels),
             scale: CGFloat(item.pixels) / 1024)
    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let data = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Failed to render \(item.name)")
    }
    try data.write(to: workURL.appendingPathComponent(item.name))
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", workURL.path, "-o", outputURL.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
    fatalError("iconutil failed with status \(process.terminationStatus)")
}

try? FileManager.default.removeItem(at: workURL)

// MARK: - Drawing
//
// All design coordinates are in a 1024×1024 logical space; `scale` maps
// them to the actual rendering size of each icon variant.

let dimRed     = NSColor(calibratedRed: 0.32, green: 0.06, blue: 0.06, alpha: 1.0)
let deepRed    = NSColor(calibratedRed: 0.55, green: 0.10, blue: 0.10, alpha: 1.0)
let red        = NSColor(calibratedRed: 0.85, green: 0.18, blue: 0.16, alpha: 1.0)
let brightRed  = NSColor(calibratedRed: 1.00, green: 0.30, blue: 0.24, alpha: 1.0)
let pink       = NSColor(calibratedRed: 1.00, green: 0.78, blue: 0.74, alpha: 1.0)
let almostWhite = NSColor(calibratedRed: 1.00, green: 0.96, blue: 0.94, alpha: 1.0)

struct Bar {
    let offset: CGFloat       // perpendicular distance from group axis
    let along: CGFloat        // shift along the group axis (asymmetry)
    let length: CGFloat
    let thickness: CGFloat
    let color: NSColor
}

func drawIcon(in rect: NSRect, scale: CGFloat) {
    // Apple icon shape: squircle with safe-area inset.
    let inset: CGFloat = 64 * scale
    let radius: CGFloat = 224 * scale
    let bounds = rect.insetBy(dx: inset, dy: inset)
    let backgroundPath = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)

    // 1. Dark, slightly warm base.
    NSGraphicsContext.saveGraphicsState()
    backgroundPath.addClip()
    NSColor(calibratedRed: 0.04, green: 0.03, blue: 0.035, alpha: 1).setFill()
    bounds.fill()

    // 2. Radial red glow centred on the X — gives the icon its signature
    //    "neon-on-black" feel without overpowering the artwork.
    let center = NSPoint(x: rect.midX, y: rect.midY)
    let glow = NSGradient(colors: [
        NSColor(calibratedRed: 0.55, green: 0.05, blue: 0.05, alpha: 0.85),
        NSColor(calibratedRed: 0.40, green: 0.03, blue: 0.03, alpha: 0.45),
        NSColor(calibratedRed: 0.10, green: 0.02, blue: 0.02, alpha: 0.18),
        NSColor.black.withAlphaComponent(0.0)
    ], atLocations: [0.0, 0.35, 0.7, 1.0], colorSpace: .deviceRGB)
    glow?.draw(fromCenter: center, radius: 0,
               toCenter: center, radius: 480 * scale,
               options: [])

    // 3. The X itself: two crossing groups of parallel diagonal bars.
    //    Group A is drawn first (slightly behind), B on top — together
    //    they read as a single X with depth.
    drawStripeGroup(bars: groupA(), center: center,
                    angleRadians: .pi * -0.25, scale: scale)
    drawStripeGroup(bars: groupB(), center: center,
                    angleRadians: .pi *  0.25, scale: scale)

    NSGraphicsContext.restoreGraphicsState()

    // 4. Hairline edge so the icon reads against light wallpapers in the
    //    Dock without looking flat.
    NSColor(calibratedWhite: 1, alpha: 0.05).setStroke()
    backgroundPath.lineWidth = 4 * scale
    backgroundPath.stroke()
}

/// Bars going from upper-left to lower-right (back layer — mostly red).
func groupA() -> [Bar] {
    [
        Bar(offset: -150, along:  -8, length: 220, thickness: 28, color: dimRed),
        Bar(offset: -100, along:  20, length: 290, thickness: 32, color: deepRed),
        Bar(offset:  -50, along: -20, length: 360, thickness: 36, color: red),
        Bar(offset:    0, along:  10, length: 400, thickness: 40, color: brightRed),
        Bar(offset:   55, along: -15, length: 360, thickness: 36, color: red),
        Bar(offset:  110, along:  18, length: 290, thickness: 32, color: deepRed),
        Bar(offset:  160, along:   0, length: 220, thickness: 28, color: dimRed),
    ]
}

/// Bars going from upper-right to lower-left (front layer — has the
/// bright white / pink highlights).
func groupB() -> [Bar] {
    [
        Bar(offset: -160, along:  10, length: 230, thickness: 28, color: dimRed),
        Bar(offset: -110, along: -16, length: 310, thickness: 32, color: deepRed),
        Bar(offset:  -55, along:  18, length: 380, thickness: 36, color: red),
        Bar(offset:    0, along: -10, length: 410, thickness: 40, color: almostWhite),
        Bar(offset:   55, along:  16, length: 360, thickness: 36, color: pink),
        Bar(offset:  110, along: -12, length: 300, thickness: 32, color: red),
        Bar(offset:  160, along:   0, length: 220, thickness: 28, color: deepRed),
    ]
}

/// Renders a parallel-bar group rotated `angleRadians` around `center`.
/// Each `Bar.offset` shifts a bar perpendicular to the axis; `along`
/// shifts its midpoint along the axis to add organic asymmetry.
func drawStripeGroup(bars: [Bar], center: NSPoint, angleRadians: CGFloat, scale: CGFloat) {
    let cosA = cos(angleRadians)
    let sinA = sin(angleRadians)

    for bar in bars {
        // Perpendicular vector: (-sinA, cosA)
        let perpX = -sinA * bar.offset * scale
        let perpY =  cosA * bar.offset * scale
        // Along-axis vector: (cosA, sinA)
        let alongX = cosA * bar.along * scale
        let alongY = sinA * bar.along * scale

        let cx = center.x + perpX + alongX
        let cy = center.y + perpY + alongY

        let half = bar.length * scale * 0.5
        let p1 = NSPoint(x: cx - cosA * half, y: cy - sinA * half)
        let p2 = NSPoint(x: cx + cosA * half, y: cy + sinA * half)

        let path = NSBezierPath()
        path.move(to: p1)
        path.line(to: p2)
        path.lineWidth = bar.thickness * scale
        path.lineCapStyle = .round
        bar.color.setStroke()
        path.stroke()
    }
}
