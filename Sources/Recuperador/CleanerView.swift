import SwiftUI

struct CleanerView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.widthClass) private var width
    @StateObject private var cleaner = CleanerModel()
    @State private var appeared = false
    @State private var confirmPurge = false

    private func fmt(_ b: Double) -> String { ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .memory) }
    private func fmt(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: width == .compact ? 22 : 30) {
                HStack(alignment: .center, spacing: width == .compact ? 14 : 22) {
                    AppBadge(size: width.heroIcon)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Limpiador")
                            .font(.system(size: width.heroSize, weight: .bold, design: Palette.titleDesign))
                        Text("Libera memoria y espacio en disco con un clic. Solo se borran cachés que las apps vuelven a generar solas.")
                            .font(width == .compact ? .body : .title3)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 22) {
                        memoryCard
                        diskSummaryCard
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        memoryCard
                        diskSummaryCard
                    }
                }
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 20)

                diskList
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 30)
            }
            .padding(.horizontal, width == .regular ? 48 : width.pagePadding)
            .padding(.vertical, width == .compact ? 20 : 40)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(ThemedBackground())
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.85).delay(0.05)) { appeared = true }
            if cleaner.state == .idle { cleaner.measure(excludingRecuperador: model.phase.isScanning) }
        }
    }

    // MARK: RAM

    private var memoryCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Memoria RAM", systemImage: "memorychip.fill").font(.title3.weight(.semibold))
            ViewThatFits(in: .horizontal) {
                memoryStats(wide: true)
                memoryStats(wide: false)
            }
            Button {
                confirmPurge = true
            } label: {
                HStack(spacing: 8) {
                    if cleaner.purging { ProgressView().controlSize(.small).tint(.white) } else {
                        Image(systemName: "wind").symbolEffect(.bounce, value: cleaner.purgeMessage)
                    }
                    Text(cleaner.purging ? "Liberando…" : "Borrar caché de RAM")
                }
            }
            .buttonStyle(GlowButtonStyle())
            .disabled(cleaner.purging)
            if let message = cleaner.purgeMessage {
                Label(message, systemImage: message.hasPrefix("Listo") ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(message.hasPrefix("Listo") ? .green : .secondary)
                    .transition(.scale.combined(with: .opacity))
            }
            Text("Equivale a `sudo purge`. La primera vez macOS pide tu contraseña y queda permitido solo ese comando.")
                .font(.caption).foregroundStyle(.tertiary)
                .confirmationDialog("¿Liberar la caché de RAM?", isPresented: $confirmPurge, titleVisibility: .visible) {
                    Button("Liberar") { cleaner.purgeMemory() }
                    Button("Cancelar", role: .cancel) {}
                } message: {
                    Text("No se borra ningún archivo. La primera vez, Recuperador guarda en el sistema un permiso limitado al comando purge, para no volver a pedir la contraseña.")
                }
        }
        .padding(width == .compact ? 16 : 22)
        .frame(maxWidth: .infinity, minHeight: width == .regular ? 390 : nil, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Palette.accent.opacity(0.15)))
        .hoverLift(1.01)
        .animation(.spring, value: cleaner.purgeMessage)
    }

    private func memoryStats(wide: Bool) -> some View {
        let gauge = memoryGauge.frame(width: width == .compact ? 120 : 140, height: width == .compact ? 120 : 140)
        let lines = VStack(alignment: .leading, spacing: 10) {
            legend(Palette.accent, "Apps", fmt(cleaner.memory.appMemory + cleaner.memory.compressed))
            legend(Palette.secondary, "Caché de archivos", fmt(cleaner.memory.fileCache))
            legend(.secondary.opacity(0.4), "Libre", fmt(cleaner.memory.free))
            Text("Total \(fmt(cleaner.memory.total))").font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        return Group {
            if wide {
                HStack(spacing: 26) { gauge; lines }
            } else {
                VStack(alignment: .leading, spacing: 16) { gauge; lines }
            }
        }
    }

    private var memoryGauge: some View {
        ZStack {
            RingGauge(value: cleaner.memory.usedFraction + cleaner.memory.cacheFraction, lineWidth: 16,
                      colors: [Palette.secondary.opacity(0.7), Palette.secondary])
            RingGauge(value: cleaner.memory.usedFraction, lineWidth: 16)
            VStack(spacing: 2) {
                Text("\(Int(((cleaner.memory.usedFraction + cleaner.memory.cacheFraction) * 100).rounded()))%")
                    .font(.system(size: width == .compact ? 24 : 30, weight: .bold, design: Palette.titleDesign))
                    .contentTransition(.numericText())
                    .animation(.snappy, value: cleaner.memory)
                Text("ocupada").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func legend(_ color: Color, _ title: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(title).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 12)
            Text(value).monospacedDigit().contentTransition(.numericText()).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Disco

    private var diskSummaryCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Caché en disco", systemImage: "internaldrive.fill").font(.title3.weight(.semibold))
            ZStack {
                RingGauge(value: cleaner.state == .cleaning || cleaner.state == .done ? cleaner.progress : 0, lineWidth: 16)
                VStack(spacing: 4) {
                    if cleaner.state == .done {
                        Image(systemName: "checkmark")
                            .font(.system(size: 34, weight: .bold))
                            .foregroundStyle(.green)
                            .symbolEffect(.bounce, value: cleaner.state)
                        Text(fmt(cleaner.freed)).font(.headline).contentTransition(.numericText())
                        Text("liberados").font(.caption).foregroundStyle(.secondary)
                    } else if cleaner.state == .cleaning {
                        Text(fmt(cleaner.freed))
                            .font(.system(size: 22, weight: .bold, design: Palette.titleDesign))
                            .contentTransition(.numericText())
                        Text("liberados").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(fmt(cleaner.selectedSize))
                            .font(.system(size: 22, weight: .bold, design: Palette.titleDesign))
                            .contentTransition(.numericText())
                            .animation(.snappy, value: cleaner.selectedSize)
                        Text(cleaner.state == .measuring ? "midiendo…" : "para liberar").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: width == .compact ? 120 : 140, height: width == .compact ? 120 : 140)
            .frame(maxWidth: .infinity)

            if cleaner.state == .cleaning || cleaner.state == .done {
                ShimmerBar(value: cleaner.progress, active: cleaner.state == .cleaning)
                Text(cleaner.state == .done ? "¡Listo! Tu Mac tiene \(fmt(cleaner.freed)) más de espacio libre." : cleaner.current)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }

            HStack {
                Button {
                    if cleaner.state == .done { cleaner.measure(excludingRecuperador: model.phase.isScanning) } else { cleaner.clean() }
                } label: {
                    Label(cleaner.state == .done ? "Volver a medir" : "Limpiar \(fmt(cleaner.selectedSize))",
                          systemImage: cleaner.state == .done ? "arrow.clockwise" : "sparkles")
                }
                .buttonStyle(GlowButtonStyle())
                .disabled(cleaner.state == .measuring || cleaner.state == .cleaning || (cleaner.state != .done && cleaner.selectedSize == 0))
            }
            .frame(maxWidth: .infinity)
        }
        .padding(width == .compact ? 16 : 22)
        .frame(maxWidth: .infinity, minHeight: width == .regular ? 390 : nil, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Palette.accent.opacity(0.15)))
        .hoverLift(1.01)
        .animation(.spring, value: cleaner.state)
    }

    private var diskList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Qué se va a limpiar").font(.title2.weight(.semibold))
            ForEach(Array(cleaner.targets.enumerated()), id: \.element.id) { index, target in
                CleanRow(target: target, selected: cleaner.selected.contains(target.id),
                         largest: cleaner.targets.map(\.size).max() ?? 1, measuring: !target.measured) {
                    guard cleaner.state != .cleaning else { return }
                    if cleaner.selected.contains(target.id) { cleaner.selected.remove(target.id) } else { cleaner.selected.insert(target.id) }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(Double(index) * 0.06), value: cleaner.targets.count)
            }
            Label("No se toca la Papelera ni tus documentos: ahí puede haber archivos que quieras recuperar.",
                  systemImage: "lock.shield.fill")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct CleanRow: View {
    @Environment(\.widthClass) private var width
    let target: CleanTarget
    let selected: Bool
    let largest: Int64
    let measuring: Bool
    let toggle: () -> Void
    @State private var hover = false

    private var barWidth: CGFloat { width == .compact ? 96 : 160 }

    var body: some View {
        HStack(spacing: width == .compact ? 10 : 16) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(selected ? Palette.accent : .secondary)
                .contentTransition(.symbolEffect(.replace))
            Image(systemName: target.symbol)
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: width == .compact ? 36 : 42, height: width == .compact ? 36 : 42)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Palette.gradient))
                .rotationEffect(.degrees(hover ? -8 : 0))
            VStack(alignment: .leading, spacing: 3) {
                Text(target.title).font(.headline).lineLimit(1)
                Text(target.detail).font(width == .compact ? .caption : .callout).foregroundStyle(.secondary)
                    .lineLimit(width == .compact ? 2 : 1)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                if measuring { ProgressView().controlSize(.small) }
                VStack(alignment: .trailing, spacing: 6) {
                    Text(ByteCountFormatter.string(fromByteCount: target.size, countStyle: .file))
                        .font(.headline.monospacedDigit())
                        .contentTransition(.numericText())
                        .lineLimit(1)
                    if width != .compact {
                        Capsule()
                            .fill(Palette.gradient)
                            .frame(width: max(6, barWidth * CGFloat(target.size) / CGFloat(max(1, largest))), height: 6)
                            .frame(width: barWidth, alignment: .trailing)
                            .animation(.spring, value: target.size)
                    }
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(selected ? Palette.accent.opacity(0.6) : Color.primary.opacity(0.06), lineWidth: selected ? 1.5 : 1))
        .scaleEffect(hover ? 1.01 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hover)
        .animation(.snappy, value: selected)
        .onHover { hover = $0 }
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
    }
}
