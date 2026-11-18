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
                        .navigationSplitViewColumnWidth(min: 220, ideal: 248, max: 310)
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
        .sheet(isPresented: $model.showRecoverAll) { RecoverAllSheet() }
        .overlay(alignment: .bottom) { RecoverToast() }
    }

    private var detail: some View {
        let items = model.filtered
        return VStack(spacing: 0) {
            VStack(spacing: 0) {
                ScanBanner()
                workspaceControls(items)
                SmartQueryBar()
                Divider()
            }
            .background(.background)
            .zIndex(1)
            Gallery(layout: layout, items: items)
                .clipped()
        }
        .modifier(WindowToolbarClearance())
        .searchable(text: $model.search, placement: .toolbar, prompt: "Buscar archivos")
        .onSubmit(of: .search) { model.applySmartSelection() }
        .task(id: model.search) {
            do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
            model.applySmartSelection()
        }
        .safeAreaInset(edge: .bottom) { SelectionBar(showDetails: $showDetails) }
        .toolbar { resultsToolbar }
    }

    @ToolbarContentBuilder private var resultsToolbar: some ToolbarContent {
        ToolbarItem {
            Button {
                if width == .regular { showInspector.toggle() } else { showDetails = true }
            } label: {
                Label("Detalles", systemImage: "sidebar.trailing")
            }
            .help("Mostrar u ocultar los detalles del archivo")
        }
    }

    private func workspaceControls(_ items: [Item]) -> some View {
        let bytes = model.filteredBytes
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                resultCount(items.count, bytes: bytes)
                Spacer(minLength: 8)
                viewControls
                recoverButton(items)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    resultCount(items.count, bytes: bytes)
                    Spacer(minLength: 8)
                    recoverButton(items)
                }
                viewControls
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private func resultCount(_ count: Int, bytes: Int64) -> some View {
        ResultCount(count: count, bytes: bytes)
    }

    private var viewControls: some View {
        let hasFilters = model.filter != .all || model.year != nil || model.onlyRecoverable
            || model.hideSystemFiles || model.hideOverwritten
        return HStack(spacing: 8) {
            if hasFilters || !model.search.isEmpty {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { model.resetFilters() }
                    Signals.play(.tap)
                } label: {
                    Label("Ver todos", systemImage: "xmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Palette.accent.opacity(0.16), in: Capsule())
                        .foregroundStyle(Palette.accent)
                }
                .buttonStyle(PressableStyle())
                .transition(.scale.combined(with: .opacity))
                .help("Quitar filtros y búsqueda activos")
            }

            Button { showFilters = true } label: {
                Label("Filtros", systemImage: hasFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
            }
            .tint(hasFilters ? Palette.accent : nil)
            .help(hasFilters ? "Cambiar filtros activos" : "Filtrar resultados")

            if layout == .gallery {
                CardSizeSlider()
            }

            Picker("Vista", selection: $layout) {
                Image(systemName: "square.grid.2x2").accessibilityLabel("Galería").tag(ResultLayout.gallery)
                Image(systemName: "list.bullet").accessibilityLabel("Lista").tag(ResultLayout.list)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
            .help("Galería o lista")

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
                Label("Orden: \(model.sort.rawValue)", systemImage: "arrow.up.arrow.down")
                    .labelStyle(.iconOnly)
            }
            .help("Ordenar por: \(model.sort.rawValue)")
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func recoverButton(_ items: [Item]) -> some View {
        RecoverButton(noneVisible: items.isEmpty)
    }

    private var filterSheet: some View {
        NavigationStack {
            Sidebar(showNewScan: false)
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
            InspectorView(belowWindowToolbar: false)
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
    @Namespace private var sidebarMotion
    var showNewScan = true

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
        let summary = model.sidebarSummary
        VStack(spacing: 0) {
            if showNewScan {
                sourceHeader
                Divider()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    group("Biblioteca") {
                        row("Todos", "square.grid.2x2.fill", .all,
                            count: summary.counts[.all, default: 0],
                            bytes: summary.bytes[.all, default: 0], tint: Palette.accent)
                        row("Con nombre original", "character.textbox", .named,
                            count: summary.counts[.named, default: 0],
                            bytes: summary.bytes[.named, default: 0], tint: .green)
                    }
                    group("Tipos") {
                        ForEach(FileCategory.allCases, id: \.self) { c in
                            row(c.rawValue, symbol(c), .category(c),
                                count: summary.counts[.category(c), default: 0],
                                bytes: summary.bytes[.category(c), default: 0], tint: tint(c))
                        }
                    }
                    let years = summary.years
                    if !years.isEmpty {
                        group("Año") {
                            ForEach(years, id: \.year) { entry in
                                let selected = model.year == entry.year
                                filterRow(String(entry.year), "calendar", count: entry.count,
                                          tint: .secondary, selected: selected) {
                                    model.year = selected ? nil : entry.year
                                }
                            }
                        }
                    }
                    group("Filtros de estado") {
                        filterToggle("Ocultar archivos del sistema", isOn: $model.hideSystemFiles)
                        filterToggle("Solo recuperables", isOn: $model.onlyRecoverable)
                        if summary.hasEmbedded {
                            filterToggle("Ocultar archivos incrustados", isOn: $model.hideEmbedded)
                        }
                        filterToggle("Ocultar posibles sobrescritos", isOn: $model.hideOverwritten)
                    }
                    if !model.volumes.isEmpty {
                        group("Volúmenes detectados") {
                            ForEach(Array(model.volumes.enumerated()), id: \.offset) { _, v in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(v.name).font(.callout.weight(.medium)).lineLimit(1)
                                    Text(v.namesSupported ? "\(v.format) · con nombres" : "\(v.format) · escaneo profundo")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                            }
                        }
                    }
                }
                .padding(12)
            }
            .clipped()
            if showNewScan {
                Divider()
                VStack(spacing: 8) {
                    if !model.items.isEmpty {
                        Button { model.openRecoverAll() } label: {
                            Label("Recuperar datos (\(Bytes.gigabytes(model.totalBytes)))",
                                  systemImage: "externaldrive.fill.badge.arrow.down")
                                .lineLimit(1)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(CompactGlowButtonStyle())
                    }
                    Button { model.newScan() } label: {
                        Label("Nuevo escaneo", systemImage: "plus.circle").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(12)
            }
        }
        .modifier(WindowToolbarClearance(enabled: showNewScan))
    }

    private var sourceHeader: some View {
        HStack(spacing: 9) {
            Image(systemName: model.sourceSymbol)
                .foregroundStyle(Palette.accent)
                .frame(width: 30, height: 30)
                .background(Palette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.sourceName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(model.sourceName)
                Text(phaseText).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 8)
                .padding(.bottom, 3)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func filterToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
            Spacer(minLength: 0)
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
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

    private func row(_ title: String, _ symbol: String, _ tag: SidebarFilter,
                     count: Int, bytes: Int64 = 0, tint: Color) -> some View {
        filterRow(title, symbol, count: count, bytes: bytes, tint: tint,
                  pillID: model.year == nil ? "sidebarMain" : nil,
                  selected: model.filter == tag) {
            withAnimation(.snappy(duration: 0.22)) { model.filter = tag }
            Signals.play(.tap)
        }
    }

    private func filterRow(_ title: String, _ symbol: String, count: Int, bytes: Int64 = 0, tint: Color,
                           pillID: String? = nil, selected: Bool, action: @escaping () -> Void) -> some View {
        SidebarRowButton(
            title: title, symbol: symbol, count: count, bytes: bytes, tint: tint,
            selected: selected, namespace: sidebarMotion, pillID: pillID, action: action
        )
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

private struct SidebarRowButton: View {
    let title: String
    let symbol: String
    let count: Int
    let bytes: Int64
    let tint: Color
    let selected: Bool
    let namespace: Namespace.ID
    let pillID: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(selected ? Palette.accent : tint)
                    .frame(width: 16)
                    .scaleEffect(hovering ? 1.1 : 1)
                Text(title)
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .opacity(selected ? 1.0 : 0.88)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(count.formatted())
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(selected ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(.secondary))
                    if count > 0, bytes > 0 {
                        Text(Bytes.format(bytes))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background {
                if selected {
                    if let pillID {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Palette.subtleSurface)
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.borderStroke))
                            .matchedGeometryEffect(id: pillID, in: namespace)
                    } else {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Palette.subtleSurface)
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.borderStroke))
                    }
                } else if hovering {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Palette.accent.opacity(0.06))
                }
            }
            .contentShape(Rectangle())
            .animation(.snappy(duration: 0.16), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
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
    @EnvironmentObject var live: LiveStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 11) {
                Image(systemName: model.sourceSymbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Palette.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: Palette.accent.opacity(0.32), radius: 7, y: 2)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.sourceName.isEmpty ? "Escaneo" : model.sourceName)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityAddTraits(.isHeader)
                    Label(title, systemImage: phaseSymbol)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .symbolEffect(.pulse, isActive: model.phase.isScanning)
                }
                .layoutPriority(1)
                Spacer(minLength: 6)
                if model.phase.isScanning {
                    Button { model.stop() } label: { Label("Detener", systemImage: "stop.fill") }
                        .help("Detener el escaneo")
                } else {
                    VStack(alignment: .trailing, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(model.items.count.formatted())
                                .font(.system(size: 19, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                            Text("encontrados")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if model.totalBytes > 0 {
                            Button {
                                model.openRecoverAll()
                            } label: {
                                Label(Bytes.gigabytesDetailed(model.totalBytes), systemImage: "scalemass.fill")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Palette.accent)
                                    .monospacedDigit()
                                    .contentTransition(.numericText())
                            }
                            .buttonStyle(.borderless)
                            .help("Ver desglose en gigas (GB) y formas de recuperar")
                        }
                    }
                }
            }
            if model.phase == .deep, let progress = live.progress {
                ShimmerBar(value: progress.fraction, active: true, height: 8)
                    .accessibilityLabel("Avance del escaneo profundo")
                if let reading = readingSummary {
                    Text(reading)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            if case let .failed(message) = model.phase {
                Text(message).font(.caption).foregroundStyle(.secondary)
            } else {
                Label("Búsqueda: \(model.scanFilter.summary)", systemImage: "line.3.horizontal.decrease")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if live.badSectors > 0 {
                Label("\(live.badSectors.formatted()) sectores ilegibles", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.phase.isScanning, !model.items.isEmpty {
                Text("\(model.items.count == 1 ? "1 archivo encontrado" : "\(model.items.count.formatted()) archivos encontrados") · \(Bytes.gigabytesDetailed(model.totalBytes))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.accent)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            let pending = model.pendingCount
            if pending > 0 {
                Text(pending == 1 ? "1 archivo pendiente de comprobar por fecha"
                     : "\(pending.formatted()) archivos pendientes de comprobar por fecha")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Palette.subtleSurface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Palette.borderStroke) }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var phaseSymbol: String {
        switch model.phase {
        case .finished: return "checkmark.circle"
        case .cancelled: return "stop.circle"
        case .failed: return "exclamationmark.circle"
        default: return "magnifyingglass"
        }
    }

    private var title: String {
        switch model.phase {
        case .quick: return "Buscando nombres originales"
        case .deep: return "Escaneo profundo"
        case .finished: return "Escaneo completo"
        case .cancelled: return "Escaneo detenido"
        case .failed: return "No se pudo escanear"
        default: return ""
        }
    }

    private var readingSummary: String? {
        guard let p = live.progress else { return nil }
        let fmt = { (b: Int64) in ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
        let read = "\(fmt(p.scanned)) de \(fmt(p.total))"
        guard p.bytesPerSecond > 0 else { return read }
        let remaining = Double(max(0, p.total - p.scanned)) / p.bytesPerSecond
        return "\(read) · \(fmt(Int64(p.bytesPerSecond)))/s · ~\(Analyzer.formatDuration(remaining)) restantes"
    }
}

// MARK: - Galería

struct Gallery: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.widthClass) private var width
    var layout: ResultLayout
    let items: [Item]
    @FocusState private var focused: Bool
    @State private var perRow = 4
    /// Tamaño de las tarjetas (deslizador, pellizco en el trackpad o ⌘+ / ⌘−).
    @AppStorage("tamano") private var cardSize = CardSize.standard
    @State private var pinchStart: Double?

    private var columns: [GridItem] {
        switch width {
        case .compact: return [GridItem(.adaptive(minimum: min(150, cardSize)), spacing: 12)]
        case .medium: return [GridItem(.adaptive(minimum: cardSize * 0.94, maximum: cardSize * 1.24), spacing: 16)]
        case .regular: return [GridItem(.adaptive(minimum: cardSize, maximum: cardSize), spacing: 18)]
        }
    }

    var body: some View {
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
        .background(.background)
        .overlay { empty(items) }
    }

    private func gallery(_ items: [Item]) -> some View {
        let padding: CGFloat = width == .compact ? 12 : 24
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 22) {
                    ForEach(items) { item in
                        ItemCell(item: item,
                                 onPreview: {
                                     model.select([item.id])
                                     model.viewerOpen = true
                                 },
                                 onRecover: { model.recover([item]) })
                            .onTapGesture {
                                // Un solo gesto: el clic selecciona al instante (sin esperar a ver si
                                // viene un segundo) y el segundo clic de un doble clic abre el visor.
                                focused = true
                                let click = NSApp.currentEvent
                                if (click?.clickCount ?? 1) >= 2, (click?.modifierFlags ?? []).isDisjoint(with: [.command, .shift]) {
                                    model.select([item.id])
                                    model.viewerOpen = true
                                } else {
                                    model.tap(item)
                                }
                            }
                            .contextMenu {
                                Button("Vista previa") {
                                    model.select([item.id])
                                    model.viewerOpen = true
                                }
                                Button("Recuperar…") { model.recover([item]) }
                                Button("Abrir con macOS") { model.openExternally(item) }
                            }
                    }
                }
                .padding(padding)
            }
            .onGeometryChange(for: Int.self, of: { geo in
                // Cuántas tarjetas caben por fila, para que ↑ y ↓ salten una fila exacta.
                let (minimum, spacing): (CGFloat, CGFloat) = width == .compact ? (min(150, cardSize), 12)
                    : width == .medium ? (cardSize * 0.94, 16) : (cardSize, 18)
                return max(1, Int((geo.size.width - padding * 2 + spacing) / (minimum + spacing)))
            }) { perRow = $0 }
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        let start = pinchStart ?? cardSize
                        pinchStart = start
                        let next = CardSize.clamp(start * value.magnification)
                        // De a pasos: rearmar la grilla en cada cuadro del pellizco no hace falta.
                        if abs(next - cardSize) >= 4 { cardSize = next }
                    }
                    .onEnded { _ in pinchStart = nil }
            )
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow], phases: [.down, .repeat]) { press in
                let delta: Int
                switch press.key {
                case .leftArrow: delta = -1
                case .rightArrow: delta = 1
                case .upArrow: delta = -perRow
                default: delta = perRow
                }
                if let item = model.step(delta) { proxy.scrollTo(item.id) }
                return .handled
            }
            .onKeyPress(keys: [.space, .return]) { _ in
                guard model.focused != nil else { return .ignored }
                model.viewerOpen = true
                return .handled
            }
            .onKeyPress(keys: ["a"]) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                model.selectAll()
                return .handled
            }
            .onAppear { focused = true }
            .background(ReturnFocus(focused: $focused))
        }
    }

    @ViewBuilder private func empty(_ items: [Item]) -> some View {
        if items.isEmpty {
            if model.phase.isScanning {
                ContentUnavailableView("Buscando…", systemImage: "magnifyingglass",
                                       description: Text("Los archivos aparecerán aquí a medida que se encuentren."))
            } else if !model.search.isEmpty {
                ContentUnavailableView.search(text: model.search)
            } else if !model.items.isEmpty {
                ContentUnavailableView {
                    Label("No hay resultados con estos filtros", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text("Prueba otra categoría o quita los filtros activos para ver los \(model.items.count.formatted()) archivos encontrados.")
                } actions: {
                    Button("Mostrar todos los archivos") {
                        withAnimation(.snappy) { model.resetFilters() }
                    }
                    .buttonStyle(CompactGlowButtonStyle())
                }
            } else {
                ContentUnavailableView("No se encontraron archivos", systemImage: "externaldrive.badge.questionmark",
                                       description: Text("Puedes iniciar otro escaneo y cambiar qué tipos de archivo buscas."))
            }
        }
    }
}

