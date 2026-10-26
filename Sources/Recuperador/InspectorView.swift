import Quartz
import RecoveryCore
import SwiftUI

struct InspectorView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let item = model.focused {
            ItemInspector(item: item)
        } else if model.selection.count > 1 {
            let items = model.selectedItems
            VStack(spacing: 16) {
                Image(systemName: "square.stack.3d.up.fill").font(.system(size: 48)).foregroundStyle(Palette.accent)
                Text("\(items.count) archivos seleccionados").font(.title3.weight(.semibold))
                Text(ByteCountFormatter.string(fromByteCount: items.reduce(0) { $0 + $1.file.size }, countStyle: .file))
                    .foregroundStyle(.secondary)
                Button { model.recover(items) } label: {
                    Label("Recuperar seleccionados", systemImage: "arrow.down.doc.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(24)
            .frame(maxHeight: .infinity)
        } else {
            ContentUnavailableView("Selecciona un archivo", systemImage: "photo.on.rectangle.angled",
                                   description: Text("Verás la vista previa, la información de la foto y el análisis de recuperabilidad."))
        }
    }
}

struct ItemInspector: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var item: Item

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                preview

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name).font(.title3.weight(.semibold)).textSelection(.enabled)
                    if let folder = item.file.folder {
                        Label(folder, systemImage: "folder").font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    }
                    if let date = item.date {
                        Label(date.formatted(date: .long, time: .shortened), systemImage: "calendar")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }

                Button { model.recover([item]) } label: {
                    Label("Recuperar este archivo", systemImage: "arrow.down.doc.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

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
            .padding(18)
        }
    }

    @ViewBuilder private var preview: some View {
        Group {
            if let url = item.localURL {
                QuickLookPreview(url: url)
            } else {
                ZStack {
                    ThumbnailView(item: item)
                    VStack(spacing: 10) {
                        if item.preparing {
                            ProgressView().controlSize(.large)
                            Text("Preparando vista previa…").foregroundStyle(.white)
                        } else if item.file.size > 150 * 1024 * 1024 {
                            Button { model.prepare(item) } label: { Label("Generar vista previa", systemImage: "eye") }
                                .controlSize(.large)
                        } else {
                            ProgressView().controlSize(.large)
                        }
                    }
                }
            }
        }
        .frame(height: 270)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.quaternary))
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
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(item.healthNote).foregroundStyle(.secondary)
                }
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

/// Vista previa nativa de Quick Look: imágenes, videos con reproductor, audio, PDF, Office...
struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .compact)!
        view.autostarts = true
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
