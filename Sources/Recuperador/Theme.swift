import AppKit
import SwiftUI

enum ThemeChoice: String, CaseIterable, Identifiable {
    case system = "Recuperador"
    case amethyst = "Noche Morada"
    case ironMan = "Iron Man"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "Moradito"
        case .amethyst: return "Noche Morada"
        case .ironMan: return "Iron Man"
        }
    }

    var symbol: String {
        switch self {
        case .system: return "sparkles"
        case .amethyst: return "moon.stars.fill"
        case .ironMan: return "bolt.circle.fill"
        }
    }

    var forcesDark: Bool { self == .amethyst || self == .ironMan }
}

/// Colores del tema activo. RootView los fija y reconstruye la interfaz al cambiar de tema.
enum Palette {
    static var theme: ThemeChoice = .system

    static var accent: Color {
        switch theme {
        case .system: return Color(red: 0.56, green: 0.22, blue: 0.95)
        case .amethyst: return Color(red: 0.68, green: 0.36, blue: 0.99)
        case .ironMan: return Color(red: 0.86, green: 0.12, blue: 0.14)
        }
    }

    static var secondary: Color {
        switch theme {
        case .system: return Color(red: 0.84, green: 0.28, blue: 0.95)
        case .amethyst: return Color(red: 0.90, green: 0.42, blue: 0.97)
        case .ironMan: return Color(red: 0.98, green: 0.76, blue: 0.27)
        }
    }

    static var glow: Color {
        switch theme {
        case .system: return Color(red: 0.72, green: 0.34, blue: 0.99)
        case .amethyst: return Color(red: 0.80, green: 0.52, blue: 1.00)
        case .ironMan: return Color(red: 0.45, green: 0.95, blue: 1.0)
        }
    }

    static var mist: Color {
        switch theme {
        case .system: return Color(red: 0.76, green: 0.54, blue: 1.00)
        case .amethyst: return Color(red: 0.86, green: 0.68, blue: 1.00)
        case .ironMan: return Color(red: 0.45, green: 0.95, blue: 1.0)
        }
    }