struct ResultTable: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var focus: Focus
    @State private var hasRoomForMetadata = false
    let items: [Item]

    var body: some View {
        Group {
            if hasRoomForMetadata { fullTable } else { shortTable }
        }
        .onGeometryChange(for: Bool.self, of: { $0.size.width >= 800 }) { hasRoomForMetadata = $0 }
    }

    private var fullTable: some View {
        Table(items, selection: Binding(get: { focus.selection }, set: model.select)) {
            fileColumn.width(min: 235, ideal: 360)
            sizeColumn.width(min: 75, ideal: 85, max: 100)
            TableColumn("Fecha") { item in
                Text(item.date?.formatted(date: .abbreviated, time: .omitted) ?? "—")
                    .foregroundStyle(.secondary)
            }
            .width(min: 105, ideal: 116, max: 130)
            TableColumn("Origen") { item in
                OriginLabel(item: item)
            }
            .width(min: 80, ideal: 96, max: 120)
            stateColumn.width(min: 108, ideal: 114, max: 138)
        }
        .modifier(TableActions())
    }

    private var shortTable: some View {
        Table(items, selection: Binding(get: { focus.selection }, set: model.select)) {
            fileColumn.width(min: 165, ideal: 300)
            sizeColumn.width(min: 70, ideal: 80, max: 96)
            stateColumn.width(min: 102, ideal: 110, max: 126)
        }
        .modifier(TableActions())
    }

    private var fileColumn: TableColumn<Item, Never, FileNameCell, Text> {
        TableColumn("Archivo") { item in
            FileNameCell(item: item)
        }
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
            .tableStyle(.inset(alternatesRowBackgrounds: false))
            .contextMenu(forSelectionType: Int.self) { ids in
                Button("Vista previa") {
                    model.select(ids)
                    model.viewerOpen = true
                }
                Button("Recuperar…") { model.recover(model.items(ids: ids)) }
                if let item = model.items(ids: ids).first {
                    Button("Abrir con macOS") { model.openExternally(item) }
                }
            } primaryAction: { ids in
                model.select(ids)
                if model.focused != nil { model.viewerOpen = true }
            }
            .onKeyPress(.space) {
                guard model.focused != nil else { return .ignored }
                model.viewerOpen = true
                return .handled
            }
    }
}

