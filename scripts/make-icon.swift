// Dibuja el ícono de la app (degradado + flecha de "deshacer") en todos los tamaños de un .iconset.
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for (size, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let px = CGFloat(size * scale)
    let image = NSImage(size: NSSize(width: px, height: px), flipped: false) { rect in
        let inset = rect.insetBy(dx: px * 0.09, dy: px * 0.09)
        let path = NSBezierPath(roundedRect: inset, xRadius: px * 0.2, yRadius: px * 0.2)
        NSGradient(colors: [NSColor(red: 0.36, green: 0.42, blue: 1, alpha: 1),
                            NSColor(red: 0.62, green: 0.30, blue: 0.95, alpha: 1)])!.draw(in: path, angle: -45)
        let config = NSImage.SymbolConfiguration(pointSize: px * 0.42, weight: .bold)
            .applying(.init(paletteColors: [.white]))
        if let symbol = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) {
            let s = symbol.size
            symbol.draw(in: NSRect(x: (px - s.width) / 2, y: (px - s.height) / 2, width: s.width, height: s.height))
        }
        return true
    }
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name)"))
}
