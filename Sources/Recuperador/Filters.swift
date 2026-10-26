import Foundation
import RecoveryCore

/// Un botón de tipo de archivo en la pantalla inicial ("RAW" agrupa cr2, nef, arw...).
struct TypeChip: Identifiable, Hashable {
    let label: String
    let extensions: [String]
    var id: String { label }

    /// Falso si el formato no tiene firma: solo se encuentra por nombre (escaneo rápido).
    var deepScannable: Bool { !Set(extensions).isDisjoint(with: Signatures.allExtensions) || extensions == ["*"] }
}

enum TypeCatalog {
    static let groups: [(category: FileCategory, chips: [TypeChip])] = [
        (.photo, [chip("JPG", "jpg", "jpeg"), chip("HEIC", "heic"), chip("PNG", "png"),
                  chip("RAW", "cr2", "cr3", "nef", "arw", "dng", "orf", "pef"), chip("GIF", "gif"),
                  chip("TIFF", "tif", "tiff"), chip("WebP", "webp"), chip("AVIF", "avif"), chip("BMP", "bmp"), chip("PSD", "psd")]),
        (.video, [chip("MP4", "mp4", "m4v"), chip("MOV", "mov"), chip("AVI", "avi"), chip("MKV", "mkv"), chip("WebM", "webm"),
                  chip("MTS", "mts", "m2ts", "ts"), chip("WMV", "wmv"), chip("3GP", "3gp"), chip("MPG", "mpg"),
                  chip("FLV", "flv"), chip("OGV", "ogv")]),
        (.audio, [chip("MP3", "mp3"), chip("M4A", "m4a"), chip("WAV", "wav"), chip("FLAC", "flac"), chip("AIFF", "aif", "aiff"),
                  chip("OGG", "ogg", "opus"), chip("WMA", "wma"), chip("MIDI", "mid")]),
        (.document, [chip("PDF", "pdf"), chip("Word", "doc", "docx"), chip("Excel", "xls", "xlsx"),
                     chip("PowerPoint", "ppt", "pptx"), chip("iWork", "pages", "numbers", "key"), chip("ODT", "odt"),
                     chip("RTF", "rtf"), chip("EPUB", "epub"), chip("Outlook", "msg"), chip("TXT", "txt")]),
        (.archive, [chip("ZIP", "zip"), chip("RAR", "rar"), chip("7z", "7z"), chip("GZ", "gz"), chip("ISO", "iso"),
                    chip("DMG", "dmg"), chip("IMG", "img"), chip("APK/JAR", "apk", "jar")]),
        (.other, [chip("SQLite", "sqlite"), chip("Cualquier otro", "*")]),
    ]

    static var allChips: [TypeChip] { groups.flatMap(\.chips) }
    static var knownExtensions: Set<String> { Set(allChips.flatMap(\.extensions)).subtracting(["*"]) }

    private static func chip(_ label: String, _ exts: String...) -> TypeChip { TypeChip(label: label, extensions: exts) }
}

/// Lo que el usuario quiere encontrar, elegido antes de escanear.
struct ScanFilter: Equatable {
    var chips: Set<String> = Set(TypeCatalog.allChips.map(\.label))
    var fromYear: Int?
    var toYear: Int?
    var includeUndated = true
    var minSize: Int64 = 0
    /// Fotos y documentos que viven dentro de un Word, un PDF o un ZIP.
    var includeEmbedded = false

    var extensions: Set<String> {
        Set(TypeCatalog.allChips.filter { chips.contains($0.label) }.flatMap(\.extensions))
    }

    var hasDateRange: Bool { fromYear != nil || toYear != nil }
    var isEverything: Bool { chips.count == TypeCatalog.allChips.count && !hasDateRange && minSize == 0 }

    func allows(ext: String) -> Bool {
        let exts = extensions
        return exts.contains(ext) || (exts.contains("*") && !TypeCatalog.knownExtensions.contains(ext))
    }

    func allows(year: Int) -> Bool {
        year >= (fromYear ?? .min) && year <= (toYear ?? .max)
    }

    /// Firmas del escaneo profundo que hacen falta para los tipos elegidos.
    var signatures: [FileSignature] {
        let exts = extensions
        if exts.contains("*") { return Signatures.all }
        return Signatures.all.filter { !Set($0.extensions).isDisjoint(with: exts) }
    }

    var summary: String {
        var parts: [String] = []
        if chips.count == TypeCatalog.allChips.count {
            parts.append("Todos los tipos")
        } else {
            let selected = TypeCatalog.allChips.filter { chips.contains($0.label) }.map(\.label)
            parts.append(selected.count <= 4 ? selected.joined(separator: ", ") : "\(selected.count) tipos")
        }
        switch (fromYear, toYear) {
        case let (f?, t?): parts.append(f == t ? "solo \(f)" : "\(f)–\(t)")
        case let (f?, nil): parts.append("desde \(f)")
        case let (nil, t?): parts.append("hasta \(t)")
        default: break
        }
        if minSize > 0 { parts.append("más de \(ByteCountFormatter.string(fromByteCount: minSize, countStyle: .file))") }
        if includeEmbedded { parts.append("también dentro de otros archivos") }
        return parts.joined(separator: " · ")
    }
}

