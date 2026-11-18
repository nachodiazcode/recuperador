import RecoveryCore
import SwiftUI

/// Paso 3 de la pantalla inicial: tipos de archivo, rango de años y tamaño mínimo.
struct WhatToFindView: View {
    @Environment(\.widthClass) private var width
    @Binding var filter: ScanFilter

    private let currentYear = Calendar.current.component(.year, from: Date())
    private var yearOptions: [Int] { Array((1995...currentYear).reversed()) }
    private let sizes: [(String, Int64)] = [("Cualquiera", 0), ("> 100 KB", 100 << 10), ("> 1 MB", 1 << 20), ("> 10 MB", 10 << 20), ("> 100 MB", 100 << 20)]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Text("Tipos de archivo").font(.headline)
                    Spacer()
                    Button("Todos") {
                        withAnimation(.snappy(duration: 0.2)) {
                            filter.chips = Set(TypeCatalog.allChips.map(\.label))
                        }
                        Signals.play(.tap)
                    }
                    Button("Ninguno") {
                        withAnimation(.snappy(duration: 0.2)) {
                            filter.chips = []
                        }
                        Signals.play(.tap)
                    }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Palette.accent)

                ForEach(TypeCatalog.groups, id: \.category) { group in
                    CategoryRow(category: group.category, chips: group.chips, selected: $filter.chips)
                }
                HStack(spacing: 6) {
                    Circle().fill(.orange).frame(width: 6, height: 6)
                    Text("Solo se encuentran por su nombre (escaneo rápido): no tienen una firma que el escaneo profundo pueda reconocer.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Buscar también lo que está dentro de otro archivo", isOn: $filter.includeEmbedded)
                Text("Una foto metida en un Word o un PDF. Apagado, el escaneo salta el interior de cada archivo y la lista queda más limpia.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Divider()

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 40) {
                    dateBlock.frame(maxWidth: .infinity, alignment: .leading)
                    sizeBlock.frame(maxWidth: 460, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 22) {
                    dateBlock
                    sizeBlock
                }
            }
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Palette.accent.opacity(0.16)))
    }

    private var dateBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Fecha").font(.headline)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    yearPicker("Desde", selection: $filter.fromYear, empty: "Siempre").frame(width: 160)
                    yearPicker("Hasta", selection: $filter.toYear, empty: "Hoy").frame(width: 150)
                }
                VStack(alignment: .leading, spacing: 8) {
                    yearPicker("Desde", selection: $filter.fromYear, empty: "Siempre").frame(maxWidth: 240)
                    yearPicker("Hasta", selection: $filter.toYear, empty: "Hoy").frame(maxWidth: 240)
                }
            }
            FlowLayout(spacing: 6) {
                preset("Cualquier fecha", nil, nil)
                preset("Este año", currentYear, nil)
                preset("Desde \(currentYear - 1)", currentYear - 1, nil)
                preset("Últimos 5 años", currentYear - 4, nil)
                preset("Antes de 2020", nil, 2019)
            }
            Toggle("Incluir archivos sin fecha conocida", isOn: $filter.includeUndated)
                .disabled(!filter.hasDateRange)
            Text("La fecha sale de la foto (EXIF), del video o del sistema de archivos.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sizeBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tamaño mínimo").font(.headline)
            sizePicker
            Text("Sube el mínimo para saltarte íconos, miniaturas y archivos de sistema.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var sizePicker: some View {
        let picker = Picker("Tamaño mínimo", selection: $filter.minSize) {
            ForEach(sizes, id: \.1) { Text($0.0).tag($0.1) }
        }
        .labelsHidden()
        if width == .compact {
            picker.pickerStyle(.menu).frame(maxWidth: 240)
        } else {
            picker.pickerStyle(.segmented).frame(maxWidth: 460)
        }
    }

    private func yearPicker(_ title: String, selection: Binding<Int?>, empty: String) -> some View {
        Picker(title, selection: selection) {
            Text(empty).tag(Int?.none)
            ForEach(yearOptions, id: \.self) { Text(String($0)).tag(Int?.some($0)) }
        }
    }

    private func preset(_ title: String, _ from: Int?, _ to: Int?) -> some View {
        let active = filter.fromYear == from && filter.toYear == to
        return Button {
            withAnimation(.snappy(duration: 0.18)) {
                filter.fromYear = from
                filter.toYear = to
            }
        } label: {
            Text(title)
                .font(.caption.weight(active ? .semibold : .regular))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(active ? Palette.accent.opacity(0.2) : Color.primary.opacity(0.05), in: Capsule())
                .overlay(Capsule().strokeBorder(active ? Palette.accent.opacity(0.6) : .clear))
                .foregroundStyle(active ? Palette.accent : .secondary)
        }
        .buttonStyle(PressableStyle())
    }
}

private struct CategoryRow: View {
    let category: FileCategory
    let chips: [TypeChip]
    @Binding var selected: Set<String>

    private var labels: Set<String> { Set(chips.map(\.label)) }
    private var allOn: Bool { labels.isSubset(of: selected) }
    private var someOn: Bool { !labels.isDisjoint(with: selected) }

    @Environment(\.widthClass) private var width

    var body: some View {
        if width == .compact {
            VStack(alignment: .leading, spacing: 8) {
                categoryButton
                chipCloud
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                categoryButton.frame(width: 134, alignment: .leading)
                chipCloud
            }
        }
    }

    private var categoryButton: some View {
        Button {
            withAnimation(.snappy(duration: 0.18)) {
                if allOn { selected.subtract(labels) } else { selected.formUnion(labels) }
            }
            Signals.play(.tap)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: allOn ? "checkmark.square.fill" : someOn ? "minus.square.fill" : "square")
                    .foregroundStyle(someOn ? Palette.accent : .secondary)
                    .contentTransition(.symbolEffect(.replace))
                Text(category.rawValue).fontWeight(.medium)
            }
        }
        .buttonStyle(.plain)
    }

    private var chipCloud: some View {
        FlowLayout(spacing: 6) {
            ForEach(chips) { chip in
                ChipPill(chip: chip, on: selected.contains(chip.label)) {
                    withAnimation(.snappy(duration: 0.18)) {
                        if selected.contains(chip.label) {
                            selected.remove(chip.label)
                        } else {
                            selected.insert(chip.label)
                        }
                    }
                }
            }
        }
    }
}

private struct ChipPill: View {
    let chip: TypeChip
    let on: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(chip.label)
                if !chip.deepScannable { Circle().fill(.orange).frame(width: 5, height: 5) }
            }
            .font(.callout.weight(on ? .semibold : .regular))
            .padding(.horizontal, 11)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(
                    on
                        ? AnyShapeStyle(LinearGradient(colors: [Palette.accent.opacity(0.24), Palette.secondary.opacity(0.18)],
                                                       startPoint: .topLeading, endPoint: .bottomTrailing))
                        : AnyShapeStyle(Color.primary.opacity(hovering ? 0.09 : 0.05))
                )
            )
            .overlay(
                Capsule().strokeBorder(
                    on ? Palette.accent.opacity(0.72) : (hovering ? Palette.accent.opacity(0.3) : .clear),
                    lineWidth: 1
                )
            )
            .foregroundStyle(on ? Palette.accent : .secondary)
            .scaleEffect(hovering ? 1.03 : 1)
            .animation(.snappy(duration: 0.15), value: hovering)
            .animation(.snappy(duration: 0.16), value: on)
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .help(chip.extensions.filter { $0 != "*" }.map { ".\($0)" }.joined(separator: " "))
    }
}
