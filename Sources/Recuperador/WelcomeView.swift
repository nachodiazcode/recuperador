import SwiftUI
import UniformTypeIdentifiers

struct WelcomeView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.widthClass) private var width
    @State private var selected: DiskInfo.ID?
    @State private var deep = true
    @State private var appeared = false
    @State private var spinRefresh = 0

    private var selectedDisk: DiskInfo? { model.disks.first { $0.id == selected } }
    private var columns: [GridItem] {
        let minimum: CGFloat = width == .compact ? 260 : 230
        return [GridItem(.adaptive(minimum: minimum, maximum: 320), spacing: 16)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: width == .compact ? 22 : 34) {
                header
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 12)

                if let saved = model.savedScan {
                    savedScanBanner(saved)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        StepTitle(number: 1, title: "Elige el disco")
                        Spacer()
                        Button {
                            withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) {
                                spinRefresh += 1
                            }
                            Signals.play(.tap)
                            model.refreshDisks()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.clockwise")
                                    .rotationEffect(.degrees(Double(spinRefresh) * 360))
                                if width != .compact {
                                    Text("Actualizar")
                                }
                            }
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Palette.accent)
                        .help("Actualizar lista de discos")
                    }
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                        ForEach(model.disks) { disk in
                            DiskCard(disk: disk, selected: selected == disk.id)
                                .hoverLift()
                                .onTapGesture {
                                    guard selected != disk.id else { return }
                                    selected = disk.id
                                    Signals.play(.tap)
                                }
                        }
                        ImageCard(
                            onTap: { model.openImage(deep: deep) },
                            onDropURL: { url in model.openImage(at: url, deep: deep) }
                        )
                        .hoverLift()
                    }
                    if let disk = selectedDisk, disk.isUnrecoverableSSD {
                        Callout(symbol: "lock.trianglebadge.exclamationmark.fill", tint: .orange,
                                title: "macOS protege el SSD interno de tu Mac",
                                text: "Ni siquiera con tu contraseña de administrador se puede leer en crudo: lo impide la Protección de Integridad del Sistema. Además, en este disco lo que borras se elimina físicamente (TRIM) y todo está cifrado. Conecta un disco externo, un pendrive o una tarjeta SD: aparecerá aquí automáticamente.")
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    } else if let disk = selectedDisk, disk.isSolidState && !disk.isInternal {
                        Callout(symbol: "externaldrive.badge.exclamationmark", tint: .orange,
                                title: "Este SSD externo puede haber borrado los datos de verdad",
                                text: "Si el disco usa TRIM, el espacio se vacía en el momento de borrar y no queda nada que recuperar. En pendrives y tarjetas SD casi nunca pasa. El escaneo es solo lectura: no escribe en el disco y no lo empeora.")
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    } else if let disk = selectedDisk, disk.unmounted {
                        Callout(symbol: "bandage.fill", tint: Palette.accent,
                                title: "macOS no logra montar este disco, pero Recuperador sí puede leerlo",
                                text: "Suele pasar cuando un disco se desconecta sin expulsarlo: el índice de carpetas queda dañado y macOS prefiere no abrirlo. Tus archivos normalmente siguen intactos. Recuperador los lee directamente desde los sectores, sin necesitar ese índice ni escribir nada en el disco.")
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 18)
                .animation(.snappy(duration: 0.25), value: selected)

                VStack(alignment: .leading, spacing: 14) {
                    StepTitle(number: 2, title: "Tipo de escaneo")
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 18) { quickMode; deepMode }
                        VStack(spacing: 12) { quickMode; deepMode }
                    }
                }
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 24)

                VStack(alignment: .leading, spacing: 14) {
                    StepTitle(number: 3, title: "¿Qué buscas?")
                    WhatToFindView(filter: $model.scanFilter)
                }
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 28)

                ViewThatFits(in: .horizontal) {
                    actionRow(wide: true)
                    actionRow(wide: false)
                }
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 32)
            }
            .padding(.horizontal, width.pagePadding)
            .padding(.vertical, width == .compact ? 20 : 36)
            .frame(maxWidth: 1120, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(ThemedBackground())
        .onAppear {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.84)) { appeared = true }
            autoSelectExternalDisk()
        }
        .onChange(of: model.disks) { _, _ in
            autoSelectExternalDisk()
        }
    }

    private func autoSelectExternalDisk() {
        if let current = selected, model.disks.contains(where: { $0.id == current }) { return }
        if let external = model.disks.first(where: { !$0.isUnrecoverableSSD }) {
            selected = external.id
        }
    }

    private var quickMode: some View {
        ModeCard(symbol: "bolt.fill", tint: Palette.secondary, title: "Rápido",
                 subtitle: "Archivos borrados con su nombre y carpeta originales.",
                 detail: "Segundos · FAT, exFAT y NTFS", selected: !deep)
            .hoverLift(1.015)
            .onTapGesture {
                guard deep else { return }
                deep = false
                Signals.play(.tap)
            }
    }

    private var deepMode: some View {
        ModeCard(symbol: "sparkle.magnifyingglass", tint: Palette.accent, title: "Completo",
                 subtitle: "Además revisa todo el espacio libre del disco, incluso después de formatear.",
                 detail: "Según el tamaño del disco · cualquier sistema", selected: deep)
            .hoverLift(1.015)
            .onTapGesture {
                guard !deep else { return }
                deep = true
                Signals.play(.tap)
            }
    }

    /// Por qué "Comenzar escaneo" está apagado, para no dejar un botón gris sin explicación.
    private var blockedReason: String? {
        if model.scanFilter.chips.isEmpty { return "Elige al menos un tipo de archivo." }
        if let disk = selectedDisk, disk.isUnrecoverableSSD {
            return "El SSD interno no se puede escanear. Conecta un disco externo, pendrive o tarjeta SD."
        }
        guard selectedDisk == nil else { return nil }
        if model.disks.allSatisfy(\.isUnrecoverableSSD) {
            return "No hay discos externos conectados. Conecta uno o arrastra una imagen de disco arriba."
        }
        return "Elige un disco arriba, en el paso 1."
    }

    private func actionRow(wide: Bool) -> some View {
        let note = VStack(alignment: .leading, spacing: 3) {
            Label("Solo lectura: el disco escaneado nunca se modifica.", systemImage: "lock.shield.fill")
                .foregroundStyle(Palette.accent)
                .font(.callout.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            Text(deep ? "Completo · \(model.scanFilter.summary)" : "Rápido · \(model.scanFilter.summary)")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            if let blocked = blockedReason {
                Label(blocked, systemImage: "arrow.up.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(.secondary)
        let button = Button {
            if let disk = selectedDisk { model.scan(disk, deep: deep) }
        } label: {
            Label("Comenzar escaneo", systemImage: "play.fill")
                .frame(maxWidth: wide ? nil : .infinity)
        }
        .buttonStyle(GlowButtonStyle())
        .disabled(selectedDisk == nil || selectedDisk?.isUnrecoverableSSD == true
                  || model.phase == .opening || model.scanFilter.chips.isEmpty)
        return Group {
            if wide {
                HStack(spacing: 16) {
                    note.frame(maxWidth: .infinity, alignment: .leading)
                    if model.phase == .opening {
                        ProgressView().controlSize(.small)
                        Text("Esperando autorización…").foregroundStyle(.secondary)
                    }
                    button
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    note
                    if model.phase == .opening {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Esperando autorización…").foregroundStyle(.secondary)
                        }
                    }
                    button
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: width == .compact ? 14 : 22) {
            AppBadge(size: width.heroIcon)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("Recuperador")
                        .font(.system(size: width.heroSize, weight: .bold, design: Palette.titleDesign))
                    VersionPill(text: "3.2.1")
                }
                Text("Encuentra fotos, videos, música y documentos borrados, con su nombre en FAT, exFAT y NTFS, o por firma después de formatear. Todo ocurre en tu Mac, sin internet.")
                    .font(width == .compact ? .body : .title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func savedScanBanner(_ saved: SavedScanHeader) -> some View {
        HStack(spacing: 14) {
            Image(systemName: saved.sourceSymbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Palette.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: Palette.accent.opacity(0.35), radius: 8, y: 3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Escaneo guardado: \(saved.sourceName)")
                    .font(.headline)
                Text("\(saved.fileCount.formatted()) archivos · \(Bytes.gigabytesDetailed(saved.totalBytes)) · \(saved.finished ? "completo" : "parcial")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 8)
            Button {
                model.resumeSavedScan()
            } label: {
                Label("Abrir sin reescanear", systemImage: "arrow.uturn.forward")
            }
            .buttonStyle(CompactGlowButtonStyle())
            .disabled(model.phase == .opening)
            Button {
                withAnimation(.snappy) { model.discardSavedScan() }
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Descartar este escaneo guardado")
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .background(Palette.subtleSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Palette.borderStroke, lineWidth: 1.5) }
        .hoverLift(1.01)
    }
}

struct StepTitle: View {
    let number: Int
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            Text("\(number)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Palette.gradient))
                .shadow(color: Palette.accent.opacity(0.35), radius: 6, y: 2)
            Text(title).font(.title2.weight(.semibold))
        }
    }
}

struct DiskCard: View {
    let disk: DiskInfo
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Image(systemName: disk.symbol)
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(disk.isUnrecoverableSSD ? AnyShapeStyle(.secondary) : AnyShapeStyle(Palette.gradient))
                    .symbolEffect(.bounce, value: selected)
                Spacer()
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Palette.gradient)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(disk.name).font(.headline).lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: disk.size, countStyle: .file))
                    .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                if disk.unmounted {
                    Tag(text: "No montado", tint: .orange)
                } else {
                    Tag(text: disk.isUnrecoverableSSD ? "Protegido por macOS" : disk.kind,
                        tint: disk.isUnrecoverableSSD ? .orange : Palette.accent)
                }
                Tag(text: disk.id, tint: .gray)
            }
            if !disk.formats.isEmpty {
                Text(disk.formats.joined(separator: " · "))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 168, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.subtleSurface)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    selected ? AnyShapeStyle(Palette.gradient) : AnyShapeStyle(Palette.accent.opacity(0.14)),
                    lineWidth: selected ? 2.5 : 1
                )
        )
        .shadow(color: Palette.accent.opacity(selected ? 0.24 : 0.04), radius: selected ? 14 : 4, y: 4)
        .contentShape(Rectangle())
        .animation(.spring(response: 0.28, dampingFraction: 0.78), value: selected)
    }
}

struct ImageCard: View {
    let onTap: () -> Void
    let onDropURL: (URL) -> Void
    @State private var dropTargeted = false

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 10) {
                Image(systemName: dropTargeted ? "arrow.down.doc.fill" : "doc.badge.plus")
                    .font(.system(size: 30))
                    .foregroundStyle(Palette.gradient)
                    .symbolEffect(.bounce, value: dropTargeted)
                Text(dropTargeted ? "Suelta la imagen aquí" : "Abrir o arrastrar imagen…")
                    .font(.headline)
                Text(".img · .dd · .dmg · .iso")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 168)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(dropTargeted ? AnyShapeStyle(Palette.subtleSurface) : AnyShapeStyle(Palette.accent.opacity(0.03)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        dropTargeted ? Palette.accent : Palette.accent.opacity(0.38),
                        style: StrokeStyle(lineWidth: dropTargeted ? 2.5 : 1.5, dash: dropTargeted ? [] : [6, 5])
                    )
            )
            .contentShape(Rectangle())
            .animation(.snappy(duration: 0.18), value: dropTargeted)
        }
        .buttonStyle(PressableStyle())
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let first = providers.first else { return false }
            _ = first.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in onDropURL(url) }
            }
            return true
        }
    }
}