private struct FileNameCell: View {
    @ObservedObject var item: Item

    var body: some View {
        HStack(spacing: 9) {
            RowThumbnail(item: item, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let folder = item.file.folder, folder != "/" {
                    Text(folder).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .padding(.vertical, 3)
        .help(item.name)
    }
}

struct ResultFileIcon: View {
    let category: FileCategory
    var size: CGFloat = 26

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.48, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: size * 0.25))
            .accessibilityHidden(true)
    }

    private var symbol: String {
        switch category {
        case .photo: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case .document: return "doc.text"
        case .archive: return "archivebox"
        case .other: return "doc"
        }
    }

    private var tint: Color {
        switch category {
        case .photo: return .pink
        case .video: return .purple
        case .audio: return .orange
        case .document: return .blue
        case .archive: return .brown
        case .other: return .secondary
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

    var body: some View {
        if let health = item.health {
            let (color, symbol) = HealthBadge.style(health)
            HStack(spacing: 5) {
                Image(systemName: symbol).foregroundStyle(color)
                Text("\(health)%").monospacedDigit()
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.primary)
            .accessibilityLabel("\(HealthBadge.title(health)), \(health) por ciento")
            .help(HealthBadge.title(health))
        } else {
            Text(item.preparing ? "Analizando…" : item.analyzed ? "No comprobable" : "Sin analizar")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(item.healthNote)
        }
    }
}

private struct CompactResultList: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var focus: Focus
    let items: [Item]

    var body: some View {
        List(selection: Binding(get: { focus.selection }, set: model.select)) {
            ForEach(items) { item in
                CompactResultRow(item: item)
                    .tag(item.id)
                    .onTapGesture(count: 2) { open(item) }
                    .contextMenu {
                        Button("Recuperar…") { model.recover([item]) }
                        Button("Vista previa") { open(item) }
                    }
            }
        }
        .listStyle(.inset)
    }

    private func open(_ item: Item) {
        model.select([item.id])
        model.viewerOpen = true
    }
}

private struct CompactResultRow: View {
    @ObservedObject var item: Item