/// Búsqueda en lenguaje natural ("el video más antiguo", "fotos de playa de febrero 2016").
/// Funciona con reglas, sin internet: reconoce tipos, meses, años, rangos y superlativos; lo que
/// sobra se busca como texto en nombres, etiquetas de la IA, cámara, etc.
struct SmartQuery: Equatable {
    enum Order: Equatable { case oldest, newest, largest, smallest }

    var categories: Set<FileCategory> = []
    var extensions: Set<String> = []
    var fromYear: Int?
    var toYear: Int?
    var months: Set<Int> = []
    var day: Int?
    var order: Order?
    /// "el video más antiguo" (singular + superlativo): seleccionar directamente el primero.
    var pickFirst = false
    var words: [String] = []

    var isEmpty: Bool { self == SmartQuery() }

    private static let monthNames = ["enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto",
                                     "septiembre", "octubre", "noviembre", "diciembre"]

    private static let categoryWords: [String: (FileCategory, singular: Bool)] = [
        "foto": (.photo, true), "fotos": (.photo, false), "fotografia": (.photo, true), "fotografias": (.photo, false),
        "imagen": (.photo, true), "imagenes": (.photo, false), "selfie": (.photo, true),
        "video": (.video, true), "videos": (.video, false), "pelicula": (.video, true), "peliculas": (.video, false),
        "grabacion": (.video, true), "grabaciones": (.video, false), "clip": (.video, true), "clips": (.video, false),
        "cancion": (.audio, true), "canciones": (.audio, false), "musica": (.audio, false), "audio": (.audio, true),
        "audios": (.audio, false), "tema": (.audio, true), "temas": (.audio, false),
        "documento": (.document, true), "documentos": (.document, false),
        "comprimido": (.archive, true), "comprimidos": (.archive, false),
    ]

    private static let extensionWords: [String: String] = [
        "word": "docx", "excel": "xlsx", "powerpoint": "pptx", "presentacion": "pptx", "planilla": "xlsx",
    ]

    private static let ignored: Set<String> = [
        "busco", "buscar", "buscame", "quiero", "encuentra", "encontrar", "muestrame", "mostrar", "dame", "ver",
        "un", "una", "unos", "unas", "el", "la", "los", "las", "lo", "de", "del", "en", "con", "que", "tenga", "tengan",
        "tiene", "sea", "sean", "mes", "año", "ano", "fecha", "data", "dato", "datos", "archivo", "archivos", "mi", "mis",
        "por", "favor", "ejemplo", "y", "o", "a", "al", "se", "me", "tomada", "tomadas", "tomado", "grabado", "grabada",
        "hecha", "hecho", "creado", "creada", "todas", "todos", "toda", "todo", "algun", "alguna", "cual", "cuál",
    ]