    static var gradient: LinearGradient {
        LinearGradient(colors: [accent, glow, secondary], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static var subtleSurface: LinearGradient {
        LinearGradient(colors: [accent.opacity(0.14), secondary.opacity(0.07)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static var borderStroke: LinearGradient {
        LinearGradient(colors: [accent.opacity(0.55), secondary.opacity(0.32)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static var titleDesign: Font.Design { theme == .ironMan ? .monospaced : .rounded }
}

/// Fundido de la ventana entera hecho por Core Animation: toma lo que se ve ahora y lo funde con
/// lo nuevo en el servidor de render, fuera del hilo principal. Aunque la pantalla nueva tarde en
/// armarse, la animación no se traba (con un fundido de SwiftUI se redibujaban las dos pantallas
/// en cada cuadro). Hay que llamarlo justo antes del cambio.
@MainActor
enum Crossfade {
    static func next(_ duration: CFTimeInterval = 0.22) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let window = NSApp.keyWindow ?? NSApp.mainWindow, window.occlusionState.contains(.visible),
              let layer = window.contentView?.layer else { return }
        let fade = CATransition()
        fade.type = .fade
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "cambio")
    }
}

/// Fondo del tema: aurora morada suave animada por Core Animation (fuera del hilo principal) o
/// cuadrícula HUD en Iron Man. No consume CPU aunque haya cientos de miles de archivos.
struct ThemedBackground: View {
    var body: some View {
        ZStack {
            if Palette.theme == .amethyst {
                Color(red: 0.07, green: 0.04, blue: 0.13)
            }
            LinearGradient(
                colors: [
                    Palette.accent.opacity(Palette.theme == .amethyst ? 0.24 : 0.16),
                    Palette.secondary.opacity(Palette.theme == .amethyst ? 0.14 : 0.09),
                    Palette.mist.opacity(0.04),
                    .clear,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            if Palette.theme == .ironMan {
                HUDGrid(color: NSColor(Palette.secondary).withAlphaComponent(0.06))
            } else {
                AuroraOrbs(
                    primary: NSColor(Palette.accent).withAlphaComponent(Palette.theme == .amethyst ? 0.26 : 0.16),
                    secondary: NSColor(Palette.secondary).withAlphaComponent(Palette.theme == .amethyst ? 0.22 : 0.13)
                )
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// Dos halos radiales violeta/orquídea que respiran y flotan en el servidor de render (0 % de hilo principal).
private struct AuroraOrbs: NSViewRepresentable {
    let primary: NSColor
    let secondary: NSColor

    func makeNSView(context: Context) -> OrbHost {
        let v = OrbHost()
        v.configure(primary: primary, secondary: secondary)
        return v
    }

    func updateNSView(_ view: OrbHost, context: Context) {
        view.configure(primary: primary, secondary: secondary)
    }

    final class OrbHost: NSView {
        private let orbA = CAGradientLayer()
        private let orbB = CAGradientLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = true
            for orb in [orbA, orbB] {
                orb.type = .radial
                orb.startPoint = CGPoint(x: 0.5, y: 0.5)
                orb.endPoint = CGPoint(x: 1.0, y: 1.0)
                layer?.addSublayer(orb)
            }
        }

        required init?(coder: NSCoder) { fatalError() }

        func configure(primary: NSColor, secondary: NSColor) {
            orbA.colors = [primary.cgColor, primary.withAlphaComponent(0).cgColor]
            orbB.colors = [secondary.cgColor, secondary.withAlphaComponent(0).cgColor]
        }

        override func layout() {
            super.layout()
            let side = max(bounds.width, bounds.height) * 0.72
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            orbA.frame = CGRect(x: -side * 0.22, y: bounds.height - side * 0.68, width: side, height: side)
            orbB.frame = CGRect(x: bounds.width - side * 0.68, y: -side * 0.25, width: side * 0.92, height: side * 0.92)
            CATransaction.commit()
            animateIfNeeded()
        }

        private func animateIfNeeded() {
            guard orbA.animation(forKey: "flotarA") == nil,
                  !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }

            let moveA = CABasicAnimation(keyPath: "transform.translation")
            moveA.fromValue = NSValue(size: NSSize(width: 0, height: 0))
            moveA.toValue = NSValue(size: NSSize(width: 48, height: -32))
            moveA.duration = 9.5
            moveA.autoreverses = true
            moveA.repeatCount = .infinity
            moveA.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            orbA.add(moveA, forKey: "flotarA")

            let moveB = CABasicAnimation(keyPath: "transform.translation")
            moveB.fromValue = NSValue(size: NSSize(width: 0, height: 0))
            moveB.toValue = NSValue(size: NSSize(width: -42, height: 36))
            moveB.duration = 11.5
            moveB.autoreverses = true
            moveB.repeatCount = .infinity
            moveB.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            orbB.add(moveB, forKey: "flotarB")
        }
    }
}

private struct HUDGrid: NSViewRepresentable {
    let color: NSColor

    func makeNSView(context: Context) -> GridView {
        let view = GridView()
        view.color = color
        return view
    }

    func updateNSView(_ view: GridView, context: Context) {
        view.color = color
    }

    final class GridView: NSView {
        private let grid = CAShapeLayer()
        private let step: CGFloat = 46
        var color: NSColor = .clear { didSet { grid.strokeColor = color.cgColor } }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = true
            grid.fillColor = nil
            grid.lineWidth = 1
            layer?.addSublayer(grid)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            grid.frame = CGRect(x: -step, y: -step, width: bounds.width + step, height: bounds.height + step)
            let path = CGMutablePath()
            var x: CGFloat = 0
            while x <= grid.bounds.width { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: grid.bounds.height)); x += step }
            var y: CGFloat = 0
            while y <= grid.bounds.height { path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: grid.bounds.width, y: y)); y += step }
            grid.path = path
            CATransaction.commit()
            startDrift()
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            grid.strokeColor = color.cgColor
        }

        private func startDrift() {
            guard grid.animation(forKey: "deriva") == nil,
                  !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            let drift = CABasicAnimation(keyPath: "transform")
            drift.fromValue = CATransform3DIdentity
            drift.toValue = CATransform3DMakeTranslation(step, step, 0)
            drift.duration = 8
            drift.repeatCount = .infinity
            grid.add(drift, forKey: "deriva")
        }
    }
}

/// El ícono vivo de Recuperador 3.0: aro orbital lavanda, cristal morado y respuesta al puntero/clic.
struct AppBadge: View {
    var size: CGFloat
    @State private var spin = false
    @State private var pulse = false
    @State private var hover = false
    @State private var bounce = 0

    var body: some View {
        Group {
            if Palette.theme == .ironMan { reactor } else { amethystBadge }
        }
        .scaleEffect(hover ? 1.07 : 1)
        .rotation3DEffect(.degrees(hover ? 6 : 0), axis: (x: -1, y: 1, z: 0))
        .animation(.spring(response: 0.26, dampingFraction: 0.68), value: hover)
        .onHover { hover = $0 }
        .onTapGesture {
            bounce += 1
            Signals.play(.tap)
        }
        .onAppear {
            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            withAnimation(.linear(duration: 18).repeatForever(autoreverses: false)) { spin = true }
            withAnimation(.easeInOut(duration: 1.9).repeatForever()) { pulse = true }
        }
    }

    private var amethystBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(Palette.gradient)
            // Brillo especular superior
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(
                    RadialGradient(
                        colors: [.white.opacity(0.34), .clear],
                        center: .topLeading,
                        startRadius: 0,
                        endRadius: size * 0.85
                    )
                )
            // Aro orbital lavanda
            Circle()
                .strokeBorder(
                    .white.opacity(hover ? 0.42 : 0.24),
                    style: StrokeStyle(lineWidth: max(1, size * 0.022), dash: [size * 0.08, size * 0.055])
                )
                .padding(size * 0.13)
                .rotationEffect(.degrees(spin ? 360 : 0))

            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: size * 0.44, weight: .bold))
                .foregroundStyle(.white)
                .rotationEffect(.degrees(hover ? -45 : 0))
                .symbolEffect(.bounce, value: bounce)
                .shadow(color: .black.opacity(0.25), radius: size * 0.06, y: size * 0.03)

            Image(systemName: "sparkle")
                .font(.system(size: size * 0.16, weight: .bold))
                .foregroundStyle(.white.opacity(0.92))
                .offset(x: size * 0.25, y: -size * 0.25)
                .scaleEffect(pulse ? 1.18 : 0.82)
        }
        .frame(width: size, height: size)
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .strokeBorder(.white.opacity(0.32), lineWidth: max(1, size * 0.02))
        )
        .shadow(color: Palette.accent.opacity(pulse ? 0.55 : 0.28), radius: pulse ? 20 : 11, y: 6)
    }

