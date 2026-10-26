import AppKit
import SwiftUI

/// Ancho útil de la ventana. En macOS no hay size class de teléfono: se mide el contenido.
enum WidthClass: Equatable {
    /// Hasta el ancho de un teléfono en horizontal.
    case compact
    /// Ancho de tablet.
    case medium
    /// Escritorio.
    case regular

    init(_ width: CGFloat) {
        if width < 720 { self = .compact }
        else if width < 1100 { self = .medium }
        else { self = .regular }
    }

    var pagePadding: CGFloat {
        switch self {
        case .compact: return 16
        case .medium: return 28
        case .regular: return 40
        }
    }

    var heroSize: CGFloat { self == .compact ? 28 : 38 }
    var heroIcon: CGFloat { self == .compact ? 56 : 84 }
    var stacks: Bool { self != .regular }
}

private struct WidthClassKey: EnvironmentKey {
    static let defaultValue = WidthClass.regular
}

extension EnvironmentValues {
    var widthClass: WidthClass {
        get { self[WidthClassKey.self] }
        set { self[WidthClassKey.self] = newValue }
    }
}

private struct WidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Publica el ancho y deja el mínimo de la ventana en tamaño de teléfono.
struct WidthClassReader: ViewModifier {
    @Binding var widthClass: WidthClass

    func body(content: Content) -> some View {
        content
            .environment(\.widthClass, widthClass)
            .background {
                GeometryReader { geo in
                    Color.clear.preference(key: WidthPreferenceKey.self, value: geo.size.width)
                }
            }
            .onPreferenceChange(WidthPreferenceKey.self) { width in
                guard width > 200 else { return }
                let next = WidthClass(width)
                if next != widthClass { widthClass = next }
            }
            .background(WindowMinSize(size: NSSize(width: 390, height: 560)))
    }
}

/// SwiftUI sube el mínimo de la ventana al ancho ideal del contenido. Esto lo vuelve a bajar.
private struct WindowMinSize: NSViewRepresentable {
    var size: NSSize

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            if window.contentMinSize != size { window.contentMinSize = size }
        }
    }
}
