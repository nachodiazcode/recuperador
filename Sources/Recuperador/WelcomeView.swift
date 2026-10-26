import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.widthClass) private var width
    @State private var selected: DiskInfo.ID?
    @State private var deep = true

    private var selectedDisk: DiskInfo? { model.disks.first { $0.id == selected } }
    private var columns: [GridItem] {
        let minimum: CGFloat = width == .compact ? 260 : 230
        return [GridItem(.adaptive(minimum: minimum, maximum: 320), spacing: 16)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: width == .compact ? 22 : 34) {
                header

                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        StepTitle(number: 1, title: "Elige el disco")
                        Spacer()
                        Button { model.refreshDisks() } label: {
                            if width == .compact {
                                Image(systemName: "arrow.clockwise")
                            } else {
                                Label("Actualizar", systemImage: "arrow.clockwise")
                            }
                        }
                            .buttonStyle(.borderless)
                            .help("Actualizar")
                    }
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                        ForEach(model.disks) { disk in
                            DiskCard(disk: disk, selected: selected == disk.id)
                                .hoverLift()
                                .onTapGesture { selected = disk.id }
                        }
                        ImageCard { model.openImage(deep: deep) }.hoverLift()
                    }
                    if let disk = selectedDisk, disk.isUnrecoverableSSD {
                        Callout(symbol: "lock.trianglebadge.exclamationmark.fill", tint: .orange,
                                title: "macOS protege el SSD interno de tu Mac",
                                text: "Ni siquiera con tu contraseña de administrador se puede leer en crudo: lo impide la Protección de Integridad del Sistema. Además, en este disco lo que borras se elimina físicamente (TRIM) y todo está cifrado. Conecta un disco externo, un pendrive o una tarjeta SD: aparecerá aquí automáticamente.")
                    } else if let disk = selectedDisk, disk.isSolidState && !disk.isInternal {
                        Callout(symbol: "externaldrive.badge.exclamationmark", tint: .orange,
                                title: "Este SSD externo puede haber borrado los datos de verdad",
                                text: "Si el disco usa TRIM, el espacio se vacía en el momento de borrar y no queda nada que recuperar. En pendrives y tarjetas SD casi nunca pasa. El escaneo es solo lectura: no escribe en el disco y no lo empeora.")
                    } else if let disk = selectedDisk, disk.unmounted {
                        Callout(symbol: "bandage.fill", tint: .blue,
                                title: "macOS no logra montar este disco, pero Recuperador sí puede leerlo",
                                text: "Suele pasar cuando un disco se desconecta sin expulsarlo: el índice de carpetas queda dañado y macOS prefiere no abrirlo. Tus archivos normalmente siguen intactos. Recuperador los lee directamente desde los sectores, sin necesitar ese índice ni escribir nada en el disco.")
                    }
                }

                VStack(alignment: .leading, spacing: 14) {
                    StepTitle(number: 2, title: "Tipo de escaneo")
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 18) { quickMode; deepMode }
                        VStack(spacing: 12) { quickMode; deepMode }
                    }
                }

                VStack(alignment: .leading, spacing: 14) {
                    StepTitle(number: 3, title: "¿Qué buscas?")
                    WhatToFindView(filter: $model.scanFilter)
                }

                ViewThatFits(in: .horizontal) {
                    actionRow(wide: true)
                    actionRow(wide: false)
                }
            }
            .padding(.horizontal, width.pagePadding)
            .padding(.vertical, width == .compact ? 20 : 36)
            .frame(maxWidth: 1120, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(ThemedBackground())
    }

    private var quickMode: some View {
        ModeCard(symbol: "bolt.fill", tint: .yellow, title: "Rápido",
                 subtitle: "Archivos borrados con su nombre y carpeta originales.",
                 detail: "Segundos · FAT, exFAT y NTFS", selected: !deep)
            .hoverLift(1.015)
            .onTapGesture { deep = false }
    }

    private var deepMode: some View {
        ModeCard(symbol: "sparkle.magnifyingglass", tint: .purple, title: "Completo",
                 subtitle: "Además revisa todo el espacio libre del disco, incluso después de formatear.",
                 detail: "Según el tamaño del disco · cualquier sistema", selected: deep)
            .hoverLift(1.015)
            .onTapGesture { deep = true }
    }

    /// Por qué "Comenzar escaneo" está apagado, para no dejar un botón gris sin explicación.
    private var blockedReason: String? {
        if model.scanFilter.chips.isEmpty { return "Elige al menos un tipo de archivo." }
        if let disk = selectedDisk, disk.isUnrecoverableSSD {
            return "El SSD interno no se puede escanear. Conecta un disco externo, pendrive o tarjeta SD."
        }
        guard selectedDisk == nil else { return nil }
        if model.disks.allSatisfy(\.isUnrecoverableSSD) {
            return "No hay discos externos conectados. Conecta uno o abre una imagen de disco (arriba)."
        }
        return "Elige un disco arriba, en el paso 1."
    }

    private func actionRow(wide: Bool) -> some View {
        let note = VStack(alignment: .leading, spacing: 3) {
            Label("Solo lectura: el disco escaneado nunca se modifica.", systemImage: "lock.shield.fill")
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
                Text("Recuperador")
                    .font(.system(size: width.heroSize, weight: .bold, design: Palette.titleDesign))
                Text("Encuentra fotos, videos, música y documentos borrados, con su nombre en FAT, exFAT y NTFS, o por firma después de formatear. Todo ocurre en tu Mac, sin internet.")
                    .font(width == .compact ? .body : .title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
                .frame(width: 26, height: 26)
                .background(Circle().fill(Palette.accent))
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
                    .font(.system(size: 34))
                    .foregroundStyle(disk.isUnrecoverableSSD ? AnyShapeStyle(.secondary) : AnyShapeStyle(Palette.accent))
                Spacer()
                if selected {
                    Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(Palette.accent)
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
                    Tag(text: disk.isUnrecoverableSSD ? "Protegido por macOS" : disk.kind, tint: disk.isUnrecoverableSSD ? .orange : .blue)
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
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(selected ? Palette.accent : Color.primary.opacity(0.08), lineWidth: selected ? 2.5 : 1))
        .shadow(color: .black.opacity(selected ? 0.12 : 0.04), radius: selected ? 10 : 4, y: 3)
        .contentShape(Rectangle())
        .animation(.snappy, value: selected)
    }
}

struct ImageCard: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: "doc.badge.plus").font(.system(size: 30))
                Text("Abrir imagen de disco…").font(.headline)
                Text(".img · .dd · .dmg · .iso").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 168)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .foregroundStyle(.secondary.opacity(0.6)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.gradient))
                .symbolEffect(.bounce, value: selected)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.title3.weight(.semibold))
                Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(detail).font(.caption.weight(.medium)).foregroundStyle(tint == .yellow ? .orange : tint)
            }
            Spacer()
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .font(.title2)
                .foregroundStyle(selected ? Palette.accent : .secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(selected ? Palette.accent : Color.primary.opacity(0.08), lineWidth: selected ? 2.5 : 1))
        .contentShape(Rectangle())
        .animation(.snappy, value: selected)
    }
}

struct Tag: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.14), in: Capsule())
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
    }
}