    static func parse(_ text: String, now: Date = Date()) -> SmartQuery {
        var q = SmartQuery()
        let folded = text.lowercased().folding(options: .diacriticInsensitive, locale: Locale(identifier: "es"))
        // Lo que parece un nombre de archivo ("img_0042", "dsc01234.jpg") se busca tal cual.
        var tokens: [String] = []
        for chunk in folded.split(whereSeparator: \.isWhitespace).map(String.init) {
            let core = chunk.trimmingCharacters(in: .punctuationCharacters)
            let mixed = core.contains(where: \.isLetter) && core.contains(where: \.isNumber)
            if !TypeCatalog.knownExtensions.contains(core), core.contains("_") || core.contains(".") || mixed {
                q.words.append(core)
            } else {
                tokens += chunk.split { !$0.isLetter && !$0.isNumber }.map(String.init)
            }
        }
        let currentYear = Calendar.current.component(.year, from: now)
        var singular = false
        var i = 0

        func year(_ t: String) -> Int? {
            guard t.count == 4, let y = Int(t), (1970...2100).contains(y) else { return nil }
            return y
        }

        while i < tokens.count {
            let t = tokens[i]
            let next = i + 1 < tokens.count ? tokens[i + 1] : ""
            let afterNext = i + 2 < tokens.count ? tokens[i + 2] : ""
            defer { i += 1 }

            if t == "mas" || t == "el" && next == "mas" || t == "la" && next == "mas" {
                if t != "mas" { singular = true; continue }
                switch next {
                case "antiguo", "antigua", "antiguos", "antiguas", "viejo", "vieja", "viejos", "viejas": q.order = .oldest
                case "reciente", "recientes", "nuevo", "nueva", "nuevos", "nuevas", "actual": q.order = .newest
                case "grande", "grandes", "pesado", "pesada", "pesados", "pesadas", "largo", "larga", "largos", "largas": q.order = .largest
                case "pequeno", "pequena", "pequenos", "pequenas", "chico", "chica", "liviano", "liviana", "corto", "corta": q.order = .smallest
                default: break
                }
                if q.order != nil { i += 1 }
                continue
            }
            if ["primer", "primera", "primero"].contains(t) { q.order = .oldest; singular = true; continue }
            if ["ultimo", "ultima"].contains(t) { q.order = .newest; singular = true; continue }
            if t == "ultimos" || t == "ultimas", let n = Int(next), afterNext.hasPrefix("ano") {
                q.fromYear = currentYear - n + 1; q.toYear = currentYear; i += 2; continue
            }
            if t == "este" && next.hasPrefix("ano") { q.fromYear = currentYear; q.toYear = currentYear; i += 1; continue }
            if t.hasPrefix("ano") && next == "pasado" { q.fromYear = currentYear - 1; q.toYear = currentYear - 1; i += 1; continue }

            if let (category, isSingular) = categoryWords[t] {
                q.categories.insert(category)
                singular = singular || isSingular
                continue
            }
            if let ext = extensionWords[t] { q.extensions.insert(ext); continue }
            if TypeCatalog.knownExtensions.contains(t) { q.extensions.insert(t == "jpeg" ? "jpg" : t); continue }

            if let m = monthNames.firstIndex(of: t) ?? (t == "setiembre" ? 8 : nil) {
                q.months.insert(m + 1)
                continue
            }
            if let d = Int(t), (1...31).contains(d), next == "de", monthNames.contains(afterNext) {
                q.day = d
                continue
            }

            // Rangos de años: "entre 2018 y 2020", "desde 2019", "hasta 2020", "antes de 2015", "despues de 2010".
            if t == "entre", let a = year(next), afterNext == "y", i + 3 < tokens.count, let b = year(tokens[i + 3]) {
                q.fromYear = min(a, b); q.toYear = max(a, b); i += 3; continue
            }
            if ["desde", "despues"].contains(t) {
                let target = next == "de" || next == "del" ? afterNext : next
                if let y = year(target) { q.fromYear = t == "despues" ? y + 1 : y; i += target == next ? 1 : 2; continue }
            }
            if ["hasta", "antes"].contains(t) {
                let target = next == "de" || next == "del" ? afterNext : next
                if let y = year(target) { q.toYear = t == "antes" ? y - 1 : y; i += target == next ? 1 : 2; continue }
            }
            if let y = year(t) {
                if q.fromYear == nil && q.toYear == nil { q.fromYear = y; q.toYear = y }
                continue
            }
            if ignored.contains(t) || ["entre", "desde", "despues", "hasta", "antes"].contains(t) { continue }
            q.words.append(t)
        }
        q.pickFirst = singular && q.order != nil
        return q
    }

    /// Descripción de lo que se entendió, para mostrarla bajo el buscador.
    var chips: [String] {
        var out: [String] = []
        out += categories.sorted { $0.rawValue < $1.rawValue }.map(\.rawValue)
        out += extensions.sorted().map { $0.uppercased() }
        let monthText = months.sorted().map { Self.monthNames[$0 - 1].capitalized }.joined(separator: ", ")
        var dateText = monthText
        if let day, !monthText.isEmpty { dateText = "\(day) de \(monthText)" }
        switch (fromYear, toYear) {
        case let (f?, t?) where f == t: dateText += dateText.isEmpty ? "\(f)" : " \(f)"
        case let (f?, t?): dateText += (dateText.isEmpty ? "" : " · ") + "\(f)–\(t)"
        case let (f?, nil): dateText += (dateText.isEmpty ? "" : " · ") + "desde \(f)"
        case let (nil, t?): dateText += (dateText.isEmpty ? "" : " · ") + "hasta \(t)"
        default: break
        }
        if !dateText.isEmpty { out.append(dateText) }
        switch order {
        case .oldest: out.append(pickFirst ? "El más antiguo" : "Más antiguos primero")
        case .newest: out.append(pickFirst ? "El más reciente" : "Más recientes primero")
        case .largest: out.append(pickFirst ? "El más grande" : "Más grandes primero")
        case .smallest: out.append(pickFirst ? "El más pequeño" : "Más pequeños primero")
        case nil: break
        }
        out += words.map { "“\($0)”" }
        return out
    }

    @MainActor
    func matches(_ item: Item) -> Bool {
        if !categories.isEmpty || !extensions.isEmpty {
            let byCategory = categories.contains(item.category)
            let byExt = extensions.contains(item.file.ext) || (extensions.contains("docx") && item.file.ext == "doc")
                || (extensions.contains("xlsx") && item.file.ext == "xls") || (extensions.contains("pptx") && item.file.ext == "ppt")
            if !byCategory && !byExt { return false }
        }
        if fromYear != nil || toYear != nil || !months.isEmpty || day != nil {
            guard let date = item.date else { return false }
            let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
            if let fromYear, c.year! < fromYear { return false }
            if let toYear, c.year! > toYear { return false }
            if !months.isEmpty, !months.contains(c.month!) { return false }
            if let day, c.day != day { return false }
        }
        if order == .oldest || order == .newest, item.date == nil { return false }
        if !words.isEmpty {
            let text = item.searchText.folding(options: .diacriticInsensitive, locale: Locale(identifier: "es"))
            if !words.allSatisfy(text.contains) { return false }
        }
        return true
    }
}
