//
//  HyperXMark.swift
//  MacGenuity
//
//  Monochrome HyperX-style mark used as the menu-bar icon: a small
//  capital "H" followed by a stylised "X". Drawn into a template
//  NSImage so the system tints it for the active menu-bar appearance
//  (white on dark, black on light) without us shipping pre-baked PNGs.
//
//  Why an NSImage and not SwiftUI shapes:
//    `MenuBarExtra(label:)` reliably renders only `Image` / `Text`.
//    Custom SwiftUI shapes collapse to zero size in the menu-bar slot —
//    a template NSImage is the macOS-native pattern for this surface.
//

import SwiftUI
import AppKit

struct HyperXMark: View {
    var body: some View {
        Image(nsImage: Self.markImage)
    }

    /// Pre-resolved once per process. Order of preference:
    ///   1. `MenuBarIcon.pdf`   — vector, retinable at any scale (best)
    ///   2. `MenuBarIcon.png`   — fixed-size raster
    ///   3. Programmatic `render()` fallback — used when the user hasn't
    ///      dropped a custom icon into Resources/ yet, so the app never
    ///      ships without a tray glyph.
    ///
    /// Whatever loads is flagged as a template image, so the system
    /// tints it for the active menu-bar appearance automatically.
    private static let markImage: NSImage = loadOrRender()

    private static func loadOrRender() -> NSImage {
        let log = FileLogger.shared
        for ext in ["pdf", "png"] {
            guard let url = Bundle.main.url(forResource: "MenuBarIcon",
                                            withExtension: ext)
            else { continue }
            guard let source = NSImage(contentsOf: url),
                  source.size.width > 0, source.size.height > 0 else {
                log.warning(.app, "menu-bar icon: failed to load \(url.lastPathComponent)")
                continue
            }

            // Re-render the artwork into a bitmap NSImage sized to the
            // menu-bar slot. We can't just set `.size` on the loaded
            // image — PDF-backed NSImages keep their original page
            // dimensions in the underlying NSImageRep, and SwiftUI's
            // MenuBarExtra has been observed to use the rep size for
            // layout even after `.size` is changed. Rendering into a
            // fresh bitmap sidesteps that entire class of bugs.
            let targetHeight: CGFloat = 22
            let aspect = source.size.width / source.size.height
            let targetSize = NSSize(width: max(targetHeight * aspect, 12),
                                    height: targetHeight)

            let baked = NSImage(size: targetSize, flipped: false) { rect in
                source.draw(in: rect,
                            from: .zero,
                            operation: .sourceOver,
                            fraction: 1.0)
                return true
            }
            baked.isTemplate = true
            log.info(.app, "menu-bar icon: \(url.lastPathComponent) natural=\(source.size) baked=\(targetSize)")
            return baked
        }
        log.info(.app, "menu-bar icon: using programmatic fallback")
        return render()
    }

    private static func render() -> NSImage {
        // Wider than tall so both glyphs fit at menu-bar height (~18 pt)
        // without crowding. macOS scales the image into the menu-bar
        // slot, preserving aspect.
        let width: CGFloat = 22
        let height: CGFloat = 18
        let image = NSImage(size: NSSize(width: width, height: height),
                            flipped: false) { rect in
            NSColor.black.setStroke()   // template ink — retinted by system

            // Unified stroke weight — keeps the two glyphs visually
            // balanced at small sizes. ~10 % of width reads cleanly
            // both retinted bright white (open menu) and retinted black
            // (light menu bar).
            let stroke = rect.width * 0.10

            // ═════════════ H (left) ═════════════
            // Compact upper-case H. Verticals roughly half the canvas
            // height, crossbar at the optical middle.
            let hLX = rect.width * 0.08
            let hRX = rect.width * 0.26
            let hTopY = rect.height * 0.82
            let hBotY = rect.height * 0.18
            let hMidY = rect.height * 0.50

            for x in [hLX, hRX] {
                let path = NSBezierPath()
                path.move(to: NSPoint(x: x, y: hBotY))
                path.line(to: NSPoint(x: x, y: hTopY))
                path.lineWidth = stroke
                path.lineCapStyle = .round
                path.stroke()
            }
            let crossbar = NSBezierPath()
            crossbar.move(to: NSPoint(x: hLX, y: hMidY))
            crossbar.line(to: NSPoint(x: hRX, y: hMidY))
            crossbar.lineWidth = stroke
            crossbar.lineCapStyle = .round
            crossbar.stroke()

            // ═════════════ X (right) ═════════════
            // Slightly outboard from the H to give a visual gap and let
            // each glyph breathe. Arm length tuned so the X reads as
            // the dominant glyph (matches the HyperX wordmark, where
            // the X visually outweighs the H).
            let xCenter = NSPoint(x: rect.width * 0.68,
                                  y: rect.height * 0.50)
            let arm = rect.width * 0.24

            for angle in [CGFloat.pi / 4, -CGFloat.pi / 4] {
                let dx = arm * cos(angle)
                let dy = arm * sin(angle)
                let path = NSBezierPath()
                path.move(to: NSPoint(x: xCenter.x - dx,
                                      y: xCenter.y - dy))
                path.line(to: NSPoint(x: xCenter.x + dx,
                                      y: xCenter.y + dy))
                path.lineWidth = stroke
                path.lineCapStyle = .round
                path.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