    var body: some View {
        HStack(spacing: 10) {
            RowThumbnail(item: item, size: 34)
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
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

struct ItemCell: View {
    @ObservedObject var item: Item
    var onPreview: () -> Void = {}
    var onRecover: () -> Void = {}
    @State private var hovering = false
    private var selected: Bool { item.isSelected }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            // Caja 4:3 fija: todas las tarjetas miden lo mismo, sea cual sea la proporción de la imagen.
            Color.primary.opacity(0.06)
                .aspectRatio(4 / 3, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay {
                    ThumbnailView(item: item, fill: item.category == .photo || item.category == .video)
                        // Al pasar el puntero la imagen se acerca un poco dentro del marco.
                        .scaleEffect(hovering ? 1.05 : 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    if hovering {
                        HStack(spacing: 6) {
                            quickAction("eye.fill", help: "Vista previa (espacio)", action: onPreview)
                            quickAction("arrow.down.to.line", help: "Recuperar este archivo", action: onRecover)
                        }
                        .padding(7)
                        .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .bottomTrailing)))
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                .overlay(alignment: .topTrailing) { HealthBadge(health: item.health).padding(6) }
                .overlay(alignment: .bottomLeading) {
                    if item.category == .video {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(.black.opacity(0.55), in: Circle())
                            .padding(6)
                            .accessibilityHidden(true)
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
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(selected ? AnyShapeStyle(Palette.subtleSurface) : AnyShapeStyle(hovering ? Palette.accent.opacity(0.06) : .clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    selected ? AnyShapeStyle(Palette.gradient) : AnyShapeStyle(hovering ? Palette.accent.opacity(0.28) : .clear),
                    lineWidth: selected ? 2 : 1
                )
        )
        .shadow(color: Palette.accent.opacity(selected ? 0.25 : (hovering ? 0.14 : 0)),
                radius: selected ? 10 : (hovering ? 9 : 0),
                y: hovering ? 4 : 2)
        .offset(y: hovering ? -2.5 : 0)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.22, dampingFraction: 0.78), value: hovering)
        .animation(.snappy(duration: 0.16), value: selected)
    }

    private func quickAction(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        QuickActionCircle(symbol: symbol, help: help, action: action)
    }
}

private struct QuickActionCircle: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 27, height: 27)
                .background(
                    Circle().fill(hover ? AnyShapeStyle(Palette.gradient) : AnyShapeStyle(.black.opacity(0.65)))
                )
                .overlay(Circle().strokeBorder(.white.opacity(hover ? 0.5 : 0.25)))
                .shadow(color: Palette.accent.opacity(hover ? 0.5 : 0), radius: 6, y: 2)
                .scaleEffect(hover ? 1.08 : 1)
                .contentShape(Circle())
                .animation(.snappy(duration: 0.14), value: hover)
        }
        .buttonStyle(PressableStyle())
        .onHover { hover = $0 }
        .help(help)
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

/// Miniatura de un resultado. Se pide solo mientras la tarjeta está en pantalla: al salir,
/// SwiftUI cancela la tarea y la lectura del disco no llega a hacerse.
struct ThumbnailView: View {
    @ObservedObject var item: Item
    /// Llenar el recuadro (fotos, videos) o mostrar la miniatura entera (documentos).
    var fill = true
    @State private var image: NSImage?

