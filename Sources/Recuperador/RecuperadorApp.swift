import AppKit
import SwiftUI

@main
struct RecuperadorApp: App {
    @StateObject private var model = AppModel()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        Window("Recuperador", id: "main") {
            RootView()
                .environmentObject(model)
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
                Button("Recuperar") {
                    model.recover(model.selection.isEmpty ? model.filtered : model.selectedItems)
                }
                .keyboardShortcut("r")
                .disabled(model.filtered.isEmpty)
                Button("Detener escaneo") { model.stop() }
                    .keyboardShortcut(".")
                    .disabled(!model.phase.isScanning)
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
                case .clean:
                    CleanerView()
                        .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)).combined(with: .opacity))
                case .recover:
                    Group {
                        if model.phase == .idle || model.phase == .opening {
                            WelcomeView()
                        } else {
                            ResultsView()
                        }
                    }
                    .transition(.asymmetric(insertion: .move(edge: .leading), removal: .move(edge: .trailing)).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .id(theme)
        .tint(Palette.accent)
        .preferredColorScheme(theme == .ironMan ? .dark : nil)
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: section)
        .animation(.smooth, value: model.phase == .idle)
        .modifier(WidthClassReader(widthClass: $widthClass))
        .toolbar {
            ToolbarItem(placement: .principal) {
                if widthClass != .compact { sectionPicker.frame(width: widthClass == .medium ? 200 : 220) }
            }
            ToolbarItem(placement: .navigation) {
                Menu {
                    Picker("Tema", selection: $theme.animation(.easeInOut(duration: 0.4))) {
                        ForEach(ThemeChoice.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Toggle("Sonidos", isOn: $sounds)
                    Toggle("Avisos", isOn: $notices)
                } label: {
                    Label("Tema", systemImage: theme == .ironMan ? "bolt.circle.fill" : "paintpalette.fill")
                }
                .help("Tema, sonidos y avisos")
            }
        }
        .onChange(of: sounds) { _, enabled in
            if enabled { Signals.play(.rise) }
        }
        .onChange(of: notices) { _, enabled in
            if enabled { Signals.requestAccess() }
        }
    }

    private var sectionPicker: some View {
        Picker("Sección", selection: $section) {
            ForEach(AppSection.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
    }
}
