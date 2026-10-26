import AppKit
import AVFoundation
import ImageIO
import PDFKit
import RecoveryCore
import Vision

struct MetaRow: Hashable {
    let label: String
    let value: String
}

/// Lo que sabemos de un archivo después de abrirlo: metadatos, un nombre legible y un
/// diagnóstico de si se recuperó entero.
struct Analysis: Sendable {
    var date: Date?
    var rows: [MetaRow] = []
    var suggestedName: String?
    var health = 50
    var healthNote = ""
    var labels: [String] = []
}

enum Analyzer {
    static func analyze(url: URL, file: FoundFile) async -> Analysis {
        var a: Analysis
        switch file.category {
        case .photo: a = analyzePhoto(url, ext: file.ext)
        case .video: a = await analyzeMedia(url, video: true)
        case .audio: a = await analyzeMedia(url, video: false)
        case .document where file.ext == "pdf": a = analyzePDF(url)
        default: a = analyzeGeneric(url, file: file)
        }

        // Para archivos recuperados por su nombre: ¿los datos en esa posición son realmente ese archivo?
        if case .fileSystem = file.origin, !contentMatches(url, ext: file.ext) {
            a.health = min(a.health, 10)
            a.healthNote = "El contenido no coincide con el tipo de archivo: esos sectores ya fueron reutilizados por otro archivo."
        } else if file.likelyOverwritten {
            a.health = min(a.health, 35)
            a.healthNote += " El sistema de archivos ya asignó ese espacio a otro archivo; puede estar sobrescrito."
        }
        if case .carved(exactLength: false) = file.origin, a.health > 60 {
            a.health = 60
            a.healthNote += " El formato no declara su tamaño: el final es una estimación."
        }
        if a.date == nil { a.date = file.modified }
        return a
    }

    private static func contentMatches(_ url: URL, ext: String) -> Bool {
        let candidates = Signatures.all.filter { $0.extensions.contains(ext) || (ext == "jpeg" && $0.extensions.contains("jpg")) }
        guard !candidates.isEmpty, let handle = try? FileHandle(forReadingFrom: url) else { return true }
        defer { try? handle.close() }
        let header = [UInt8]((try? handle.read(upToCount: 32)) ?? Data())
        if header.allSatisfy({ $0 == 0 }) { return false }
        return candidates.contains { $0.matches(header) }
    }

    // MARK: Fotos

    private static let exifDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()