struct ModeCard: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
    let detail: String
    let selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(selected ? AnyShapeStyle(Palette.gradient) : AnyShapeStyle(tint.gradient))
                )
                .shadow(color: tint.opacity(selected ? 0.42 : 0.18), radius: 8, y: 3)
                .symbolEffect(.bounce, value: selected)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.title3.weight(.semibold))
                Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(detail).font(.caption.weight(.semibold)).foregroundStyle(Palette.accent)
            }
            Spacer()
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(selected ? AnyShapeStyle(Palette.gradient) : AnyShapeStyle(.secondary))
                .contentTransition(.symbolEffect(.replace))
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.subtleSurface)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    selected ? AnyShapeStyle(Palette.gradient) : AnyShapeStyle(Palette.accent.opacity(0.14)),
                    lineWidth: selected ? 2.5 : 1
                )
        )
        .shadow(color: Palette.accent.opacity(selected ? 0.2 : 0), radius: 12, y: 4)
        .contentShape(Rectangle())
        .animation(.spring(response: 0.28, dampingFraction: 0.78), value: selected)
    }
}

struct Tag: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint == .gray ? .secondary : tint)
    }
}

struct Callout: View {
    let symbol: String
    let tint: Color
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title2).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(tint.opacity(0.22)))
    }
}
