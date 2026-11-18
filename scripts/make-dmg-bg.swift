// Genera el fondo Retina (640x420 pt @2x) del instalador DMG de Recuperador 3.0 en estilo moradito.
import AppKit

let out = CommandLine.arguments[1]
let version = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "3.2.1"
let w: CGFloat = 640
let h: CGFloat = 420
let scale: CGFloat = 2

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(w * scale),
    pixelsHigh: Int(h * scale),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!
rep.size = NSSize(width: w, height: h)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let rect = NSRect(x: 0, y: 0, width: w, height: h)

// Fondo morado nocturno aterciopelado
let bg = NSGradient(colorsAndLocations:
    (NSColor(red: 0.08, green: 0.04, blue: 0.16, alpha: 1), 0.0),
    (NSColor(red: 0.15, green: 0.07, blue: 0.29, alpha: 1), 0.55),
    (NSColor(red: 0.22, green: 0.09, blue: 0.38, alpha: 1), 1.0)
)!
bg.draw(in: rect, angle: -35)

// Halos radiales violeta / orquídea
let glowLeft = NSGradient(
    starting: NSColor(red: 0.62, green: 0.24, blue: 0.98, alpha: 0.36),
    ending: NSColor(red: 0.62, green: 0.24, blue: 0.98, alpha: 0.0)
)!
glowLeft.draw(fromCenter: NSPoint(x: 180, y: 205), radius: 0, toCenter: NSPoint(x: 180, y: 205), radius: 210, options: [])

let glowRight = NSGradient(
    starting: NSColor(red: 0.88, green: 0.30, blue: 0.96, alpha: 0.28),
    ending: NSColor(red: 0.88, green: 0.30, blue: 0.96, alpha: 0.0)
)!
glowRight.draw(fromCenter: NSPoint(x: 460, y: 205), radius: 0, toCenter: NSPoint(x: 460, y: 205), radius: 200, options: [])

// Tarjetas guía suaves detrás de los dos íconos (x=180 y x=460, centro en y=200 desde abajo = 220 desde arriba)
for cx in [CGFloat(180), CGFloat(460)] {
    let box = NSRect(x: cx - 72, y: 124, width: 144, height: 152)
    let card = NSBezierPath(roundedRect: box, xRadius: 24, yRadius: 24)
    NSColor.white.withAlphaComponent(0.055).setFill()
    card.fill()
    card.lineWidth = 1.2
    NSColor(red: 0.82, green: 0.56, blue: 1.0, alpha: 0.25).setStroke()
    card.stroke()
}

// Flecha luminosa central (de izquierda a derecha)
let arrowY: CGFloat = 204
let shaft = NSBezierPath()
shaft.move(to: NSPoint(x: 278, y: arrowY))
shaft.line(to: NSPoint(x: 356, y: arrowY))
shaft.lineWidth = 4.5
shaft.lineCapStyle = .round
NSColor(red: 0.84, green: 0.52, blue: 1.0, alpha: 0.92).setStroke()
shaft.stroke()

let head = NSBezierPath()
head.move(to: NSPoint(x: 344, y: arrowY + 13))
head.line(to: NSPoint(x: 362, y: arrowY))
head.line(to: NSPoint(x: 344, y: arrowY - 13))
head.lineWidth = 4.5
head.lineCapStyle = .round
head.lineJoinStyle = .round
head.stroke()

// Título superior
let para = NSMutableParagraphStyle()
para.alignment = .center

let titleAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 24, weight: .bold),
    .foregroundColor: NSColor.white,
    .paragraphStyle: para,
]
NSString(string: "Recuperador \(version)").draw(in: NSRect(x: 0, y: h - 66, width: w, height: 34), withAttributes: titleAttrs)

let subAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 13, weight: .medium),
    .foregroundColor: NSColor(red: 0.88, green: 0.76, blue: 1.0, alpha: 0.88),
    .paragraphStyle: para,
]
NSString(string: "Arrastra Recuperador a la carpeta Aplicaciones para instalarlo")
    .draw(in: NSRect(x: 0, y: 42, width: w, height: 24), withAttributes: subAttrs)

NSGraphicsContext.restoreGraphicsState()

let tiff = rep.tiffRepresentation!
try! tiff.write(to: URL(fileURLWithPath: out))