    var body: some View {
        let shown = image ?? ThumbnailStore.shared.cached(item.id)
        ZStack {
            if let shown {
                if fill {
                    Image(nsImage: shown).resizable().scaledToFill()
                } else {
                    Image(nsImage: shown).resizable().scaledToFit()
                        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                        .padding(10)
                }
            } else {
                VStack(spacing: 8) {
                    ResultFileIcon(category: item.category, size: 40)
                    if !item.file.ext.isEmpty {
                        Text(item.file.ext.uppercased())
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityHidden(true)
            }
        }
        .animation(.easeOut(duration: 0.12), value: shown != nil)
        // Cuando el archivo ya se extrajo se reintenta: algunos tipos solo tienen miniatura así.
        .task(id: item.localURL != nil) {
            guard image == nil else { return }
            // Al desplazar rápido, las tarjetas que pasan de largo no llegan a leer el disco.
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            image = await ThumbnailStore.shared.thumbnail(for: item)
        }
    }
}

/// Miniatura pequeña para las filas de la lista; si no hay, el ícono del tipo.
struct RowThumbnail: View {
    @ObservedObject var item: Item
    let size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let shown = image ?? ThumbnailStore.shared.cached(item.id) {
                Image(nsImage: shown).resizable().scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
                    .accessibilityHidden(true)
            } else {
                ResultFileIcon(category: item.category, size: size)
            }
        }
        .task(id: item.localURL != nil) {
            guard image == nil, item.category == .photo || item.category == .video else { return }
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            image = await ThumbnailStore.shared.thumbnail(for: item)
        }
    }
}


// MARK: - Piezas que dependen de la selección

/// Devuelve el teclado a la galería al cerrar el visor. Es una vista vacía aparte para que la
/// galería no tenga que observar la selección.
private struct ReturnFocus: View {
    @EnvironmentObject private var focus: Focus
    var focused: FocusState<Bool>.Binding

