import AppKit
import SwiftUI

@main
struct RecuperadorApp: App {
    @StateObject private var model = AppModel()
    @AppStorage("tamano") private var cardSize = CardSize.standard

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        Window("Recuperador", id: "main") {
            RootView()
                .environmentObject(model)
                .environmentObject(model.focus)
                .environmentObject(model.live)
                .frame(minWidth: 390, minHeight: 560)
                .onAppear {
                    Signals.prepare()
                    NSApp.activate(ignoringOtherApps: true)
                    // `Recuperador --abrir imagen.dmg` escanea una imagen directamente (útil para pruebas).
                    let args = CommandLine.arguments
                    if let i = args.firstIndex(of: "--abrir"), i + 1 < args.count {
                        model.openImage(at: URL(fileURLWithPath: args[i + 1]), deep: true)
                    }
                }
                .alert("Atención", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
                    Button("Entendido", role: .cancel) {}
                } message: {
                    Text(model.alert ?? "")
                }
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1320, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Nuevo escaneo") { model.newScan() }
                    .keyboardShortcut("n")
                Button("Abrir imagen de disco…") { model.openImage(deep: true) }
                    .keyboardShortcut("o")
                Button("Recuperar selección o visibles…") {
                    model.recoverResults()
                }
                .keyboardShortcut("r")
                .disabled(!model.hasVisibleResults)
                Button("Recuperar datos…") {
                    model.openRecoverAll()
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(model.items.isEmpty)
                Button("Detener escaneo") { model.stop() }
                    .keyboardShortcut(".")
                    .disabled(!model.phase.isScanning)
            }
            CommandGroup(after: .toolbar) {
                Button("Miniaturas más grandes") { cardSize = CardSize.clamp(cardSize * 1.15) }
                    .keyboardShortcut("+")
                Button("Miniaturas más chicas") { cardSize = CardSize.clamp(cardSize / 1.15) }
                    .keyboardShortcut("-")
                Button("Tamaño normal de miniaturas") { cardSize = CardSize.standard }
                    .keyboardShortcut("0")
            }
        }
    }
}

enum AppSection: String, CaseIterable, Identifiable {
    case recover = "Recuperar"
    case clean = "Limpiar"
    var id: String { rawValue }
    var symbol: String { self == .recover ? "arrow.counterclockwise" : "sparkles" }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("seccion") private var section: AppSection = .recover
    @AppStorage("tema") private var theme: ThemeChoice = .system
    @AppStorage("sonidos") private var sounds = true
    @AppStorage("avisos") private var notices = true
    @State private var widthClass: WidthClass = .regular

    var body: some View {
        let _ = Palette.theme = theme
        VStack(spacing: 0) {
            if widthClass == .compact {
                sectionPicker
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                Divider()
            }
            Group {
                switch section {
                case .recover: RecoverSection()
                case .clean: CleanerView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .id(theme)
        .tint(Palette.accent)
        .preferredColorScheme(theme.forcesDark ? .dark : nil)

        .modifier(WidthClassReader(widthClass: $widthClass))
        .toolbar {
            ToolbarItem(placement: .principal) {
                if widthClass != .compact { sectionPicker.frame(width: widthClass == .medium ? 200 : 220) }
            }
            ToolbarItem(placement: .navigation) {
                Menu {
                    // Sin animación SwiftUI: el tema reconstruye toda la interfaz con Crossfade.
                    Picker("Tema", selection: $theme) {
                        ForEach(ThemeChoice.allCases) { choice in
                            Label(choice.label, systemImage: choice.symbol).tag(choice)
                        }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Toggle("Sonidos", isOn: $sounds)
                    Toggle("Avisos", isOn: $notices)
                } label: {
                    Label("Tema", systemImage: theme.symbol)
                        .foregroundStyle(Palette.accent)
                }
                .help("Tema (\(theme.label)), sonidos y avisos")
            }
        }
        .onChange(of: theme) { Crossfade.next(0.3) }
        .onChange(of: sounds) { _, enabled in
            if enabled { Signals.play(.rise) }
        }
        .onChange(of: notices) { _, enabled in
            if enabled { Signals.requestAccess() }
        }
    }

    private var sectionPicker: some View {
        Picker("Sección", selection: Binding(get: { section }, set: { next in
            guard next != section else { return }
            Crossfade.next()
            section = next
        })) {
            ForEach(AppSection.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
    }
}

/// Pantalla de Recuperar: bienvenida o resultados. El visor grande va encima, dentro de la
/// misma ventana (una hoja aparte oscurecía la ventana de atrás fotografiándola entera, y eso
/// trababa la apertura).
private struct RecoverSection: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var focus: Focus

    var body: some View {
        let idle = model.phase == .idle || model.phase == .opening
        Group {
            if idle {
                WelcomeView()
            } else {
                ResultsView()
                    .overlay {
                        if focus.viewerOpen {
                            ViewerOverlay()
                        }
                    }
            }
        }
        .onChange(of: idle) { Crossfade.next() }
    }
}
