import QuickLookThumbnailing
import RecoveryCore
import SwiftUI

enum ResultLayout: String {
    case gallery, list
}

struct ResultsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.widthClass) private var width
    @State private var showInspector = true
    @State private var showFilters = false
    @State private var showDetails = false
    @AppStorage("vista") private var layout: ResultLayout = .gallery

    private var inspectorPresented: Binding<Bool> {
        Binding(get: { width == .regular && showInspector }, set: { showInspector = $0 })
    }

    var body: some View {
        Group {
            if width == .compact {
                detail
            } else {
                NavigationSplitView {
                    Sidebar()
                        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 280)
                } detail: {
                    detail
                }
                .inspector(isPresented: inspectorPresented) {
                    InspectorView()
                        .inspectorColumnWidth(min: 260, ideal: 340, max: 420)
                }
            }
        }
        .sheet(isPresented: $showFilters) { filterSheet }
        .sheet(isPresented: $showDetails) { detailSheet }
        .overlay(alignment: .bottom) {
            if let message = model.recoverMessage {
                Text(message)
                    .font(.headline)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(.thickMaterial, in: Capsule())
                    .shadow(radius: 10)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: model.recoverMessage)
    }

    private var detail: some View {
        VStack(spacing: 0) {
            ScanBanner()
            SmartQueryBar()
            Gallery(layout: layout)
        }
        .searchable(text: $model.search, placement: .toolbar, prompt: "Prueba: “el video más antiguo” o “fotos de febrero 2016”")
        .onSubmit(of: .search) { model.applySmartSelection() }
        .task(id: model.search) {
            try? await Task.sleep(for: .milliseconds(450))
            model.applySmartSelection()
        }
        .safeAreaInset(edge: .bottom) { selectionBar }
        .toolbar { resultsToolbar }
    }

    @ViewBuilder private var selectionBar: some View {
        if width != .regular, !model.selection.isEmpty {
            HStack(spacing: 12) {
                Text(selectionTitle).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Detalles") { showDetails = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(.horizontal, width.pagePadding)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }

    private var selectionTitle: String {
        if model.selection.count == 1, let name = model.focused?.name { return name }
        return "\(model.selection.count) seleccionados"
    }

    @ToolbarContentBuilder private var resultsToolbar: some ToolbarContent {
        ToolbarItemGroup {
            if width == .compact {
                Button { showFilters = true } label: { Label("Filtros", systemImage: "line.3.horizontal.decrease.circle") }
            }
            Picker("Vista", selection: $layout) {
                Image(systemName: "square.grid.2x2").tag(ResultLayout.gallery)
                Image(systemName: "list.bullet").tag(ResultLayout.list)
            }
            .pickerStyle(.segmented)
            .help("Galería o lista")

            if width == .compact {
                Menu {
                    ForEach(SortOrder.allCases) { order in
                        Button {
                            model.sort = order
                        } label: {
                            if model.sort == order { Label(order.rawValue, systemImage: "checkmark") }
                            else { Text(order.rawValue) }
                        }
                    }
                } label: {
                    Label("Ordenar", systemImage: "arrow.up.arrow.down")
                }
                .help("Ordenar por")
            } else {
                Picker("Ordenar", selection: $model.sort) {
                    ForEach(SortOrder.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                .help("Ordenar por")
            }

            Button {
                model.recover(model.selection.isEmpty ? model.filtered : model.selectedItems)
            } label: {
                if width == .compact {
                    Image(systemName: "arrow.down.doc.fill")
                } else {
                    Label(recoverTitle, systemImage: "arrow.down.doc.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.accent)
            .disabled(model.filtered.isEmpty)
            .help(recoverTitle)

            Button {
                if width == .regular { showInspector.toggle() } else { showDetails = true }
            } label: {
                if width == .regular {
                    Label("Detalles", systemImage: "sidebar.trailing")
                } else {
                    Image(systemName: "sidebar.trailing")
                }
            }
            .help("Detalles")
        }
    }

    private var recoverTitle: String {
        let count = model.selection.isEmpty ? model.filtered.count : model.selection.count
        if width == .regular, model.selection.isEmpty { return "Recuperar todo (\(count))" }
        if width == .compact { return "Recuperar \(count)" }
        return "Recuperar (\(count))"
    }

    private var filterSheet: some View {
        NavigationStack {
            Sidebar()
                .navigationTitle("Filtros")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Cerrar") { showFilters = false }
                    }
                }
        }
        .frame(minWidth: 320, idealWidth: 400, minHeight: 480)
    }

    private var detailSheet: some View {
        NavigationStack {
            InspectorView()
                .navigationTitle("Detalles")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Cerrar") { showDetails = false }
                    }
                }
        }
        .frame(minWidth: 320, idealWidth: 420, minHeight: 480)
    }
}

// MARK: - Barra lateral

struct Sidebar: View {
    @EnvironmentObject var model: AppModel

    private func symbol(_ c: FileCategory) -> String {
        switch c {
        case .photo: return "photo.fill"
        case .video: return "film.fill"
        case .audio: return "music.note"
        case .document: return "doc.text.fill"
        case .archive: return "archivebox.fill"
        case .other: return "questionmark.folder.fill"
        }
    }

    var body: some View {
        List(selection: Binding(get: { model.filter }, set: { model.filter = $0 ?? .all })) {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: model.sourceSymbol).font(.title).foregroundStyle(Palette.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.sourceName).font(.headline).lineLimit(1)
                        Text(phaseText).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
                .selectionDisabled()
            }

            Section("Biblioteca") {
                row("Todos", "square.grid.2x2.fill", .all, tint: .accentColor)
                row("Con nombre original", "character.textbox", .named, tint: .green)
            }
            Section("Tipos") {
                ForEach(FileCategory.allCases, id: \.self) { c in
                    row(c.rawValue, symbol(c), .category(c), tint: tint(c))
                }
            }
            if !model.years.isEmpty {
                Section("Año") {
                    ForEach(model.years, id: \.year) { entry in
                        Button {
                            model.year = model.year == entry.year ? nil : entry.year
                        } label: {
                            HStack {
                                Image(systemName: model.year == entry.year ? "checkmark.circle.fill" : "calendar")
                                    .foregroundStyle(model.year == entry.year ? Palette.accent : .secondary)
                                Text(String(entry.year))
                                Spacer()
                                Text("\(entry.count)").foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                        .buttonStyle(.plain)
                        .selectionDisabled()
                    }
                }
            }
            Section("Estado") {
                Toggle("Solo recuperables", isOn: $model.onlyRecoverable)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .selectionDisabled()
                if model.hasEmbeddedResults {
                    Toggle("Ocultar los que están dentro de otro", isOn: $model.hideEmbedded)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .selectionDisabled()
                }
                Toggle("Ocultar probablemente sobrescritos", isOn: $model.hideOverwritten)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .selectionDisabled()
            }
            if !model.volumes.isEmpty {
                Section("Volúmenes detectados") {
                    ForEach(Array(model.volumes.enumerated()), id: \.offset) { _, v in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(v.name).lineLimit(1)
                            Text(v.namesSupported ? "\(v.format) · con nombres" : "\(v.format) · solo escaneo profundo")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .selectionDisabled()
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Button { model.newScan() } label: {
                Label("Nuevo escaneo", systemImage: "plus.circle").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .padding(12)
        }
    }

    private func tint(_ c: FileCategory) -> Color {
        switch c {
        case .photo: return .pink
        case .video: return .purple
        case .audio: return .orange
        case .document: return .blue
        case .archive: return .brown
        case .other: return .gray
        }
    }

    private func row(_ title: String, _ symbol: String, _ tag: SidebarFilter, tint: Color) -> some View {
        HStack {
            Label { Text(title) } icon: { Image(systemName: symbol).foregroundStyle(tint) }
            Spacer()
            Text("\(model.count(tag))")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .tag(tag)
    }

    private var phaseText: String {
        switch model.phase {
        case .quick: return "Leyendo FAT, exFAT y NTFS…"
        case .deep: return "Escaneo profundo en curso"
        case .finished: return "Escaneo terminado"
        case .cancelled: return "Escaneo detenido"
        case let .failed(e): return e
        default: return ""
        }
    }
}

// MARK: - Búsqueda inteligente

/// Muestra cómo se interpretó la frase escrita en el buscador.
struct SmartQueryBar: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.widthClass) private var width

    var body: some View {
        let query = model.smart
        if !query.isEmpty {
            ViewThatFits(in: .horizontal) {
                queryLine(query.chips, stacked: false)
                queryLine(query.chips, stacked: true)
            }
            .padding(.horizontal, width == .compact ? 16 : 24)
            .padding(.vertical, 10)
            .background(Color.purple.opacity(0.05))
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    private func queryLine(_ chips: [String], stacked: Bool) -> some View {
        let summary = HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(.purple)
            Text("Entendí:").foregroundStyle(.secondary)
            if !stacked { chipRow(chips) }
            Spacer(minLength: 8)
            Text("\(model.filtered.count) resultado\(model.filtered.count == 1 ? "" : "s")")
                .foregroundStyle(.secondary).monospacedDigit()
                .lineLimit(1)
            Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        return VStack(alignment: .leading, spacing: 8) {
            summary
            if stacked { chipRow(chips) }
        }
    }

    private func chipRow(_ chips: [String]) -> some View {
        FlowLayout(spacing: 6) {
            ForEach(chips, id: \.self) { chip in
                Text(chip)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(Color.purple.opacity(0.14), in: Capsule())
                    .foregroundStyle(.purple)
            }
        }
    }
}

// MARK: - Progreso

struct ScanBanner: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.widthClass) private var width

    var body: some View {
        if model.phase.isScanning || model.phase == .finished || model.phase == .cancelled {
            ViewThatFits(in: .horizontal) {
                banner(wide: true)
                banner(wide: false)
            }
            .padding(.horizontal, width == .compact ? 16 : 24)
            .padding(.vertical, width == .compact ? 12 : 14)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    private func banner(wide: Bool) -> some View {
        let copy = VStack(alignment: .leading, spacing: 6) {
            if wide {
                Text(title).font(.headline).fixedSize(horizontal: false, vertical: true)
            }
            if model.phase == .deep, let p = model.progress {
                ShimmerBar(value: p.fraction, active: true).frame(maxWidth: wide ? 460 : .infinity)
            }
            Text(subtitle).font(wide ? .callout : .caption).foregroundStyle(.secondary).monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            counts
            filterLine(inlinePending: wide)
        }
        return Group {
            if wide {
                HStack(alignment: .center, spacing: 16) {
                    icon
                    copy.frame(maxWidth: .infinity, alignment: .leading)
                    stopButton
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 12) {
                        icon
                        Text(title).font(.headline).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        stopButton
                    }
                    copy
                }
            }
        }
    }

    private func filterLine(inlinePending: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                Text("Buscando: \(model.scanFilter.summary)")
                    .fixedSize(horizontal: false, vertical: true)
                if model.pendingCount > 0, inlinePending {
                    Text("· analizando fechas de \(model.pendingCount) archivo(s)…")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if model.pendingCount > 0, !inlinePending {
                Text("Analizando fechas de \(model.pendingCount) archivo(s)…")
            }
        }
        .font(.caption).foregroundStyle(.tertiary)
    }

    @ViewBuilder private var stopButton: some View {
        if model.phase.isScanning {
            Button(role: .destructive) { model.stop() } label: {
                if width == .compact {
                    Image(systemName: "stop.fill")
                } else {
                    Label("Detener", systemImage: "stop.fill")
                }
            }
            .controlSize(width == .compact ? .regular : .large)
            .help("Detener")
        }
    }

    @ViewBuilder private var icon: some View {
        switch model.phase {
        case .finished:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 30)).foregroundStyle(.green)
                .symbolEffect(.bounce, value: model.phase)
        case .cancelled:
            Image(systemName: "pause.circle.fill").font(.system(size: 30)).foregroundStyle(.orange)
        default:
            AppBadge(size: 34)
        }
    }

    private var title: String {
        switch model.phase {
        case .quick: return "Buscando archivos borrados con su nombre…"
        case .deep: return "Escaneo profundo · \(Int((model.progress?.fraction ?? 0) * 100))% · \(model.items.count) archivos"
        case .finished: return "Escaneo completo: \(model.items.count) archivos encontrados"
        case .cancelled: return "Escaneo detenido: \(model.items.count) archivos encontrados"
        default: return ""
        }
    }

    private var subtitle: String {
        let fmt = { (b: Int64) in ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
        guard let p = model.progress else {
            return model.phase == .quick ? "En FAT y exFAT son segundos. En NTFS hay que leer el índice entero." : "Puedes revisar y recuperar mientras sigue buscando"
        }
        let damage = model.badSectors > 0 ? " · \(model.badSectors) sectores ilegibles" : ""
        if model.phase != .deep { return "Se revisaron \(fmt(p.scanned)) en \(Analyzer.formatDuration(p.elapsed))\(damage)" }
        let remaining = p.bytesPerSecond > 0 ? Double(p.total - p.scanned) / p.bytesPerSecond : 0
        return "\(fmt(p.scanned)) de \(fmt(p.total)) · \(fmt(Int64(p.bytesPerSecond)))/s · quedan ~\(Analyzer.formatDuration(remaining))\(damage)"
    }

    private var counts: some View {
        let c = model.libraryCounts
        return FlowLayout(spacing: 8) {
            CountPill(value: c.shown, label: "en pantalla", tint: Palette.accent)
            CountPill(value: c.named, label: "con nombre", tint: .green)
            CountPill(value: c.recoverable, label: "recuperables", tint: .green)
            if c.review > 0 { CountPill(value: c.review, label: "a revisar", tint: .orange) }
        }
    }
}

private struct CountPill: View {
    let value: Int
    let label: String
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Text("\(value)").font(.caption.weight(.semibold).monospacedDigit())
            Text(label).font(.caption)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tint.opacity(0.12), in: Capsule())
    }
}

// MARK: - Galería

struct Gallery: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.widthClass) private var width
    var layout: ResultLayout

    private var columns: [GridItem] {
        switch width {
        case .compact: return [GridItem(.adaptive(minimum: 150), spacing: 12)]
        case .medium: return [GridItem(.adaptive(minimum: 168, maximum: 220), spacing: 16)]
        case .regular: return [GridItem(.adaptive(minimum: 178, maximum: 178), spacing: 18)]
        }
    }

    var body: some View {
        let items = model.filtered
        Group {
            if layout == .list, width == .compact {
                CompactResultList(items: items)
            } else if layout == .list {
                ResultTable(items: items)
            } else {
                gallery(items)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ThemedBackground())
        .overlay { empty(items) }
    }

    private func gallery(_ items: [Item]) -> some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 22) {
                ForEach(items) { item in
                    ItemCell(item: item, selected: model.selection.contains(item.id))
                        .hoverLift(1.04)
                        .onTapGesture { model.tap(item) }
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                        .contextMenu {
                            Button("Recuperar…") { model.recover([item]) }
                            if let url = item.localURL {
                                Button("Abrir vista previa") { NSWorkspace.shared.open(url) }
                            }
                        }
                }
            }
            .padding(width == .compact ? 12 : 24)
            .animation(.spring(response: 0.45, dampingFraction: 0.8), value: items.map(\.id))
        }
    }

    @ViewBuilder private func empty(_ items: [Item]) -> some View {
        if items.isEmpty {
            if model.phase.isScanning {
                ContentUnavailableView("Buscando…", systemImage: "magnifyingglass",
                                       description: Text("Los archivos aparecerán aquí a medida que se encuentren."))
            } else if !model.search.isEmpty {
                ContentUnavailableView.search(text: model.search)
            } else if model.phase == .finished || model.phase == .cancelled {
                ContentUnavailableView("No apareció nada con estos filtros", systemImage: "externaldrive.badge.questionmark",
                                       description: Text("Si el disco es un SSD, TRIM puede haber vaciado los datos al borrarlos. En un disco mecánico, un pendrive o una tarjeta, el escaneo completo revisa el espacio libre sector por sector."))
            } else {
                ContentUnavailableView("Nada por aquí", systemImage: "tray",
                                       description: Text("No se encontraron archivos con estos filtros."))
            }
        }
    }
}