    var body: some View {
        Color.clear
            .onChange(of: focus.viewerOpen) { _, open in if !open { focused.wrappedValue = true } }
    }
}

private struct ResultCount: View {
    @EnvironmentObject private var focus: Focus
    let count: Int
    let bytes: Int64

    var body: some View {
        let selected = focus.selection.count
        let subtitle: String = {
            if selected == 0 {
                let base = count == 1 ? "1 archivo visible" : "\(count.formatted()) archivos visibles"
                return count > 0 ? "\(base) · \(Bytes.gigabytesDetailed(bytes))" : base
            }
            let base = selected == 1 ? "1 seleccionado" : "\(selected.formatted()) seleccionados"
            return "\(base) · \(Bytes.gigabytesDetailed(focus.selectedBytes))"
        }()
        VStack(alignment: .leading, spacing: 3) {
            Text("Resultados").font(.headline).accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.2), value: selected)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct RecoverButton: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var focus: Focus
    let noneVisible: Bool

    var body: some View {
        let hasSelection = !focus.selection.isEmpty
        let hasFilter = model.filter != .all || model.year != nil || !model.search.isEmpty
            || model.onlyRecoverable || model.hideSystemFiles || model.hideOverwritten
        let totalGB = model.totalBytes > 0 ? " (\(Bytes.gigabytes(model.totalBytes)))" : ""

        HStack(spacing: 8) {
            if hasSelection {
                Button {
                    model.recoverResults()
                } label: {
                    Label("Recuperar selección (\(Bytes.gigabytes(focus.selectedBytes)))", systemImage: "arrow.down.doc.fill")
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)
                .fixedSize()
                .help("Recuperar directamente los archivos seleccionados")
            } else if hasFilter, !noneVisible {
                Button {
                    model.recoverResults()
                } label: {
                    Label("Recuperar visibles (\(Bytes.gigabytes(model.filteredBytes)))", systemImage: "arrow.down.doc")
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)
                .fixedSize()
                .help("Recuperar los archivos visibles con el filtro actual")
            }

            Button {
                model.openRecoverAll(mode: .all)
            } label: {
                Label("Recuperar datos\(totalGB)", systemImage: "externaldrive.fill.badge.arrow.down")
                    .lineLimit(1)
            }
            .buttonStyle(CompactGlowButtonStyle())
            .disabled(model.items.isEmpty)
            .fixedSize()
            .help("Ver cuántos gigas (GB) son y elegir entre distintas formas de recuperar")
        }
    }
}

private struct SelectionBar: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var focus: Focus
    @Environment(\.widthClass) private var width
    @Binding var showDetails: Bool