    private var reactor: some View {
        ZStack {
            Circle().fill(Color.black.opacity(0.85))
            Circle().strokeBorder(Palette.secondary, lineWidth: size * 0.05)
            ForEach(0..<10) { i in
                Capsule()
                    .fill(Palette.accent)
                    .frame(width: size * 0.07, height: size * 0.17)
                    .offset(y: -size * 0.33)
                    .rotationEffect(.degrees(Double(i) * 36))
            }
            .rotationEffect(.degrees(spin ? 360 : 0))
            Circle()
                .strokeBorder(Palette.glow.opacity(0.9), style: StrokeStyle(lineWidth: size * 0.025, dash: [size * 0.06, size * 0.04]))
                .frame(width: size * 0.52, height: size * 0.52)
                .rotationEffect(.degrees(spin ? -360 : 0))
            Circle()
                .fill(RadialGradient(colors: [.white, Palette.glow, Palette.glow.opacity(0)], center: .center,
                                     startRadius: 0, endRadius: size * 0.22))
                .frame(width: size * 0.42, height: size * 0.42)
                .scaleEffect(pulse ? 1.08 : 0.92)
        }
        .frame(width: size, height: size)
        .shadow(color: Palette.glow.opacity(pulse ? 0.8 : 0.35), radius: pulse ? 22 : 10)
    }
}

