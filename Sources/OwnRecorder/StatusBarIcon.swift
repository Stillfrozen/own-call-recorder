import AppKit

/// Menu-bar glyph + optional status dot.
///
/// Template images ignore `contentTintColor` in the status bar, so busy states
/// bake color into a non-template `NSImage`. Idle without a badge stays template
/// so it follows light/dark menu bar automatically.
enum StatusBarIcon {
    private static let canvas = NSSize(width: 18, height: 18)

    static func image(
        symbol: String,
        glyphColor: NSColor?,
        dot: NSColor?,
        appearance: NSAppearance
    ) -> NSImage {
        if glyphColor == nil, dot == nil {
            return templateSymbol(symbol, pointSize: 15)
        }

        let image = NSImage(size: canvas, flipped: false) { rect in
            appearance.performAsCurrentDrawingAppearance {
                let color = glyphColor ?? menuBarForeground(appearance)
                drawSymbol(symbol, color: color, in: rect, reservedForDot: dot != nil)
                if let dot {
                    drawDot(dot, in: rect)
                }
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Own Recorder"
        return image
    }

    private static func templateSymbol(_ symbol: String, pointSize: CGFloat) -> NSImage {
        let base = NSImage(systemSymbolName: symbol, accessibilityDescription: "Own Recorder")
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        let image = base?.withSymbolConfiguration(config) ?? base ?? NSImage(size: canvas)
        image.isTemplate = true
        return image
    }

    private static func menuBarForeground(_ appearance: NSAppearance) -> NSColor {
        let match = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight])
        let dark = match == .darkAqua || match == .vibrantDark
        return dark ? NSColor.white.withAlphaComponent(0.92) : NSColor.black.withAlphaComponent(0.85)
    }

    private static func drawSymbol(_ name: String, color: NSColor, in rect: NSRect, reservedForDot: Bool) {
        let pointSize: CGFloat = reservedForDot ? 13 : 14
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        else { return }
        symbol.isTemplate = false

        var glyphRect = rect
        if reservedForDot {
            glyphRect.origin.x += 0.5
            glyphRect.size.width -= 3.5
            glyphRect.origin.y += 1.5
            glyphRect.size.height -= 1.5
        }
        let fitted = aspectFit(symbol.size, in: glyphRect)
        symbol.draw(in: fitted, from: .zero, operation: .sourceOver, fraction: 1)
    }

    private static func drawDot(_ color: NSColor, in rect: NSRect) {
        let diameter: CGFloat = 5.5
        let box = NSRect(
            x: rect.maxX - diameter - 0.4,
            y: 0.4,
            width: diameter,
            height: diameter
        )
        NSColor.black.withAlphaComponent(0.4).setFill()
        NSBezierPath(ovalIn: box.insetBy(dx: -0.8, dy: -0.8)).fill()
        NSColor.white.withAlphaComponent(0.95).setFill()
        NSBezierPath(ovalIn: box.insetBy(dx: -0.35, dy: -0.35)).fill()
        color.setFill()
        NSBezierPath(ovalIn: box).fill()
    }

    private static func aspectFit(_ size: NSSize, in bounds: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let w = size.width * scale
        let h = size.height * scale
        return NSRect(
            x: bounds.midX - w / 2,
            y: bounds.midY - h / 2,
            width: w,
            height: h
        )
    }
}
