import AppKit
import RecoveryCore
import SwiftUI

/// Centro «Recuperar datos»: mide cuántos gigabytes (GB) ocupa el escaneo en total y por categoría,
/// ofrece distintas formas de recuperar (todo, por tipos, con nombre original, vista/selección o por
/// tandas de GB) y comprueba el espacio libre en todos los discos conectados sin borrar lo escaneado.
struct RecoverAllSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var scope = EverythingScope()
    @State private var destination: DestinationInfo?
    @State private var volumes: [DestinationInfo] = []
    @State private var appeared = false

    private let batchPresets = [16, 32, 64, 128, 250]

    var body: some View {
        let summary = model.everythingSummary(for: scope)
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    heroCard(summary)
                    modeSection(summary)
                    modeDetailSection(summary)
                    fineTuneSection(summary)
                    destinationSection(summary)
                }
                .padding(20)
            }
            Divider()
            footer(summary)
        }
        .background(ThemedBackground())
        .frame(minWidth: 580, idealWidth: 660, maxWidth: 760, minHeight: 560, idealHeight: 690)
        .onAppear {
            scope.mode = model.initialRecoverMode
            volumes = DestinationInfo.mountedVolumes()
            withAnimation(.spring(response: 0.45, dampingFraction: 0.84)) { appeared = true }
        }
    }

    // MARK: - Cabecera

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.fill.badge.arrow.down")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Palette.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: Palette.accent.opacity(0.35), radius: 8, y: 3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("Recuperar datos")
                        .font(.title3.weight(.bold))
                    VersionPill(text: "3.2.1")
                }
                Text("Mide cuántos gigas (GB) ocupan tus archivos en «\(model.sourceName.isEmpty ? "el disco" : model.sourceName)» y elige cómo recuperarlos sin borrar el escaneo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Medidor principal en Gigas

    private func heroCard(_ summary: EverythingSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("TAMAÑO A RECUPERAR EN GIGAS", systemImage: "scalemass.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Palette.accent)
                    Text(Bytes.gigabytes(summary.selected.bytes))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Palette.gradient)
                        .contentTransition(.numericText())
                    if summary.selected.bytes > 0 && (summary.selected.bytes < 1_000_000_000 || summary.selected.bytes >= 1_000_000_000_000) {
                        Text("Equivale a \(Bytes.format(summary.selected.bytes))")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("ARCHIVOS ELEGIDOS")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text(summary.selected.count.formatted())
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(scope.mode.title)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Palette.accent.opacity(0.16), in: Capsule())
                        .foregroundStyle(Palette.accent)
                }
            }

            stackedCategoryBar(summary)

            HStack(spacing: 6) {
                Image(systemName: "internaldrive")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Total escaneado en el disco: \(summary.everything.count.formatted()) archivos · \(Bytes.gigabytesDetailed(summary.everything.bytes))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if summary.largest > 0 {
                    Text("Archivo mayor: \(Bytes.gigabytesDetailed(summary.largest))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .background(Palette.subtleSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Palette.borderStroke, lineWidth: 1.4)
        }
        .animation(.snappy(duration: 0.22), value: scope)
    }

    @ViewBuilder
    private func stackedCategoryBar(_ summary: EverythingSummary) -> some View {
        let total = max(1, summary.allMatchingToggles.bytes)
        let activeCats = FileCategory.allCases.compactMap { cat -> (FileCategory, Int64)? in
            guard let t = summary.byCategory[cat], t.bytes > 0 else { return nil }
            if scope.mode == .categories && !scope.categories.contains(cat) { return nil }
            return (cat, t.bytes)
        }
        if !activeCats.isEmpty {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(activeCats, id: \.0) { cat, bytes in
                        let w = max(4, geo.size.width * CGFloat(Double(bytes) / Double(total)))
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(CategoryStyle.tint(cat).gradient)
                            .frame(width: appeared ? w : 0)
                            .help("\(cat.rawValue): \(Bytes.gigabytesDetailed(bytes))")
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 8)
            .padding(2)
            .background(.primary.opacity(0.07), in: Capsule())
            .clipShape(Capsule())
        }
    }

    // MARK: - 1. Formas de recuperar

    private func modeSection(_ summary: EverythingSummary) -> some View {
        let cols = [GridItem(.adaptive(minimum: 185, maximum: 260), spacing: 10)]
        return VStack(alignment: .leading, spacing: 10) {
            Text("1. Elige cómo recuperar")
                .font(.subheadline.weight(.semibold))
            LazyVGrid(columns: cols, spacing: 10) {
                ForEach(RecoveryMode.allCases) { mode in
                    let active = scope.mode == mode
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                            scope.mode = mode
                        }
                        Signals.play(.tap)
                    } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 8) {
                                Image(systemName: mode.symbol)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(active ? .white : Palette.accent)
                                    .frame(width: 28, height: 28)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(active ? AnyShapeStyle(Palette.gradient) : AnyShapeStyle(Palette.accent.opacity(0.14)))
                                    )
                                Spacer()
                                Text(modeBadge(mode, summary: summary))
                                    .font(.caption.weight(.bold).monospacedDigit())
                                    .foregroundStyle(active ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(.secondary))
                                    .lineLimit(1)
                            }
                            Text(mode.title)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(mode.subtitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, minHeight: 98, alignment: .topLeading)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .background {
                            if active {
                                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.subtleSurface)
                            }
                        }
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(
                                    active ? AnyShapeStyle(Palette.gradient) : AnyShapeStyle(Palette.accent.opacity(0.14)),
                                    lineWidth: active ? 2 : 1
                                )
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                }
            }
        }
    }

    private func modeBadge(_ mode: RecoveryMode, summary: EverythingSummary) -> String {
        switch mode {
        case .all:
            return Bytes.gigabytes(summary.allMatchingToggles.bytes)
        case .categories:
            var bytes: Int64 = 0
            for c in scope.categories { bytes += summary.byCategory[c]?.bytes ?? 0 }
            return Bytes.gigabytes(bytes)
        case .named:
            return Bytes.gigabytes(summary.named.bytes)
        case .current:
            let t = (!model.selection.isEmpty && !scope.useFilteredInsteadOfSelection)
                ? summary.currentSelection : summary.currentFiltered
            return Bytes.gigabytes(t.bytes)
        case .batches:
            let n = max(1, summary.batches.count)
            return n == 1 ? "1 tanda" : "\(n) tandas"
        }
    }

    // MARK: - Detalle según la modalidad elegida

    @ViewBuilder
    private func modeDetailSection(_ summary: EverythingSummary) -> some View {
        switch scope.mode {
        case .all:
            categoryBreakdown(summary, interactive: false)
        case .categories:
            categoryBreakdown(summary, interactive: true)
        case .named:
            namedDetailCard(summary)
        case .current:
            currentViewDetailCard(summary)
        case .batches:
            batchesDetailCard(summary)
        }
    }

    private func categoryBreakdown(_ summary: EverythingSummary, interactive: Bool) -> some View {
        let rows = FileCategory.allCases
            .compactMap { cat -> (FileCategory, Tally)? in
                guard let t = summary.byCategory[cat], t.count > 0 else { return nil }
                return (cat, t)
            }
            .sorted { $0.1.bytes > $1.1.bytes }
        let maxBytes = max(1, rows.first?.1.bytes ?? 1)

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(interactive ? "Marca qué tipos recuperar" : "Desglose en GB por tipo de archivo")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if interactive {
                    HStack(spacing: 6) {
                        presetChip("Todos") {
                            scope.categories = Set(FileCategory.allCases)
                        }
                        presetChip("Fotos y Docs") {
                            scope.categories = [.photo, .document]
                        }
                        presetChip("Multimedia") {
                            scope.categories = [.photo, .video, .audio]
                        }
                        presetChip("Sin videos") {
                            scope.categories = Set(FileCategory.allCases).subtracting([.video])
                        }
                    }
                } else if rows.count > 1 {
                    Button("Elegir tipos…") {
                        withAnimation(.snappy) { scope.mode = .categories }
                        Signals.play(.tap)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.accent)
                }
            }

            VStack(spacing: 8) {
                ForEach(rows, id: \.0) { cat, tally in
                    let checked = !interactive || scope.categories.contains(cat)
                    Button {
                        if !interactive {
                            withAnimation(.snappy) {
                                scope.mode = .categories
                                scope.categories = [cat]
                            }
                        } else {
                            withAnimation(.snappy(duration: 0.18)) {
                                if scope.categories.contains(cat) {
                                    scope.categories.remove(cat)
                                } else {
                                    scope.categories.insert(cat)
                                }
                            }
                        }
                        Signals.play(.tap)
                    } label: {
                        VStack(spacing: 5) {
                            HStack(spacing: 8) {
                                if interactive {
                                    Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(checked ? AnyShapeStyle(Palette.gradient) : AnyShapeStyle(.secondary))
                                        .contentTransition(.symbolEffect(.replace))
                                }
                                Image(systemName: CategoryStyle.symbol(cat))
                                    .foregroundStyle(CategoryStyle.tint(cat))
                                    .frame(width: 18)
                                Text(cat.rawValue)
                                    .font(.callout.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text("\(tally.count.formatted()) archivos")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(Bytes.gigabytesDetailed(tally.bytes))
                                    .font(.callout.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(checked ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                            }
                            GeometryReader { geo in
                                let ratio = (appeared && checked) ? max(0.015, Double(tally.bytes) / Double(maxBytes)) : 0
                                ZStack(alignment: .leading) {
                                    Capsule().fill(.primary.opacity(0.07))
                                    Capsule().fill(CategoryStyle.tint(cat).gradient)
                                        .frame(width: geo.size.width * ratio)
                                }
                            }
                            .frame(height: 6)
                        }
                        .opacity(checked ? 1 : 0.5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func presetChip(_ title: String, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.18)) { action() }
            Signals.play(.tap)
        } label: {
            Text(title)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Palette.accent.opacity(0.13), in: Capsule())
                .foregroundStyle(Palette.accent)
        }
        .buttonStyle(PressableStyle())
    }

    private func namedDetailCard(_ summary: EverythingSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Archivos con nombre y carpeta original")
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 12) {
                Image(systemName: summary.named.count > 0 ? "folder.fill.badge.person.crop" : "info.circle.fill")
                    .font(.title2)
                    .foregroundStyle(summary.named.count > 0 ? Palette.accent : .orange)
                VStack(alignment: .leading, spacing: 3) {
                    if summary.named.count > 0 {
                        Text("\(summary.named.count.formatted()) archivos conservan su nombre real y estructura de carpetas (\(Bytes.gigabytesDetailed(summary.named.bytes))).")
                            .font(.callout.weight(.medium))
                        Text("Omite los fragmentos sin nombre del escaneo profundo para ahorrar espacio y mantener tus carpetas ordenadas.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Este escaneo no encontró nombres del sistema de archivos (por ejemplo, tras formatear el disco).")
                            .font(.callout.weight(.medium))
                        Text("Usa «Todo lo escaneado» o «Por tipo de archivo» para recuperar los \(summary.allMatchingToggles.count.formatted()) archivos encontrados por firma.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func currentViewDetailCard(_ summary: EverythingSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Vista filtrada o selección actual")
                .font(.subheadline.weight(.semibold))
            VStack(alignment: .leading, spacing: 10) {
                if summary.currentSelection.count > 0 {
                    HStack(spacing: 8) {
                        choicePill(
                            title: "Mi selección (\(summary.currentSelection.count.formatted()) · \(Bytes.gigabytes(summary.currentSelection.bytes)))",
                            selected: !scope.useFilteredInsteadOfSelection
                        ) {
                            scope.useFilteredInsteadOfSelection = false
                        }
                        choicePill(
                            title: "Vista filtrada (\(summary.currentFiltered.count.formatted()) · \(Bytes.gigabytes(summary.currentFiltered.bytes)))",
                            selected: scope.useFilteredInsteadOfSelection
                        ) {
                            scope.useFilteredInsteadOfSelection = true
                        }
                    }
                }
                Text("Recupera exactamente los \(summary.selected.count.formatted()) archivos (\(Bytes.gigabytesDetailed(summary.selected.bytes))) que corresponden a tu búsqueda, filtro o selección en la galería.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func batchesDetailCard(_ summary: EverythingSummary) -> some View {
        let currentIdx = min(max(0, scope.batchIndex), max(0, summary.batches.count - 1))
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recuperar por tandas de Gigas")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                HStack(spacing: 5) {
                    Text("Tope:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(batchPresets, id: \.self) { gb in
                        choicePill(title: "\(gb) GB", selected: scope.batchSizeGB == gb) {
                            scope.batchSizeGB = gb
                            scope.batchIndex = 0
                        }
                    }
                    if let free = destination?.free, free >= 2_000_000_000 {
                        let safeGB = max(1, Int((Double(free) * 0.92) / 1_000_000_000.0))
                        if !batchPresets.contains(safeGB) {
                            choicePill(title: "Libre (\(safeGB) GB)", selected: scope.batchSizeGB == safeGB) {
                                scope.batchSizeGB = safeGB
                                scope.batchIndex = 0
                            }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Si no te alcanzan los gigas para recuperar los \(Bytes.gigabytes(summary.allMatchingToggles.bytes)) de una vez, recupera una tanda, muévela a otro disco o nube y vuelve por la siguiente sin volver a escanear.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                let cols = [GridItem(.adaptive(minimum: 155, maximum: 220), spacing: 8)]
                LazyVGrid(columns: cols, spacing: 8) {
                    ForEach(summary.batches) { batch in
                        let selected = batch.index == currentIdx
                        let key = batchIdentifier(sizeGB: scope.batchSizeGB, index: batch.index, total: summary.batches.count)
                        let done = model.completedBatches.contains(key)
                        Button {
                            withAnimation(.snappy(duration: 0.18)) { scope.batchIndex = batch.index }
                            Signals.play(.tap)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Tanda \(batch.index + 1) de \(summary.batches.count)")
                                        .font(.caption.weight(.bold))
                                    Spacer()
                                    if done {
                                        Image(systemName: "checkmark.seal.fill")
                                            .foregroundStyle(.green)
                                            .font(.caption)
                                            .help("Ya recuperaste esta tanda en esta sesión")
                                    }
                                }
                                Text(Bytes.gigabytes(batch.bytes))
                                    .font(.callout.weight(.bold).monospacedDigit())
                                    .foregroundStyle(selected ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(.primary))
                                Text("\(batch.count.formatted()) archivos")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(selected ? AnyShapeStyle(Palette.subtleSurface) : AnyShapeStyle(.background.opacity(0.55)))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(
                                        selected ? AnyShapeStyle(Palette.gradient) : AnyShapeStyle(Palette.accent.opacity(0.15)),
                                        lineWidth: selected ? 2 : 1
                                    )
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
            }
            .padding(14)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func choicePill(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.18)) { action() }
            Signals.play(.tap)
        } label: {
            Text(title)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(selected ? AnyShapeStyle(Palette.gradient) : AnyShapeStyle(Palette.accent.opacity(0.12)))
                )
                .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(Palette.accent))
        }
        .buttonStyle(PressableStyle())
    }

    // MARK: - Ajustes finos para ahorrar GB

    @ViewBuilder
    private func fineTuneSection(_ summary: EverythingSummary) -> some View {
        let hasAnyOption = summary.embedded.count > 0 || summary.overwritten.count > 0
            || summary.systemFiles.count > 0 || summary.healthy.count > 0
        if scope.mode != .current, hasAnyOption {
            VStack(alignment: .leading, spacing: 10) {
                Text("Ajustes para filtrar y ahorrar GB")
                    .font(.subheadline.weight(.semibold))
                VStack(alignment: .leading, spacing: 10) {
                    if summary.systemFiles.count > 0 {
                        Toggle(isOn: $scope.excludeSystemFiles) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Omitir archivos del sistema (\(summary.systemFiles.count.formatted()) · \(Bytes.gigabytesDetailed(summary.systemFiles.bytes)))")
                                    .font(.callout)
                                Text("Descarta índices internos como .DS_Store, Spotlight o fseventsd.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if summary.healthy.count > 0 {
                        Toggle(isOn: $scope.onlyHealthy) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Solo archivos ya verificados con salud alta (\(summary.healthy.count.formatted()) · \(Bytes.gigabytesDetailed(summary.healthy.bytes)))")
                                    .font(.callout)
                                Text("Excluye archivos dañados o que aún no pasaron por comprobación profunda.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if summary.embedded.count > 0 {
                        Toggle(isOn: $scope.includeEmbedded) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Incluir archivos incrustados (\(summary.embedded.count.formatted()) · \(Bytes.gigabytesDetailed(summary.embedded.bytes)))")
                                    .font(.callout)
                                Text("Miniaturas o imágenes que estaban dentro de otro archivo ya encontrado.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if summary.overwritten.count > 0 {
                        Toggle(isOn: $scope.includeOverwritten) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Incluir posibles sobrescritos (\(summary.overwritten.count.formatted()) · \(Bytes.gigabytesDetailed(summary.overwritten.bytes)))")
                                    .font(.callout)
                                Text("Sectores que el sistema de archivos marcó como ocupados por otro archivo.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(14)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    // MARK: - 2. Disco de destino y comparador de GB libres

    private func destinationSection(_ summary: EverythingSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("2. Disco de destino y espacio libre en GB")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    volumes = DestinationInfo.mountedVolumes()
                    if let dest = destination { destination = DestinationInfo.read(dest.url) }
                    Signals.play(.tap)
                } label: {
                    Label("Actualizar discos", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Palette.accent)

                Button(destination == nil ? "Elegir carpeta…" : "Cambiar carpeta…") {
                    if let url = model.chooseDestination(for: summary.selected.count, bytes: summary.selected.bytes) {
                        destination = DestinationInfo.read(url)
                    }
                }
                .controlSize(.small)
            }

            if !volumes.isEmpty {
                VStack(spacing: 7) {
                    ForEach(volumes) { vol in
                        volumeRow(vol, summary: summary)
                    }
                }
            }

            if let dest = destination {
                selectedDestinationCard(dest, summary: summary)
            } else {
                Text("Haz clic en uno de tus discos arriba o en «Elegir carpeta…» para escoger dónde guardar los datos recuperados.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func volumeRow(_ vol: DestinationInfo, summary: EverythingSummary) -> some View {
        let sameSource = model.isSameSourceDisk(vol.url)
        let free = vol.free ?? 0
        let fits = free >= summary.selected.bytes
        return HStack(spacing: 10) {
            Image(systemName: vol.isRemovable || !vol.isInternal ? "externaldrive.fill" : "internaldrive.fill")
                .foregroundStyle(sameSource ? .secondary : Palette.accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(vol.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    if let fmt = vol.format {
                        Text(fmt)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if sameSource {
                    Text("Disco que estás escaneando · protegido contra escritura")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                } else if let cap = vol.capacity, cap > 0 {
                    Text("Libres: \(Bytes.gigabytes(free)) de \(Bytes.gigabytes(cap))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text("Libres: \(Bytes.gigabytes(free))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !sameSource {
                if summary.selected.bytes == 0 {
                    Text(Bytes.gigabytes(free))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else if fits {
                    Label("Alcanza", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                } else {
                    let missing = summary.selected.bytes - free
                    HStack(spacing: 6) {
                        Text("Faltan \(Bytes.gigabytes(missing))")
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.orange)
                        if free >= 2_000_000_000, scope.mode != .batches {
                            let safeGB = max(1, Int((Double(free) * 0.92) / 1_000_000_000.0))
                            Button("Usar tandas de \(safeGB) GB") {
                                withAnimation(.snappy) {
                                    scope.mode = .batches
                                    scope.batchSizeGB = safeGB
                                    scope.batchIndex = 0
                                }
                                Signals.play(.tap)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                    }
                }
                Button("Elegir aquí…") {
                    if let url = model.chooseDestination(for: summary.selected.count, bytes: summary.selected.bytes, startingAt: vol.url) {
                        destination = DestinationInfo.read(url)
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .opacity(sameSource ? 0.65 : 1)
    }

    private func selectedDestinationCard(_ dest: DestinationInfo, summary: EverythingSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill.badge.gearshape").foregroundStyle(Palette.accent)
                Text("Carpeta elegida: \(dest.url.path)")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(dest.url.path)
                Spacer()
                if let fmt = dest.format {
                    Text(fmt).font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.isSameSourceDisk(dest.url) {
                statusLabel("Está en el mismo disco que estás escaneando. Elige otro disco para no pisar tus datos.",
                            symbol: "xmark.octagon.fill", tint: .red)
            } else if let free = dest.free {
                if free >= summary.selected.bytes {
                    statusLabel("Espacio libre: \(Bytes.gigabytesDetailed(free)) · alcanza bien (quedarán ~\(Bytes.gigabytes(free - summary.selected.bytes))).",
                                symbol: "checkmark.circle.fill", tint: .green)
                } else {
                    statusLabel("Espacio libre: \(Bytes.gigabytesDetailed(free)) · faltan \(Bytes.gigabytes(summary.selected.bytes - free)) para los \(Bytes.gigabytes(summary.selected.bytes)). Puedes usar «Por tandas de GB» arriba.",
                                symbol: "exclamationmark.triangle.fill", tint: .orange)
                }
            }
            if dest.isFAT32, summary.largest >= 4_294_967_296 {
                statusLabel("Este destino es FAT32 (máximo 4 GB por archivo) y hay archivos de hasta \(Bytes.gigabytesDetailed(summary.largest)). Usa un disco exFAT o APFS.",
                            symbol: "exclamationmark.triangle.fill", tint: .orange)
            }
        }
        .padding(14)
        .background(Palette.subtleSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.borderStroke))
    }

    private func statusLabel(_ text: String, symbol: String, tint: Color) -> some View {
        Label {
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
    }

    // MARK: - Pie de acción

    private func footer(_ summary: EverythingSummary) -> some View {
        let sameDisk = destination.map { model.isSameSourceDisk($0.url) } ?? false
        let lowSpace: Bool = {
            guard let free = destination?.free else { return false }
            return free < summary.selected.bytes
        }()
        return HStack(spacing: 12) {
            if model.phase.isScanning {
                Label("El escaneo sigue en curso: recuperará los \(summary.selected.count.formatted()) encontrados hasta ahora.",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cerrar") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button {
                startRecover(summary: summary)
            } label: {
                Label(primaryButtonTitle(summary: summary, lowSpace: lowSpace),
                      systemImage: "arrow.down.doc.fill")
            }
            .buttonStyle(CompactGlowButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(summary.selected.count == 0 || sameDisk || model.isRecovering)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func primaryButtonTitle(summary: EverythingSummary, lowSpace: Bool) -> String {
        let gb = Bytes.gigabytes(summary.selected.bytes)
        if scope.mode == .batches, summary.batches.count > 1 {
            let idx = min(max(0, scope.batchIndex), summary.batches.count - 1) + 1
            return destination == nil
                ? "Elegir destino · Tanda \(idx)/\(summary.batches.count) (\(gb))"
                : "Recuperar Tanda \(idx)/\(summary.batches.count) (\(gb))"
        }
        if destination == nil {
            return "Elegir destino y recuperar (\(gb))"
        }
        if lowSpace {
            return "Recuperar hasta llenar (\(gb))"
        }
        return "Recuperar datos (\(gb))"
    }

    private func batchIdentifier(sizeGB: Int, index: Int, total: Int) -> String {
        "\(sizeGB)gb-\(index)-\(total)-\(scope.includeEmbedded)-\(scope.includeOverwritten)-\(scope.excludeSystemFiles)-\(scope.onlyHealthy)"
    }

    private func folderSuffix(summary: EverythingSummary) -> String? {
        switch scope.mode {
        case .all:
            return nil
        case .categories:
            if scope.categories.count == 1, let only = scope.categories.first {
                return only.rawValue
            }
            return nil
        case .named:
            return "Con nombre original"
        case .current:
            return nil
        case .batches:
            guard summary.batches.count > 1 else { return nil }
            let idx = min(max(0, scope.batchIndex), summary.batches.count - 1) + 1
            return "Tanda \(idx) de \(summary.batches.count)"
        }
    }

    private func startRecover(summary: EverythingSummary) {
        let suffix = folderSuffix(summary: summary)
        let bKey: String? = scope.mode == .batches
            ? batchIdentifier(sizeGB: scope.batchSizeGB, index: scope.batchIndex, total: summary.batches.count)
            : nil

        if let dest = destination {
            guard !model.isSameSourceDisk(dest.url) else { return }
            let list = model.itemsForEverything(scope)
            dismiss()
            model.recover(list, to: dest.url, folderSuffix: suffix, batchKey: bKey)
        } else {
            guard let url = model.chooseDestination(for: summary.selected.count, bytes: summary.selected.bytes) else { return }
            let info = DestinationInfo.read(url)
            if model.isSameSourceDisk(url) || (info.free != nil && info.free! < summary.selected.bytes) {
                destination = info
                return
            }
            let list = model.itemsForEverything(scope)
            dismiss()
            model.recover(list, to: url, folderSuffix: suffix, batchKey: bKey)
        }
    }
}

enum CategoryStyle {
    static func symbol(_ c: FileCategory) -> String {
        switch c {
        case .photo: return "photo.fill"
        case .video: return "film.fill"
        case .audio: return "music.note"
        case .document: return "doc.text.fill"
        case .archive: return "archivebox.fill"
        case .other: return "questionmark.folder.fill"
        }
    }

    static func tint(_ c: FileCategory) -> Color {
        switch c {
        case .photo: return .pink
        case .video: return .purple
        case .audio: return .orange
        case .document: return .blue
        case .archive: return .brown
        case .other: return .gray
        }
    }
}