/// Insignia de versión 3.0 con degradado morado.
struct VersionPill: View {
    var text = "3.0"
    var body: some View {
        Text(text)
            .font(.caption.weight(.bold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Capsule().fill(Palette.gradient))
            .overlay(Capsule().strokeBorder(.white.opacity(0.28), lineWidth: 0.8))
            .shadow(color: Palette.accent.opacity(0.38), radius: 6, y: 2)
    }
}

/// Microinteracción: la tarjeta se eleva con resplandor morado suave al pasar el puntero.
struct HoverLift: ViewModifier {
    var scale: CGFloat = 1.022
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering ? scale : 1)
            .offset(y: hovering ? -2 : 0)
            .shadow(color: Palette.accent.opacity(hovering ? 0.26 : 0), radius: hovering ? 16 : 0, y: hovering ? 8 : 0)
            .animation(.spring(response: 0.24, dampingFraction: 0.76), value: hovering)
            .onHover { hovering = $0 }
    }
}

extension View {
    func hoverLift(_ scale: CGFloat = 1.022) -> some View { modifier(HoverLift(scale: scale)) }
}

/// Botón principal con degradado violeta-orquídea, brillo superior y respuesta elástica al clic.
struct GlowButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .padding(.vertical, 11)
            .background(
                Capsule()
                    .fill(enabled ? AnyShapeStyle(Palette.gradient) : AnyShapeStyle(Color.gray.opacity(0.38)))
                    .overlay(
                        Capsule()
                            .strokeBorder(.white.opacity(enabled ? (hovering ? 0.42 : 0.24) : 0), lineWidth: 1)
                    )
            )
            .shadow(
                color: Palette.accent.opacity(enabled ? (configuration.isPressed ? 0.22 : (hovering ? 0.58 : 0.42)) : 0),
                radius: configuration.isPressed ? 5 : (hovering ? 16 : 11),
                y: configuration.isPressed ? 2 : 5
            )
            .scaleEffect(configuration.isPressed ? 0.955 : (hovering && enabled ? 1.025 : 1))
            .animation(.spring(response: 0.22, dampingFraction: 0.68), value: configuration.isPressed)
            .animation(.spring(response: 0.22, dampingFraction: 0.78), value: hovering)
            .onHover { hovering = $0 }
    }
}

/// Variante compacta para barras de herramientas y paneles laterales: conserva el moradito vivo.
struct CompactGlowButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 13)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(enabled ? AnyShapeStyle(Palette.gradient) : AnyShapeStyle(Color.gray.opacity(0.35)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(.white.opacity(enabled ? (hovering ? 0.4 : 0.22) : 0), lineWidth: 0.8)
                    )
            )
            .shadow(
                color: Palette.accent.opacity(enabled ? (configuration.isPressed ? 0.18 : (hovering ? 0.45 : 0.28)) : 0),
                radius: configuration.isPressed ? 3 : (hovering ? 10 : 6),
                y: 2
            )
            .scaleEffect(configuration.isPressed ? 0.96 : (hovering && enabled ? 1.02 : 1))
            .animation(.snappy(duration: 0.16), value: configuration.isPressed)
            .animation(.snappy(duration: 0.18), value: hovering)
            .onHover { hovering = $0 }
    }
}

/// Anillo de progreso animado, con el valor en el centro.
struct RingGauge: View {
    var value: Double
    var lineWidth: CGFloat = 14
    var colors: [Color] = [Palette.accent, Palette.secondary]

    var body: some View {
        ZStack {
            Circle().stroke(Palette.accent.opacity(0.11), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, value)))
                .stroke(AngularGradient(colors: colors + [colors[0]], center: .center),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: colors[0].opacity(0.45), radius: 7)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: value)
    }
}

/// Barra de progreso moradita con reflejo luminoso mientras avanza.
struct ShimmerBar: View {
    var value: Double
    var active: Bool
    var height: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.accent.opacity(0.12))
                Capsule()
                    .fill(Palette.gradient)
                    .frame(width: max(height, geo.size.width * min(1, max(0, value))))
                    .overlay {
                        if active, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                            TimelineView(.animation) { context in
                                let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.35) / 1.35
                                LinearGradient(colors: [.clear, .white.opacity(0.6), .clear], startPoint: .leading, endPoint: .trailing)
                                    .frame(width: 84)
                                    .offset(x: CGFloat(t) * (geo.size.width + 84) - 42)
                            }
                            .clipShape(Capsule())
                        }
                    }
                    .shadow(color: Palette.accent.opacity(active ? 0.35 : 0.15), radius: 5, y: 1)
                    .animation(.spring(response: 0.3, dampingFraction: 0.86), value: value)
            }
        }
        .frame(height: height)
    }
}