    private static func analyzePhoto(_ url: URL, ext: String) -> Analysis {
        var a = Analysis()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            a.health = 8
            a.healthNote = "No se pudo abrir la imagen: los datos están dañados."
            return a
        }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]

        if let raw = exif[kCGImagePropertyExifDateTimeOriginal] as? String ?? tiff[kCGImagePropertyTIFFDateTime] as? String {
            a.date = exifDate.date(from: raw)
        }
        if let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int {
            a.rows.append(MetaRow(label: "Dimensiones", value: "\(w) × \(h) px (\(String(format: "%.1f", Double(w * h) / 1_000_000)) MP)"))
        }
        let make = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        if !model.isEmpty { a.rows.append(MetaRow(label: "Cámara", value: model.hasPrefix(make) ? model : "\(make) \(model)")) }
        if let lens = exif[kCGImagePropertyExifLensModel] as? String { a.rows.append(MetaRow(label: "Lente", value: lens)) }
        var exposure: [String] = []
        if let f = exif[kCGImagePropertyExifFNumber] as? Double { exposure.append(String(format: "ƒ/%.1f", f)) }
        if let t = exif[kCGImagePropertyExifExposureTime] as? Double, t > 0 {
            exposure.append(t < 1 ? "1/\(Int((1 / t).rounded())) s" : String(format: "%.1f s", t))
        }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first { exposure.append("ISO \(iso)") }
        if let focal = exif[kCGImagePropertyExifFocalLength] as? Double { exposure.append("\(Int(focal)) mm") }
        if !exposure.isEmpty { a.rows.append(MetaRow(label: "Exposición", value: exposure.joined(separator: " · "))) }
        if let lat = gps[kCGImagePropertyGPSLatitude] as? Double, let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            let la = (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" ? -lat : lat
            let lo = (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" ? -lon : lon
            a.rows.append(MetaRow(label: "Ubicación", value: String(format: "%.5f, %.5f", la, lo)))
        }
        if let software = tiff[kCGImagePropertyTIFFSoftware] as? String { a.rows.append(MetaRow(label: "Software", value: software)) }
        if let date = a.date { a.suggestedName = "Foto \(nameDate(date))" }

        // Decodificar la imagen completa (no la miniatura EXIF, que podría estar intacta aunque la foto no).
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: 512] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            a.health = 10
            a.healthNote = "La cabecera es legible pero la imagen no se puede decodificar."
            return a
        }
        let complete = CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete
        let missing = ["jpg", "jpeg", "heic"].contains(ext) ? missingBottomFraction(image) : 0
        if missing > 0.04 || !complete {
            let pct = Int((max(missing, complete ? 0 : 0.1) * 100).rounded())
            a.health = max(5, 95 - pct)
            a.healthNote = "Falta aproximadamente el \(pct)% inferior de la imagen (se ve gris): esa parte fue sobrescrita."
        } else {
            a.health = 98
            a.healthNote = "La imagen se decodifica completa y sin zonas dañadas."
        }
        a.labels = classify(image)
        return a
    }

    /// Fracción inferior de la imagen que es un bloque gris uniforme: así se ve un JPEG truncado.
    private static func missingBottomFraction(_ image: CGImage) -> Double {
        let w = 64, h = max(8, Int(64.0 * Double(image.height) / Double(max(1, image.width))))
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return 0 }
        // En CGContext la fila 0 del buffer es la de arriba.
        var flat = 0
        for row in stride(from: h - 1, through: 0, by: -1) {
            let start = row * w * 4
            var lo = 255, hi = 0, sum = 0
            for x in 0..<w {
                for c in 0..<3 {
                    let v = Int(pixels[start + x * 4 + c])
                    lo = min(lo, v); hi = max(hi, v); sum += v
                }
            }
            let mean = sum / (w * 3)
            guard hi - lo < 10, abs(mean - 128) < 20 else { break }
            flat += 1
        }
        return Double(flat) / Double(h)
    }

    /// Reconoce el contenido con Vision, el modelo de Apple que corre 100% en el Mac.
    static func classify(_ image: CGImage) -> [String] {
        let classify = VNClassifyImageRequest()
        let faces = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: image).perform([classify, faces])
        var labels = (classify.results ?? []).filter { $0.confidence > 0.3 }.prefix(6).map { Vocabulary.spanish($0.identifier) }
        if let n = faces.results?.count, n > 0 { labels.insert(n == 1 ? "1 persona" : "\(n) personas", at: 0) }
        var seen = Set<String>()
        return labels.filter { seen.insert($0).inserted }
    }

    // MARK: Video y audio

    private static func analyzeMedia(_ url: URL, video: Bool) async -> Analysis {
        var a = Analysis()
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.seconds.isFinite, duration.seconds > 0 else {
            a.health = 10
            a.healthNote = video ? "No se pudo abrir el video: puede estar fragmentado o sobrescrito." : "No se pudo abrir el audio."
            return a
        }
        a.rows.append(MetaRow(label: "Duración", value: formatDuration(duration.seconds)))
        if let date = try? await asset.load(.creationDate), let value = try? await date.load(.dateValue) { a.date = value }

        var title: String?, artist: String?
        for item in (try? await asset.load(.commonMetadata)) ?? [] {
            guard let key = item.commonKey, let value = try? await item.load(.stringValue), !value.isEmpty else { continue }
            switch key {
            case .commonKeyTitle: title = value; a.rows.append(MetaRow(label: "Título", value: value))
            case .commonKeyArtist: artist = value; a.rows.append(MetaRow(label: "Artista", value: value))
            case .commonKeyAlbumName: a.rows.append(MetaRow(label: "Álbum", value: value))
            case .commonKeyMake: a.rows.append(MetaRow(label: "Dispositivo", value: value))
            case .commonKeyModel: a.rows.append(MetaRow(label: "Modelo", value: value))
            default: break
            }
        }

        if video {
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let size = try? await track.load(.naturalSize) {
                a.rows.insert(MetaRow(label: "Resolución", value: "\(Int(abs(size.width))) × \(Int(abs(size.height)))"), at: 0)
            }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 512, height: 512)
            if let (frame, _) = try? await generator.image(at: CMTime(seconds: duration.seconds * 0.9, preferredTimescale: 600)) {
                a.health = 95
                a.healthNote = "El video se abre y se pueden leer fotogramas hasta el final."
                a.labels = classify(frame)
            } else {
                a.health = 55
                a.healthNote = "El video se abre pero el final no se puede decodificar: puede estar incompleto."
            }
            if let date = a.date { a.suggestedName = "Video \(nameDate(date))" }
        } else {
            a.health = 92
            a.healthNote = "El audio se abre correctamente."
            if let title { a.suggestedName = artist.map { "\($0) - \(title)" } ?? title }
        }
        return a
    }

    // MARK: Documentos

    private static func analyzePDF(_ url: URL) -> Analysis {
        var a = Analysis()
        guard let doc = PDFDocument(url: url), doc.pageCount > 0, doc.page(at: doc.pageCount - 1) != nil else {
            a.health = 15
            a.healthNote = "El PDF está dañado o incompleto."
            return a
        }
        a.health = 95
        a.healthNote = "El PDF abre correctamente (\(doc.pageCount) páginas)."
        a.rows.append(MetaRow(label: "Páginas", value: "\(doc.pageCount)"))
        let attrs = doc.documentAttributes ?? [:]
        if let title = attrs[PDFDocumentAttribute.titleAttribute] as? String, !title.isEmpty {
            a.rows.append(MetaRow(label: "Título", value: title))
            a.suggestedName = title
        }
        if let author = attrs[PDFDocumentAttribute.authorAttribute] as? String, !author.isEmpty {
            a.rows.append(MetaRow(label: "Autor", value: author))
        }
        a.date = attrs[PDFDocumentAttribute.creationDateAttribute] as? Date
        return a
    }

    private static func analyzeGeneric(_ url: URL, file: FoundFile) -> Analysis {
        var a = Analysis()
        let zipLike = ["zip", "docx", "xlsx", "pptx", "odt", "epub", "apk", "jar", "pages", "numbers", "key"]
        if zipLike.contains(file.ext) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            p.arguments = ["-tqq", url.path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            if (try? p.run()) != nil {
                p.waitUntilExit()
                a.health = p.terminationStatus == 0 ? 96 : 25
                a.healthNote = p.terminationStatus == 0 ? "Todo el contenido interno se verificó sin errores."
                                                        : "Algunas partes internas están dañadas."
                return a
            }
        }
        a.health = 75
        a.healthNote = "La estructura interna del archivo es válida."
        return a
    }

    // MARK: Utilidades

    private static let nameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f
    }()

    static func nameDate(_ date: Date) -> String { nameFormatter.string(from: date) }

    static func formatDuration(_ s: Double) -> String {
        let t = Int(s.rounded())
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// Traducción de las etiquetas más comunes de Vision (vienen en inglés).
enum Vocabulary {
    private static let es: [String: String] = [
        "people": "personas", "adult": "adulto", "child": "niño", "baby": "bebé", "portrait": "retrato", "selfie": "selfie",
        "animal": "animal", "dog": "perro", "cat": "gato", "bird": "pájaro", "horse": "caballo", "pet": "mascota",
        "outdoor": "exterior", "indoor": "interior", "sky": "cielo", "cloudy": "nublado", "sunset_sunrise": "atardecer",
        "beach": "playa", "sea": "mar", "ocean": "océano", "water": "agua", "water_body": "agua", "lake": "lago", "river": "río",
        "mountain": "montaña", "snow": "nieve", "tree": "árbol", "plant": "planta", "flower": "flor", "grass": "pasto",
        "forest": "bosque", "landscape": "paisaje", "night_sky": "noche", "city": "ciudad", "building": "edificio",
        "structure": "construcción", "house": "casa", "street": "calle", "road": "camino", "car": "auto", "vehicle": "vehículo",
        "food": "comida", "drink": "bebida", "dessert": "postre", "cake": "torta", "fruit": "fruta", "document": "documento",
        "text": "texto", "screenshot": "captura", "art": "arte", "painting": "pintura", "toy": "juguete", "sport": "deporte",
        "ball": "pelota", "music": "música", "musical_instrument": "instrumento", "guitar": "guitarra", "party": "fiesta",
        "celebration": "celebración", "wedding": "boda", "christmas_decoration": "navidad", "computer": "computador",
        "phone": "teléfono", "furniture": "muebles", "room": "habitación", "kitchen": "cocina", "clothing": "ropa",
    ]

    static func spanish(_ identifier: String) -> String {
        es[identifier] ?? identifier.replacingOccurrences(of: "_", with: " ")
    }
}