    var body: some View {
        if width != .regular, !focus.selection.isEmpty {
            HStack(spacing: 12) {
                Text(title).lineLimit(1).truncationMode(.middle)
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

    private var title: String {
        if focus.selection.count == 1, let name = model.focused?.name { return name }
        return "\(focus.selection.count.formatted()) seleccionados · \(Bytes.format(focus.selectedBytes))"
    }
}

/// Avance de la recuperación: barra de progreso en bytes, velocidad, resultado y acceso a Finder.
private struct RecoverToast: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveStatus

    var body: some View {
        ZStack {
            if let status = live.recover {
                HStack(spacing: 12) {
                    icon(status)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(title(status))
                            .font(.headline)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        if !status.finished {
                            ShimmerBar(value: fraction(status), active: true, height: 8)
                                .frame(minWidth: 220, maxWidth: 320)
                            Text(progressSubtitle(status))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .contentTransition(.numericText())
                        } else if let sub = finishedSubtitle(status) {
                            Text(sub)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    if !status.finished {
                        Button("Detener") { model.stopRecovery() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("Detener la recuperación conservando lo ya copiado")
                    }
                    if status.finished, let folder = status.folder {
                        Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                            .buttonStyle(CompactGlowButtonStyle())
                    }
                    if status.finished {
                        Button { live.recover = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Cerrar")
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 13)
                .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Palette.borderStroke, lineWidth: 1.2))
                .shadow(color: Palette.accent.opacity(0.24), radius: 16, y: 6)
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: live.recover?.finished)
        .animation(.snappy(duration: 0.25), value: live.recover == nil)
    }

    private func fraction(_ status: RecoverStatus) -> Double {
        if status.bytesTotal > 0 {
            return min(1, max(0, Double(status.bytesDone) / Double(status.bytesTotal)))
        }
        return min(1, max(0, Double(status.done) / Double(max(1, status.total))))
    }

    private func progressSubtitle(_ status: RecoverStatus) -> String {
        var parts = ["\(Bytes.gigabytes(status.bytesDone)) de \(Bytes.gigabytes(status.bytesTotal))"]
        let speed = status.speed
        if speed > 0 {
            parts.append("\(Bytes.format(Int64(speed)))/s")
            let remainingBytes = max(0, status.bytesTotal - status.bytesDone)
            if remainingBytes > 0 {
                parts.append("~\(Analyzer.formatDuration(Double(remainingBytes) / speed)) restantes")
            }
        }
        return parts.joined(separator: " · ")
    }

    private func finishedSubtitle(_ status: RecoverStatus) -> String? {
        var parts: [String] = []
        if status.bytesDone > 0 { parts.append(Bytes.gigabytesDetailed(status.bytesDone)) }
        if let reason = status.stopReason { parts.append(reason) }
        if status.failed > 0 { parts.append("\(status.failed.formatted()) no se pudieron copiar") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder private func icon(_ status: RecoverStatus) -> some View {
        let problem = status.failed > 0 || status.stopped
        Image(systemName: !status.finished ? "arrow.down.circle" : !problem ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            .font(.title2)
            .foregroundStyle(!status.finished ? Palette.accent : !problem ? .green : .orange)
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.bounce, value: status.finished)
    }

    private func title(_ status: RecoverStatus) -> String {
        guard status.finished else {
            return "Recuperando \(status.done.formatted()) de \(status.total.formatted())…"
        }
        let ok = max(0, status.done - status.failed)
        if status.stopped {
            return "Detenido · \(ok.formatted()) recuperados"
        }
        return ok == 1 ? "1 archivo recuperado" : "\(ok.formatted()) archivos recuperados"
    }
}


// MARK: - Tamaño de las tarjetas

enum CardSize {
    static let standard = 178.0
    static let range = 128.0...260.0
    static func clamp(_ value: Double) -> Double { min(range.upperBound, max(range.lowerBound, value)) }
}

private struct CardSizeSlider: View {
    @AppStorage("tamano") private var cardSize = CardSize.standard

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "photo").font(.system(size: 9))
            Slider(value: $cardSize, in: CardSize.range)
                .controlSize(.mini)
                .frame(width: 80)
            Image(systemName: "photo").font(.system(size: 13))
        }
        .foregroundStyle(.secondary)
        .help("Tamaño de las miniaturas (⌘+ / ⌘−, o pellizca en el trackpad)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tamaño de las miniaturas")
    }
}
