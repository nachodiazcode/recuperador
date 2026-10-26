import SwiftUI

enum ThemeChoice: String, CaseIterable, Identifiable {
    case system = "Recuperador"
    case ironMan = "Iron Man"
    var id: String { rawValue }
}

/// Colores del tema activo. RootView los fija y reconstruye la interfaz al cambiar de tema.
enum Palette {
    static var theme: ThemeChoice = .system

    static var accent: Color {
        theme == .ironMan ? Color(red: 0.86, green: 0.12, blue: 0.14) : Color(red: 0.45, green: 0.36, blue: 0.98)
    }
    static var secondary: Color {
        theme == .ironMan ? Color(red: 0.98, green: 0.76, blue: 0.27) : Color(red: 0.70, green: 0.32, blue: 0.95)
    }
    /// El brillo celeste del reactor.
    static var glow: Color {
        theme == .ironMan ? Color(red: 0.45, green: 0.95, blue: 1.0) : Color(red: 0.62, green: 0.30, blue: 0.95)
    }
    static var gradient: LinearGradient {
        LinearGradient(colors: [accent, secondary], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static var titleDesign: Font.Design { theme == .ironMan ? .monospaced : .rounded }
}

/// Fondo del tema: degradado suave, y en Iron Man una cuadrícula tipo HUD que se desplaza.
struct ThemedBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Palette.accent.opacity(0.13), Palette.secondary.opacity(0.07), .clear],
                           startPoint: .topLeading, endPoint: .bottom)
            if Palette.theme == .ironMan {
                TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    Canvas { ctx, size in
                        let step: CGFloat = 46
                        let shift = CGFloat(t.truncatingRemainder(dividingBy: 8) / 8) * step
                        var grid = Path()
                        for x in stride(from: -step + shift, through: size.width, by: step) {
                            grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
                        }
                        for y in stride(from: -step + shift, through: size.height, by: step) {
                            grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
                        }
                        ctx.stroke(grid, with: .color(Palette.secondary.opacity(0.06)), lineWidth: 1)
                        // Línea de barrido horizontal.
                        let scan = CGFloat((t / 6).truncatingRemainder(dividingBy: 1)) * size.height
                        ctx.fill(Path(CGRect(x: 0, y: scan, width: size.width, height: 2)),
                                 with: .linearGradient(Gradient(colors: [.clear, Palette.glow.opacity(0.25), .clear]),
                                                       startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)))
                    }
                }
            }
        }
        .ignoresSafeArea()
    }
}

/// El ícono de la app: en el tema Iron Man es un reactor que gira y late.
struct AppBadge: View {
    var size: CGFloat
    @State private var spin = false
    @State private var pulse = false
    @State private var hover = false

    var body: some View {
        Group {
            if Palette.theme == .ironMan { reactor } else { classic }
        }
        .scaleEffect(hover ? 1.06 : 1)
        .animation(.spring(response: 0.35, dampingFraction: 0.6), value: hover)
        .onHover { hover = $0 }
        .onAppear {
            withAnimation(.linear(duration: 14).repeatForever(autoreverses: false)) { spin = true }
            withAnimation(.easeInOut(duration: 1.6).repeatForever()) { pulse = true }
        }
    }

    private var classic: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(Palette.gradient)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: size * 0.46, weight: .bold))
                    .foregroundStyle(.white)
                    .rotationEffect(.degrees(hover ? -40 : 0))
            )
            .shadow(color: Palette.secondary.opacity(pulse ? 0.55 : 0.25), radius: pulse ? 18 : 10, y: 6)
    }

    private var reactor: some View {
        ZStack {
            Circle().fill(Color.black.opacity(0.85))
            Circle().strokeBorder(Palette.secondary, lineWidth: size * 0.05)
            // Bobinas del anillo exterior.
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

/// Microinteracción: la vista se eleva al pasar el mouse.
struct HoverLift: ViewModifier {
    var scale: CGFloat = 1.025
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering ? scale : 1)
            .shadow(color: Palette.accent.opacity(hovering ? 0.22 : 0), radius: hovering ? 14 : 0, y: hovering ? 8 : 0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovering)
            .onHover { hovering = $0 }
    }
}

extension View {
    func hoverLift(_ scale: CGFloat = 1.025) -> some View { modifier(HoverLift(scale: scale)) }
}

/// Botón principal con degradado del tema, que se hunde al hacer clic.
struct GlowButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .padding(.vertical, 11)
            .background(Capsule().fill(enabled ? AnyShapeStyle(Palette.gradient) : AnyShapeStyle(Color.gray.opacity(0.4))))
            .shadow(color: Palette.accent.opacity(enabled ? (configuration.isPressed ? 0.2 : 0.45) : 0), radius: configuration.isPressed ? 4 : 12, y: 4)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// Anillo de progreso animado, con el valor en el centro.
struct RingGauge: View {
    var value: Double
    var lineWidth: CGFloat = 14
    var colors: [Color] = [Palette.accent, Palette.secondary]

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.08), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, value)))
                .stroke(AngularGradient(colors: colors + [colors[0]], center: .center),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: colors[0].opacity(0.4), radius: 6)
        }
        .animation(.spring(response: 0.9, dampingFraction: 0.8), value: value)
    }
}

/// Barra de progreso con brillo que recorre la barra mientras avanza.
struct ShimmerBar: View {
    var value: Double
    var active: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(Palette.gradient)
                    .frame(width: max(8, geo.size.width * min(1, value)))
                    .overlay {
                        if active {
                            TimelineView(.animation) { context in
                                let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                                LinearGradient(colors: [.clear, .white.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing)
                                    .frame(width: 80)
                                    .offset(x: CGFloat(t) * geo.size.width - 40)
                            }
                            .clipShape(Capsule())
                        }
                    }
                    .animation(.spring(response: 0.5), value: value)
            }
        }
        .frame(height: 12)
    }
}
