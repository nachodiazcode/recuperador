import Quartz
import RecoveryCore
import SwiftUI

struct InspectorView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var focus: Focus
    /// Lo que el panel muestra. Con una flecha mantenida la selección cambia muchas veces por
    /// segundo: la galería la sigue al instante y el panel espera a que se detenga, como el panel
    /// de vista previa del Finder. Rearmarlo en cada paso era lo que trababa la navegación.
    @State private var shown: Set<Int>?

    private var displayed: Set<Int> { shown ?? focus.selection }
    var belowWindowToolbar = true

    var body: some View {
        VStack(spacing: 0) {
            Label("Detalles", systemImage: "sidebar.trailing")
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
        .modifier(WindowToolbarClearance(enabled: belowWindowToolbar))
        .task(id: focus.selection) {
            // Con el visor abierto el panel queda tapado: se pone al día al cerrarlo.
            guard !focus.viewerOpen || shown == nil else { return }
            if shown != nil, model.isBrowsingFast {
                try? await Task.sleep(for: .milliseconds(160))
                guard !Task.isCancelled else { return }
            }
            shown = focus.selection
        }
        .onChange(of: focus.viewerOpen) { _, open in
            if !open { shown = focus.selection }
        }
    }

    @ViewBuilder private var content: some View {
        if displayed.count == 1, let item = displayed.first.flatMap(model.item) {
            // Identidad por archivo: reproductores y estados no se arrastran al cambiar de selección.
            ItemInspector(item: item).id(item.id)
        } else if displayed.count > 1 {
            let bytes = displayed == focus.selection
                ? focus.selectedBytes
                : displayed.reduce(Int64(0)) { $0 + (model.item($1)?.file.size ?? 0) }
            VStack(spacing: 16) {
                Image(systemName: "square.stack.3d.up.fill").font(.system(size: 48)).foregroundStyle(Palette.accent)
                Text("\(displayed.count.formatted()) archivos seleccionados").font(.title3.weight(.semibold))
                Text(Bytes.gigabytesDetailed(bytes))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button { model.recover(displayed.compactMap(model.item)) } label: {
                    Label("Recuperar seleccionados", systemImage: "arrow.down.doc.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(GlowButtonStyle())
                Button { model.openRecoverAll(mode: .current) } label: {
                    Label("Más formas de recuperar…", systemImage: "externaldrive.fill.badge.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(24)
            .frame(maxHeight: .infinity)
        } else {
            VStack(spacing: 16) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(Palette.gradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: Palette.accent.opacity(0.32), radius: 9, y: 3)
                    .accessibilityHidden(true)
                Text("Selecciona un archivo")
                    .font(.headline)
                Text("Haz clic en un resultado para ver sus datos, su vista previa y el estado de recuperación.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if !model.items.isEmpty {
                    Divider().padding(.vertical, 4)
                    VStack(spacing: 8) {
                        Text("Total escaneado en Gigas")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(Bytes.gigabytes(model.totalBytes))
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Palette.gradient)
                            .contentTransition(.numericText())
                        Text("\(model.items.count.formatted()) archivos encontrados")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Button { model.openRecoverAll() } label: {
                            Label("Recuperar datos…", systemImage: "externaldrive.fill.badge.arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(CompactGlowButtonStyle())
                        .padding(.top, 6)
                    }
                    .padding(14)
                    .background(Palette.subtleSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.borderStroke))
                }
            }
            .padding(20)
        }
    }
}

struct ItemInspector: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var item: Item

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 10) {
                    ResultFileIcon(category: item.category, size: 36)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name).font(.headline).textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .help(item.name)
                        Text(fileSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 5) {
                    if let folder = item.file.folder {
                        Label(folder, systemImage: "folder").lineLimit(2).truncationMode(.middle)
                    }
                    if let date = item.date {
                        Label(date.formatted(date: .long, time: .shortened), systemImage: "calendar")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Button { model.recover([item]) } label: {
                    Label("Recuperar este archivo", systemImage: "arrow.down.doc.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(CompactGlowButtonStyle())

                // Vista previa rápida y de alta resolución
                preview

                if item.file.likelyOverwritten {
                    Callout(symbol: "exclamationmark.triangle.fill", tint: .orange,
                            title: "Ese espacio ya se reutilizó",
                            text: "El sistema de archivos asignó estos sectores a otro archivo después del borrado. Lo que recuperes puede estar mezclado o incompleto.")
                }
                if item.file.embedded {
                    Callout(symbol: "square.stack.3d.up.fill", tint: .blue,
                            title: "Estaba dentro de otro archivo",
                            text: "Apareció al revisar el interior de un documento o un comprimido. Si ya recuperaste ese archivo, esta copia sobra.")
                }

                HealthCard(item: item)

                if !item.labels.isEmpty {
                    Card(title: "Contenido detectado", symbol: "sparkles") {
                        FlowLayout(spacing: 6) {
                            ForEach(item.labels, id: \.self) { label in
                                Text(label)
                                    .font(.callout)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(Color.purple.opacity(0.14), in: Capsule())
                                    .foregroundStyle(.purple)
                                    .onTapGesture { model.search = label }
                            }
                        }
                        Text("Análisis local con Vision de Apple · toca una etiqueta para buscar")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }

                if !item.rows.isEmpty {
                    Card(title: "Información", symbol: "info.circle") {
                        InfoGrid(rows: item.rows)
                    }
                }

                Card(title: "Detalles técnicos", symbol: "cpu") {
                    InfoGrid(rows: technicalRows)
                }
            }
            .padding(16)
        }
    }

    private var fileSummary: String {
        let size = ByteCountFormatter.string(fromByteCount: item.file.size, countStyle: .file)
        return item.file.ext.isEmpty ? size : "\(item.file.ext.uppercased()) · \(size)"
    }

    private var preview: some View {
        VStack(spacing: 6) {
            FilePreview(item: item)
            HStack {
                Button { model.viewerOpen = true } label: {
                    Label("Ampliar", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .help("Ver en grande (barra espaciadora)")
                Spacer()
                if item.loading, let progress = item.progress {
                    ProgressView(value: progress).frame(width: 60).controlSize(.small)
                }
                Button("Abrir con macOS…") { model.openExternally(item) }
                    .disabled(item.loading)
            }
            .font(.caption.weight(.medium))
            .buttonStyle(.link)
        }
        .frame(maxWidth: .infinity)
    }

    private var technicalRows: [MetaRow] {
        var rows = [
            MetaRow(label: "Tamaño", value: ByteCountFormatter.string(fromByteCount: item.file.size, countStyle: .file)),
            MetaRow(label: "Formato", value: item.file.ext.uppercased()),
            MetaRow(label: "Posición", value: String(format: "0x%llX", item.file.offset)),
        ]
        switch item.file.origin {
        case let .fileSystem(fs): rows.append(MetaRow(label: "Encontrado en", value: "Entrada borrada de \(fs)"))
        case let .carved(exact): rows.append(MetaRow(label: "Encontrado en", value: exact ? "Escaneo profundo (firma)" : "Escaneo profundo · tamaño estimado"))
        }
        if item.file.extents.count > 1 { rows.append(MetaRow(label: "Fragmentos", value: "\(item.file.extents.count)")) }
        if item.file.embedded { rows.append(MetaRow(label: "Ubicación", value: "Dentro de otro archivo")) }
        if item.file.likelyOverwritten { rows.append(MetaRow(label: "Sectores", value: "Ya reasignados")) }
        return rows
    }
}

// MARK: - Tarjetas auxiliares

struct HealthCard: View {
    @ObservedObject var item: Item

    var body: some View {
        Card(title: "Recuperabilidad", symbol: "stethoscope") {
            if let health = item.health {
                let (color, _) = HealthBadge.style(health)
                HStack(spacing: 16) {
                    Gauge(value: Double(health), in: 0...100) {
                        EmptyView()
                    } currentValueLabel: {
                        Text("\(health)").font(.title3.weight(.bold)).monospacedDigit()
                    }
                    .gaugeStyle(.accessoryCircularCapacity)
                    .tint(color)
                    .scaleEffect(1.2)
                    .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(HealthBadge.title(health)).font(.headline).foregroundStyle(color)
                        Text(item.healthNote).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                Text(item.preparing ? "Comprobando el contenido…" : item.healthNote)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct Card<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct InfoGrid: View {
    let rows: [MetaRow]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
            ForEach(rows, id: \.self) { row in
                GridRow {
                    Text(row.label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Text(row.value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout)
            }
        }
    }
}

/// Vista previa nativa de Quick Look para formatos de sistema
struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .compact)!
        view.autostarts = false
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url { view.previewItem = url as NSURL }
    }
}

/// Distribuye las etiquetas en filas, saltando de línea cuando no caben.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