struct ResultTable: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.widthClass) private var width
    let items: [Item]

    var body: some View {
        if width == .regular { fullTable } else { shortTable }
    }

    private var fullTable: some View {
        Table(items, selection: $model.selection) {
            fileColumn.width(min: 160, ideal: 360)
            sizeColumn.width(min: 80, ideal: 100)
            TableColumn("Fecha") { item in
                Text(item.date?.formatted(date: .abbreviated, time: .omitted) ?? "—")
                    .foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 120)
            TableColumn("Origen") { item in
                OriginLabel(item: item)
            }
            .width(min: 110, ideal: 170)
            stateColumn.width(min: 130, ideal: 180)
        }
        .modifier(TableActions())
    }

    private var shortTable: some View {
        Table(items, selection: $model.selection) {
            fileColumn.width(min: 140, ideal: 280)
            sizeColumn.width(min: 72, ideal: 90)
            stateColumn.width(min: 72, ideal: 90)
        }
        .modifier(TableActions())
    }

    private var fileColumn: TableColumn<Item, Never, FileNameCell, Text> {
        TableColumn("Archivo") { item in FileNameCell(item: item) }
    }

    private var sizeColumn: TableColumn<Item, Never, some View, Text> {
        TableColumn("Tamaño") { item in
            Text(ByteCountFormatter.string(fromByteCount: item.file.size, countStyle: .file))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private var stateColumn: TableColumn<Item, Never, HealthLabel, Text> {
        TableColumn("Estado") { item in HealthLabel(item: item) }
    }
}

/// Menú y doble clic de la tabla. Va aparte porque el contenido de columnas no admite `if` en macOS 14.0.
private struct TableActions: ViewModifier {
    @EnvironmentObject private var model: AppModel

    func body(content: Content) -> some View {
        content
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .contextMenu(forSelectionType: Int.self) { ids in
                Button("Recuperar…") { model.recover(model.items(ids: ids)) }
            } primaryAction: { ids in
                guard let item = model.items(ids: ids).first else { return }
                if let url = item.localURL {
                    NSWorkspace.shared.open(url)
                } else {
                    model.prepare(item)
                }
            }
    }
}

private struct FileNameCell: View {
    @ObservedObject var item: Item

    var body: some View {
        HStack(spacing: 10) {
            ThumbnailView(item: item)
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                if let folder = item.file.folder, folder != "/" {
                    Text(folder).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

private struct OriginLabel: View {
    let item: Item

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
            Text(text).lineLimit(1)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private var symbol: String {
        if item.file.embedded { return "square.stack.3d.up" }
        if item.hasOriginalName { return "character.textbox" }
        return "signature"
    }

    private var text: String {
        if item.file.embedded { return "Dentro de otro" }
        switch item.file.origin {
        case let .fileSystem(fs): return fs
        case let .carved(exact): return exact ? "Firma" : "Tamaño estimado"
        }
    }
}

private struct HealthLabel: View {
    @ObservedObject var item: Item
    @Environment(\.widthClass) private var width

    var body: some View {
        if let health = item.health {
            let (color, symbol) = HealthBadge.style(health)
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(color)
                if width == .regular {
                    Text(HealthBadge.title(health)).foregroundStyle(color)
                }
                Text("\(health)%").foregroundStyle(.secondary).monospacedDigit()
            }
            .font(.callout)
        } else {
            Text(item.healthNote).font(.callout).foregroundStyle(.tertiary).lineLimit(1)
        }
    }
}

private struct CompactResultList: View {
    @EnvironmentObject var model: AppModel
    let items: [Item]

    var body: some View {
        List(selection: $model.selection) {
            ForEach(items) { item in
                CompactResultRow(item: item)
                    .tag(item.id)
                    .onTapGesture(count: 2) { open(item) }
                    .contextMenu {
                        Button("Recuperar…") { model.recover([item]) }
                        if item.localURL != nil { Button("Abrir vista previa") { open(item) } }
                    }
            }
        }
        .listStyle(.inset)
    }

    private func open(_ item: Item) {
        if let url = item.localURL {
            NSWorkspace.shared.open(url)
        } else {
            model.prepare(item)
        }
    }
}

private struct CompactResultRow: View {
    @ObservedObject var item: Item

    var body: some View {
        HStack(spacing: 10) {
            ThumbnailView(item: item)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(ByteCountFormatter.string(fromByteCount: item.file.size, countStyle: .file))
                    if let year = item.year { Text("· \(String(year))") }
                    if let health = item.health {
                        let (color, symbol) = HealthBadge.style(health)
                        Image(systemName: symbol).foregroundStyle(color)
                        Text("\(health)%").foregroundStyle(color)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct ItemCell: View {
    @ObservedObject var item: Item
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            // Caja 4:3 fija: todas las tarjetas miden lo mismo, sea cual sea la proporción de la imagen.
            Color.primary.opacity(0.06)
                .aspectRatio(4 / 3, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay { ThumbnailView(item: item, fill: item.category == .photo || item.category == .video) }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                .overlay(alignment: .topTrailing) { HealthBadge(health: item.health).padding(6) }
                .overlay(alignment: .bottomLeading) {
                    if item.category == .video {
                        Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(.white).shadow(radius: 3).padding(6)
                    }
                }
            Text(item.name)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 4) {
                Text(ByteCountFormatter.string(fromByteCount: item.file.size, countStyle: .file))
                if let year = item.year { Text("· \(String(year))") }
                if item.file.embedded {
                    Spacer()
                    Image(systemName: "square.stack.3d.up").help("Estaba dentro de otro archivo")
                } else if item.hasOriginalName {
                    Spacer()
                    Image(systemName: "character.textbox").help("Nombre original recuperado")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(selected ? Palette.accent.opacity(0.16) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(selected ? Palette.accent : .clear, lineWidth: 2))
        .contentShape(Rectangle())
    }
}

struct HealthBadge: View {
    let health: Int?

    var body: some View {
        if let health {
            let (color, symbol) = HealthBadge.style(health)
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(color))
                .shadow(color: .black.opacity(0.3), radius: 2)
                .help("Recuperabilidad: \(health)%")
        }
    }

    static func style(_ h: Int) -> (Color, String) {
        h >= 70 ? (.green, "checkmark") : h >= 40 ? (.orange, "exclamationmark") : (.red, "xmark")
    }

    static func title(_ h: Int) -> String {
        h >= 70 ? "Recuperable" : h >= 40 ? "Parcialmente dañado" : "Dañado"
    }
}

/// Miniatura generada por Quick Look: funciona con fotos, videos, PDF, documentos de Office...
struct ThumbnailView: View {
    @ObservedObject var item: Item
    /// Llenar el recuadro (fotos, videos) o mostrar la miniatura entera (documentos).
    var fill = true
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                if fill {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(nsImage: image).resizable().scaledToFit()
                        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                        .padding(10)
                }
            } else {
                LinearGradient(colors: placeholderColors, startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(spacing: 6) {
                    Image(systemName: placeholderSymbol).font(.system(size: 34)).foregroundStyle(.white.opacity(0.9))
                    Text(item.file.ext.uppercased()).font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.8))
                }
            }
        }
        .task(id: item.localURL) {
            guard let url = item.localURL else { return }
            image = await ThumbnailCache.shared.thumbnail(for: url)
        }
    }

    private var placeholderSymbol: String {
        switch item.category {
        case .photo: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case .document: return "doc.richtext"
        case .archive: return "doc.zipper"
        case .other: return "doc"
        }
    }

    private var placeholderColors: [Color] {
        switch item.category {
        case .photo: return [.pink, .orange]
        case .video: return [.purple, .indigo]
        case .audio: return [.orange, .red]
        case .document: return [.blue, .cyan]
        case .archive: return [.brown, .orange]
        case .other: return [.gray, .secondary]
        }
    }
}

@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSURL, NSImage>()

    func thumbnail(for url: URL) async -> NSImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 340, height: 260),
                                                   scale: 2, representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        cache.setObject(rep.nsImage, forKey: url as NSURL)
        return rep.nsImage
    }
}
