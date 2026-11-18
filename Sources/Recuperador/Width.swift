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

/// Publica el ancho y deja el mínimo de la ventana en tamaño de teléfono.
struct WidthClassReader: ViewModifier {
    @Binding var widthClass: WidthClass

    func body(content: Content) -> some View {
        content
            .environment(\.widthClass, widthClass)
            // Solo avisa cuando cambia la categoría de ancho, no en cada pasada de diseño.
            .onGeometryChange(for: WidthClass?.self, of: { $0.size.width > 200 ? WidthClass($0.size.width) : nil }) { next in
                if let next, next != widthClass { widthClass = next }
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

/// A unified toolbar can cover the top of split-view columns. Only add space
/// when AppKit reports that this column starts above the unobscured content.
struct WindowToolbarClearance: ViewModifier {
    var enabled = true
    @State private var overlap: CGFloat = 0

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            constrained(content)
        } else {
            content
        }
    }

    private func constrained(_ content: Content) -> some View {
        GeometryReader { geometry in
            let clearance = min(overlap, geometry.size.height)
            content
                .frame(width: geometry.size.width, height: geometry.size.height - clearance)
                .padding(.top, clearance)
                .overlay(alignment: .top) {
                    WindowToolbarProbe(overlap: $overlap)
                        .frame(width: 1, height: 1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
        }
    }
}

private struct WindowToolbarProbe: NSViewRepresentable {
    @Binding var overlap: CGFloat

    func makeNSView(context: Context) -> Probe { Probe(frame: .zero) }

    func updateNSView(_ view: Probe, context: Context) {
        view.report = { value in if overlap != value { overlap = value } }
        view.measureAfterLayout()
    }

    final class Probe: NSView {
        var report: ((CGFloat) -> Void)?
        private var measurementScheduled = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            measureAfterLayout()
        }

        override func layout() {
            super.layout()
            measureAfterLayout()
        }

        func measureAfterLayout() {
            guard !measurementScheduled else { return }
            measurementScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                measurementScheduled = false
                guard let window else { return }
                let top = convert(bounds, to: nil).maxY
                // AppKit can include the unified toolbar in contentLayoutRect
                // when a sidebar titlebar is transparent.
                let nativeTop = window.contentLayoutRect.maxY
                let toolbarVisible = window.toolbar?.isVisible == true
                let minimumInset: CGFloat = toolbarVisible ? 54 : 0
                let uncoveredTop = min(nativeTop, window.frame.height - minimumInset)
                report?(max(0, ceil(top - uncoveredTop)))
            }
        }
    }
}
