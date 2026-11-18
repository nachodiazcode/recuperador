// Dibuja el ícono de Recuperador 3.0 (moradito: violeta profundo → orquídea + brillo cristal) en un .iconset.
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for (size, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let px = CGFloat(size * scale)
    let image = NSImage(size: NSSize(width: px, height: px), flipped: false) { rect in
        let inset = rect.insetBy(dx: px * 0.085, dy: px * 0.085)
        let radius = px * 0.215
        let path = NSBezierPath(roundedRect: inset, xRadius: radius, yRadius: radius)

        NSGraphicsContext.saveGraphicsState()
        path.addClip()

        // Degradado principal morado → violeta eléctrico → orquídea
        let bg = NSGradient(colorsAndLocations:
            (NSColor(red: 0.22, green: 0.06, blue: 0.52, alpha: 1), 0.0),
            (NSColor(red: 0.54, green: 0.16, blue: 0.92, alpha: 1), 0.52),
            (NSColor(red: 0.84, green: 0.26, blue: 0.95, alpha: 1), 1.0)
        )!
        bg.draw(in: inset, angle: -48)

        // Resplandor radial lavanda arriba a la izquierda
        let bloom = NSGradient(starting: NSColor(red: 0.96, green: 0.72, blue: 1.0, alpha: 0.42),
                               ending: NSColor(red: 0.75, green: 0.30, blue: 1.0, alpha: 0.0))!
        bloom.draw(fromCenter: NSPoint(x: inset.minX + inset.width * 0.25, y: inset.maxY - inset.height * 0.22),
                   radius: 0,
                   toCenter: NSPoint(x: inset.minX + inset.width * 0.25, y: inset.maxY - inset.height * 0.22),
                   radius: inset.width * 0.72,
                   options: [])

        // Aro orbital sutil en tamaños medianos y grandes
        if px >= 64 {
            let ringInset = inset.insetBy(dx: px * 0.11, dy: px * 0.11)
            let ring = NSBezierPath(ovalIn: ringInset)
            ring.lineWidth = max(1, px * 0.012)
            let dash: [CGFloat] = [px * 0.045, px * 0.032]
            ring.setLineDash(dash, count: 2, phase: 0)
            NSColor.white.withAlphaComponent(0.22).setStroke()
            ring.stroke()
        }

        // Borde interior tipo cristal
        let rim = NSBezierPath(roundedRect: inset.insetBy(dx: max(0.5, px * 0.008), dy: max(0.5, px * 0.008)),
                               xRadius: radius * 0.96, yRadius: radius * 0.96)
        rim.lineWidth = max(1, px * 0.016)
        NSColor.white.withAlphaComponent(0.28).setStroke()
        rim.stroke()

        NSGraphicsContext.restoreGraphicsState()

        // Símbolo central con sombra suave
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(red: 0.14, green: 0.02, blue: 0.34, alpha: 0.45)
        shadow.shadowBlurRadius = px * 0.05
        shadow.shadowOffset = NSSize(width: 0, height: -px * 0.02)

        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        let config = NSImage.SymbolConfiguration(pointSize: px * 0.41, weight: .bold)
            .applying(.init(paletteColors: [.white]))
        if let symbol = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) {
            let s = symbol.size
            symbol.draw(in: NSRect(x: (px - s.width) / 2, y: (px - s.height) / 2, width: s.width, height: s.height))
        }
        if px >= 64 {
            let spConfig = NSImage.SymbolConfiguration(pointSize: px * 0.13, weight: .bold)
                .applying(.init(paletteColors: [NSColor(red: 0.98, green: 0.86, blue: 1.0, alpha: 0.95)]))
            if let sp = NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil)?
                .withSymbolConfiguration(spConfig) {
                let s = sp.size
                sp.draw(in: NSRect(x: inset.maxX - px * 0.24 - s.width / 2,
                                   y: inset.maxY - px * 0.23 - s.height / 2,
                                   width: s.width, height: s.height))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        return true
    }
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name)"))
}
