import Foundation

/// Un tipo de archivo que el carver sabe reconocer por su firma y cuya longitud sabe deducir
/// leyendo su estructura interna (no depende del sistema de archivos, que puede estar borrado).
public protocol FileSignature: Sendable {
    var name: String { get }
    /// Extensiones que puede producir; sirven para filtrar con --tipos.
    var extensions: [String] { get }
    /// Primeros bytes posibles, para descartar rápido la gran mayoría de sectores.
    var firstBytes: Set<UInt8> { get }
    /// Falso si el formato no declara su tamaño y la longitud es una estimación.
    var exactLength: Bool { get }
    /// Distancia entre el inicio del archivo y la firma (casi siempre 0; en ISO la firma está en 0x8001).
    var headerOffset: Int64 { get }
    func matches(_ header: [UInt8]) -> Bool
    /// Longitud total y extensión del archivo que empieza en `offset`, o nil si no es válido.
    func carve(at offset: Int64, reader: DiskReader) -> (length: Int64, ext: String)?
}

extension FileSignature {
    public var exactLength: Bool { true }
    public var headerOffset: Int64 { 0 }
}

public enum Signatures {
    public static let all: [FileSignature] = [
        JPEGSignature(), PNGSignature(), GIFSignature(), BMPSignature(), TIFFSignature(), PSDSignature(),
        ISOMediaSignature(), RIFFSignature(), MatroskaSignature(), ASFSignature(), FLVSignature(),
        MPEGPSSignature(), TransportStreamSignature(), MP3Signature(), OggSignature(), FLACSignature(),
        AIFFSignature(), MIDISignature(), PDFSignature(), ZIPSignature(), OLESignature(), RTFSignature(),
        SevenZipSignature(), RARSignature(), GZipSignature(), ISOSignature(), SQLiteSignature(),
    ]

    public static var allExtensions: [String] { all.flatMap(\.extensions) }

    /// ¿Empieza algún archivo conocido en este bloque?
    static func anyHeader(_ block: [UInt8]) -> Bool {
        guard let first = block.first else { return false }
        return all.contains { $0.firstBytes.contains(first) && $0.matches(block) }
    }
}

// MARK: - Utilidades de lectura

extension Array where Element == UInt8 {
    func be16(_ i: Int) -> Int { Int(self[i]) << 8 | Int(self[i + 1]) }
    func be24(_ i: Int) -> Int64 { Int64(self[i]) << 16 | Int64(self[i + 1]) << 8 | Int64(self[i + 2]) }
    func be32(_ i: Int) -> Int64 { (i..<(i + 4)).reduce(0) { $0 << 8 | Int64(self[$1]) } }
    func be64(_ i: Int) -> Int64 { (i..<(i + 8)).reduce(0) { $0 << 8 | Int64(self[$1]) } }
    func le16(_ i: Int) -> Int { Int(self[i]) | Int(self[i + 1]) << 8 }
    func le32(_ i: Int) -> Int64 { (i..<(i + 4)).reversed().reduce(0) { $0 << 8 | Int64(self[$1]) } }
    func le64(_ i: Int) -> Int64 { (i..<(i + 8)).reversed().reduce(0) { $0 << 8 | Int64(self[$1]) } }
    func starts(with prefix: String, at i: Int = 0) -> Bool {
        let p = Array(prefix.utf8)
        return count >= i + p.count && self[i..<(i + p.count)].elementsEqual(p)
    }
    func starts(with prefix: [UInt8], at i: Int = 0) -> Bool {
        count >= i + prefix.count && self[i..<(i + prefix.count)].elementsEqual(prefix)
    }
    func ascii(_ range: Range<Int>) -> String { String(decoding: self[range], as: UTF8.self) }
}

let MB: Int64 = 1 << 20

/// Para formatos que no declaran su tamaño: el archivo termina donde empieza otro archivo
/// conocido o donde aparece una racha larga de ceros (sectores nunca usados).
enum Fallback {
    static func length(at offset: Int64, reader: DiskReader, max: Int64) -> Int64 {
        let end = min(reader.size, offset + max)
        var pos = offset + 512
        var zeroRun: Int64 = 0
        while pos < end {
            let block = reader.bytes(at: pos, count: 512)
            if block.allSatisfy({ $0 == 0 }) {
                zeroRun += 512
                if zeroRun >= 32 * 1024 { return pos - zeroRun + 512 - offset }
            } else {
                if Signatures.anyHeader(block) { return pos - zeroRun - offset }
                zeroRun = 0
            }
            pos += 512
        }
        return end - offset - zeroRun
    }
}

// MARK: - JPEG

/// Recorre los segmentos hasta SOS (Start of Scan) y luego busca FFD9. Así las miniaturas EXIF,
/// que viven dentro del segmento APP1, no cortan el archivo antes de tiempo.
struct JPEGSignature: FileSignature {
    let name = "JPEG"
    let extensions = ["jpg"]
    let firstBytes: Set<UInt8> = [0xFF]
    let maxSize = 64 * MB

    func matches(_ h: [UInt8]) -> Bool {
        h.count >= 4 && h[0] == 0xFF && h[1] == 0xD8 && h[2] == 0xFF
            && ((0xE0...0xEF).contains(h[3]) || [0xDB, 0xC4, 0xC0, 0xFE].contains(h[3]))
    }

    func carve(at offset: Int64, reader: DiskReader) -> (length: Int64, ext: String)? {
        var pos = offset + 2
        for _ in 0..<512 {
            let b = reader.bytes(at: pos, count: 4)
            guard b.count == 4, b[0] == 0xFF else { return nil }
            let marker = b[1]
            if marker == 0xFF { pos += 1; continue }
            if marker == 0xD9 { return nil }
            if (0xD0...0xD8).contains(marker) || marker == 0x01 { pos += 2; continue }
            let segment = Int64(b.be16(2))
            guard segment >= 2 else { return nil }
            if marker == 0xDA {
                guard let end = reader.find([0xFF, 0xD9], from: pos + 2 + segment, limit: offset + maxSize) else { return nil }
                return (end + 2 - offset, "jpg")
            }
            pos += 2 + segment
            guard pos - offset < maxSize else { return nil }
        }
        return nil
    }
}

// MARK: - PNG

struct PNGSignature: FileSignature {
    let name = "PNG"
    let extensions = ["png"]
    let firstBytes: Set<UInt8> = [0x89]
    private let magic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    func matches(_ h: [UInt8]) -> Bool { h.starts(with: magic) }

    func carve(at offset: Int64, reader: DiskReader) -> (length: Int64, ext: String)? {
        var pos = offset + 8
        while pos - offset < 512 * MB {
            let c = reader.bytes(at: pos, count: 8)
            guard c.count == 8 else { return nil }
            let length = c.be32(0)
            guard length < 1 << 31, c[4..<8].allSatisfy({ (0x41...0x5A).contains($0 & 0xDF) }) else { return nil }
            pos += 12 + length
            if c.starts(with: "IEND", at: 4) { return (pos - offset, "png") }
        }
        return nil
    }
}

// MARK: - GIF

struct GIFSignature: FileSignature {
    let name = "GIF"
    let extensions = ["gif"]
    let firstBytes: Set<UInt8> = [0x47]

    func matches(_ h: [UInt8]) -> Bool { h.starts(with: "GIF87a") || h.starts(with: "GIF89a") }

    func carve(at offset: Int64, reader: DiskReader) -> (length: Int64, ext: String)? {
        let screen = reader.bytes(at: offset + 6, count: 7)
        guard screen.count == 7 else { return nil }
        var pos = offset + 13
        if screen[4] & 0x80 != 0 { pos += 3 << (Int64(screen[4] & 0x07) + 1) }

        func skipSubBlocks() -> Bool {
            while true {
                guard let n = reader.bytes(at: pos, count: 1).first else { return false }
                pos += 1 + Int64(n)
                if n == 0 { return true }
                if pos - offset > 128 * MB { return false }
            }
        }

        while pos - offset < 128 * MB {
            guard let block = reader.bytes(at: pos, count: 1).first else { return nil }
            switch block {
            case 0x3B:
                return (pos + 1 - offset, "gif")
            case 0x21:
                pos += 2
                guard skipSubBlocks() else { return nil }
            case 0x2C:
                let d = reader.bytes(at: pos, count: 10)
                guard d.count == 10 else { return nil }
                pos += 10
                if d[9] & 0x80 != 0 { pos += 3 << (Int64(d[9] & 0x07) + 1) }
                pos += 1 // tamaño mínimo de código LZW
                guard skipSubBlocks() else { return nil }
            default:
                return nil
            }
        }
        return nil
    }
}

// MARK: - BMP

struct BMPSignature: FileSignature {
    let name = "BMP"
    let extensions = ["bmp"]
    let firstBytes: Set<UInt8> = [0x42]

    func matches(_ h: [UInt8]) -> Bool {
        guard h.count >= 18, h.starts(with: "BM"), h.le32(6) == 0 else { return false }
        let size = h.le32(2), dataOffset = h.le32(10)
        return [12, 40, 52, 56, 108, 124].contains(h.le32(14)) && dataOffset < size && size > 64
    }

    func carve(at offset: Int64, reader: DiskReader) -> (length: Int64, ext: String)? {
        let h = reader.bytes(at: offset, count: 6)
        guard h.count == 6 else { return nil }
        return (h.le32(2), "bmp")
    }
}

// MARK: - TIFF y RAW de cámaras (CR2, NEF, ARW, DNG, PEF...)

/// El tamaño es el final del último dato referenciado desde cualquier IFD (tiras, teselas,
/// miniaturas, MakerNote...).
struct TIFFSignature: FileSignature {
    let name = "TIFF/RAW"
    let extensions = ["tif", "cr2", "nef", "arw", "dng", "pef", "orf"]
    let firstBytes: Set<UInt8> = [0x49, 0x4D]

    func matches(_ h: [UInt8]) -> Bool {
        h.starts(with: [0x49, 0x49, 0x2A, 0x00]) || h.starts(with: [0x4D, 0x4D, 0x00, 0x2A])
            || h.starts(with: [0x49, 0x49, 0x52, 0x4F]) // ORF de Olympus
    }

    func carve(at offset: Int64, reader: DiskReader) -> (length: Int64, ext: String)? {
        let head = reader.bytes(at: offset, count: 16)
        guard head.count == 16 else { return nil }
        let little = head[0] == 0x49
        func u16(_ b: [UInt8], _ i: Int) -> Int64 { Int64(little ? b.le16(i) : b.be16(i)) }
        func u32(_ b: [UInt8], _ i: Int) -> Int64 { little ? b.le32(i) : b.be32(i) }
        let typeSize: [Int64: Int64] = [1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8, 13: 4]
        let limit = 512 * MB

        var queue = [u32(head, 4)]
        var visited = Set<Int64>()
        var maxEnd: Int64 = 8
        var make = ""
        var isDNG = false

        func readArray(_ type: Int64, _ count: Int64, _ value: Int64, _ raw: [UInt8], _ at: Int) -> [Int64] {
            let size = typeSize[type] ?? 4
            let n = Int(min(count, 100_000))
            let data = size * count <= 4 ? Array(raw[at..<(at + 4)]) : reader.bytes(at: offset + value, count: n * Int(size))
            return (0..<n).compactMap { i in
                let p = i * Int(size)
                guard p + Int(size) <= data.count else { return nil }
                return size == 2 ? u16(data, p) : u32(data, p)
            }
        }

        while let ifd = queue.popLast(), visited.count < 64 {
            guard ifd >= 8, ifd < limit, visited.insert(ifd).inserted else { continue }
            let countBytes = reader.bytes(at: offset + ifd, count: 2)
            guard countBytes.count == 2 else { return nil }
            let n = u16(countBytes, 0)
            guard n > 0, n < 1000 else { if ifd == u32(head, 4) { return nil }; continue }
            let raw = reader.bytes(at: offset + ifd + 2, count: Int(n) * 12 + 4)
            guard raw.count == Int(n) * 12 + 4 else { return nil }
            maxEnd = max(maxEnd, ifd + 2 + n * 12 + 4)

            var strips: [Int64] = [], stripCounts: [Int64] = []
            var thumb: Int64 = 0, thumbLength: Int64 = 0
            for e in 0..<Int(n) {
                let at = e * 12
                let tag = u16(raw, at), type = u16(raw, at + 2), count = u32(raw, at + 4), value = u32(raw, at + 8)
                let dataLength = (typeSize[type] ?? 1) * count
                if dataLength > 4 { maxEnd = max(maxEnd, value + dataLength) }
                switch tag {
                case 0x111, 0x144: strips = readArray(type, count, value, raw, at + 8)
                case 0x117, 0x145: stripCounts = readArray(type, count, value, raw, at + 8)
                case 0x201: thumb = value
                case 0x202: thumbLength = value
                case 0x14A, 0x8769: queue += readArray(type, count, value, raw, at + 8)
                case 0x10F:
                    let bytes = dataLength > 4 ? reader.bytes(at: offset + value, count: Int(min(dataLength, 32)))
                                               : Array(raw[(at + 8)..<(at + 12)])
                    make = String(decoding: bytes, as: UTF8.self)
                case 0xC612: isDNG = true
                default: break
                }
            }
            for (o, c) in zip(strips, stripCounts) { maxEnd = max(maxEnd, o + c) }
            if thumbLength > 0 { maxEnd = max(maxEnd, thumb + thumbLength) }
            let next = u32(raw, Int(n) * 12)
            if next != 0 { queue.append(next) }
        }
        guard maxEnd > 64, maxEnd < limit else { return nil }

        let ext: String
        let upper = make.uppercased()
        if head.starts(with: "CR", at: 8) || upper.hasPrefix("CANON") { ext = "cr2" }
        else if isDNG { ext = "dng" }
        else if upper.hasPrefix("NIKON") { ext = "nef" }
        else if upper.hasPrefix("SONY") { ext = "arw" }
        else if upper.hasPrefix("PENTAX") || upper.hasPrefix("RICOH") { ext = "pef" }
        else if upper.hasPrefix("OLYMPUS") || head[2] == 0x52 { ext = "orf" }
        else { ext = "tif" }
        return (maxEnd, ext)
    }
}

// MARK: - PSD (Photoshop)

struct PSDSignature: FileSignature {
    let name = "Photoshop"
    let extensions = ["psd"]
    let firstBytes: Set<UInt8> = [0x38]

    func matches(_ h: [UInt8]) -> Bool { h.starts(with: "8BPS") && h.be16(4) == 1 }

    func carve(at offset: Int64, reader: DiskReader) -> (length: Int64, ext: String)? {
        let h = reader.bytes(at: offset, count: 26)
        guard h.count == 26 else { return nil }
        let channels = Int64(h.be16(12)), height = h.be32(14), width = h.be32(18), depth = Int64(h.be16(22))
        guard (1...56).contains(channels), height > 0, width > 0, [1, 8, 16, 32].contains(depth) else { return nil }
        var pos = offset + 26
        for _ in 0..<3 { // modo de color, recursos de imagen, capas y máscaras
            let l = reader.bytes(at: pos, count: 4)
            guard l.count == 4 else { return nil }
            pos += 4 + l.be32(0)
        }
        let c = reader.bytes(at: pos, count: 2)
        guard c.count == 2 else { return nil }
        pos += 2
        switch c.be16(0) {
        case 0:
            pos += channels * height * ((width * depth + 7) / 8)
        case 1:
            let rows = Int(channels * height)
            let table = reader.bytes(at: pos, count: rows * 2)
            guard table.count == rows * 2 else { return nil }
            pos += Int64(rows * 2) + (0..<rows).reduce(Int64(0)) { $0 + Int64(table.be16($1 * 2)) }
        default:
            return nil
        }
        return pos - offset < 2048 * MB ? (pos - offset, "psd") : nil
    }
}

// MARK: - ISO Base Media (mp4, mov, m4a, heic, avif, cr3, 3gp)

/// Recorre las "cajas" de nivel superior; el archivo termina donde aparece una caja inválida.
struct ISOMediaSignature: FileSignature {
    let name = "MP4/MOV/HEIC"
    let extensions = ["mp4", "mov", "m4a", "m4v", "heic", "avif", "cr3", "3gp"]
    let firstBytes: Set<UInt8> = [0x00]
    private let knownBoxes: Set<String> = [
        "ftyp", "moov", "mdat", "free", "skip", "wide", "uuid", "meta", "pdin", "moof",
        "mfra", "styp", "sidx", "prft", "emsg", "pnot", "PICT", "idat", "iinf", "iloc",
    ]

    func matches(_ h: [UInt8]) -> Bool {
        guard h.count >= 12, h.starts(with: "ftyp", at: 4) else { return false }
        let size = h.be32(0)
        return size >= 12 && size <= 512
    }

    func carve(at offset: Int64, reader: DiskReader) -> (length: Int64, ext: String)? {
        let brand = reader.bytes(at: offset + 8, count: 4).ascii(0..<4)
        var pos = offset
        var sawPayload = false
        while pos < reader.size {
            let b = reader.bytes(at: pos, count: 16)
            guard b.count >= 8 else { break }
            let type = b.ascii(4..<8)
            guard knownBoxes.contains(type) else { break }
            var size = b.be32(0)
            if size == 1 {
                guard b.count == 16 else { break }
                size = b.be64(8)
            } else if size == 0 {
                size = reader.size - pos // la caja se extiende hasta el final
            }
            guard size >= 8 else { break }
            if ["moov", "mdat", "meta", "moof"].contains(type) { sawPayload = true }
            pos += size
        }
        guard sawPayload, pos > offset else { return nil }
        return (min(pos, reader.size) - offset, ext(for: brand))
    }

    private func ext(for brand: String) -> String {
        switch brand {
        case "qt  ": return "mov"
        case "heic", "heix", "heim", "heis", "hevc", "mif1", "msf1": return "heic"
        case "avif", "avis": return "avif"
        case "M4A ", "M4B ", "M4P ": return "m4a"
        case "M4V ", "M4VH", "M4VP": return "m4v"
        case "crx ": return "cr3"
        case let b where b.hasPrefix("3g"): return "3gp"
        default: return "mp4"
        }
    }
}

// MARK: - RIFF (wav, avi, webp)

struct RIFFSignature: FileSignature {
    let name = "WAV/AVI/WebP"
    let extensions = ["wav", "avi", "webp"]
    let firstBytes: Set<UInt8> = [0x52]

    func matches(_ h: [UInt8]) -> Bool {
        h.starts(with: "RIFF") && (h.starts(with: "WAVE", at: 8) || h.starts(with: "AVI ", at: 8) || h.starts(with: "WEBP", at: 8))
    }

    func carve(at offset: Int64, reader: DiskReader) -> (length: Int64, ext: String)? {
        let h = reader.bytes(at: offset, count: 12)
        guard h.count == 12 else { return nil }
        let ext = h.ascii(8..<12).trimmingCharacters(in: .whitespaces).lowercased()
        return (h.le32(4) + 8, ext == "wave" ? "wav" : ext)
    }
}

// MARK: - Matroska / WebM

struct MatroskaSignature: FileSignature {
    let name = "MKV/WebM"
    let extensions = ["mkv", "webm"]
    let firstBytes: Set<UInt8> = [0x1A]
    var exactLength: Bool { true }

    func matches(_ h: [UInt8]) -> Bool { h.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) }

    /// Entero de longitud variable de EBML: (valor, bytes usados, ¿tamaño desconocido?).
    private func vint(_ b: [UInt8], _ i: Int) -> (Int64, Int, Bool)? {
        guard i < b.count, b[i] != 0 else { return nil }
        let len = b[i].leadingZeroBitCount + 1
        guard i + len <= b.count else { return nil }
        var value = Int64(b[i] & (0xFF >> len))
        var allOnes = value == Int64(0xFF >> len)
        for j in 1..<len {
            value = value << 8 | Int64(b[i + j])
            allOnes = allOnes && b[i + j] == 0xFF
        }
        return (value, len, allOnes)
    }

    func carve(at offset: Int64, reader: DiskReader) -> (length: Int64, ext: String)? {
        let b = reader.bytes(at: offset, count: 4096)
        guard let (headerSize, hl, _) = vint(b, 4), headerSize < 4000 else { return nil }
        let headerEnd = 4 + hl + Int(headerSize)
        let ext = b.ascii(0..<min(b.count, headerEnd)).contains("webm") ? "webm" : "mkv"
        guard b.starts(with: [0x18, 0x53, 0x80, 0x67], at: headerEnd),
              let (segment, sl, unknown) = vint(b, headerEnd + 4) else { return nil }
        if unknown { return (Fallback.length(at: offset, reader: reader, max: 8192 * MB), ext) }
        return (Int64(headerEnd + 4 + sl) + segment, ext)
    }
}

// MARK: - ASF (wmv, wma)

struct ASFSignature: FileSignature {
    let name = "WMV/WMA"
    let extensions = ["wmv", "wma"]
    let firstBytes: Set<UInt8> = [0x30]
    private let header: [UInt8] = [0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11, 0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C]
    private let fileProperties: [UInt8] = [0xA1, 0xDC, 0xAB, 0x8C, 0x47, 0xA9, 0xCF, 0x11, 0x8E, 0xE4, 0x00, 0xC0, 0x0C, 0x20, 0x53, 0x65]
    private let videoMedia: [UInt8] = [0xC0, 0xEF, 0x19, 0xBC, 0x4D, 0x5B, 0xCF, 0x11, 0xA8, 0xFD, 0x00, 0x80, 0x5F, 0x5C, 0x44, 0x2B]

    func matches(_ h: [UInt8]) -> Bool { h.starts(with: header) }

    func carve(at offset: Int64, reader: DiskReader) -> (length: Int64, ext: String)? {
        let h = reader.bytes(at: offset, count: 24)
        guard h.count == 24 else { return nil }
        let headerSize = Int(min(h.le64(16), 256 * 1024))
        guard let props = reader.find(fileProperties, from: offset + 30, limit: offset + Int64(headerSize)) else { return nil }
        let p = reader.bytes(at: props + 40, count: 8)
        guard p.count == 8 else { return nil }
        let size = p.le64(0)
        guard size > Int64(headerSize) else { return nil }
        let isVideo = reader.find(videoMedia, from: offset, limit: offset + Int64(headerSize)) != nil
        return (size, isVideo ? "wmv" : "wma")
    }
}

// MARK: - FLV

struct FLVSignature: FileSignature {
    let name = "FLV"
    let extensions = ["flv"]
    let firstBytes: Set<UInt8> = [0x46]

    func matches(_ h: [UInt8]) -> Bool { h.starts(with: "FLV") && h[3] == 1 && h.be32(5) == 9 }

    func carve(at offset: Int64, reader: DiskReader) -> (length: Int64, ext: String)? {
        var pos = offset + 13
        var tags = 0
        while pos - offset < 8192 * MB {
            let t = reader.bytes(at: pos, count: 11)
            guard t.count == 11, [8, 9, 18].contains(t[0] & 0x1F) else { break }
            let dataSize = t.be24(1)
            let prev = reader.bytes(at: pos + 11 + dataSize, count: 4)
            guard prev.count == 4, prev.be32(0) == 11 + dataSize else { break }
            pos += 15 + dataSize
            tags += 1
        }
        return tags > 0 ? (pos - offset, "flv") : nil
    }
}

// MARK: - MPEG-PS (mpg, vob)

struct MPEGPSSignature: FileSignature {
    let name = "MPEG"
    let extensions = ["mpg"]
    let firstBytes: Set<UInt8> = [0x00]

    func matches(_ h: [UInt8]) -> Bool { h.starts(with: [0x00, 0x00, 0x01, 0xBA]) && (h[4] & 0xC4 == 0x44 || h[4] & 0xF1 == 0x21) }

    func carve(at offset: Int64, reader: DiskReader) -> (length: Int64, ext: String)? {
        var pos = offset
        var packs = 0
        while pos - offset < 8192 * MB {
            let b = reader.bytes(at: pos, count: 14)
            guard b.count == 14, b.starts(with: [0x00, 0x00, 0x01]) else { break }
            switch b[3] {
            case 0xBA: pos += b[4] & 0xC0 == 0x40 ? 14 + Int64(b[13] & 0x07) : 12; packs += 1
            case 0xB9: pos += 4; return packs > 1 ? (pos - offset, "mpg") : nil
            case 0xBB...0xFF: pos += 6 + Int64(b.be16(4))
            default: return packs > 2 ? (pos - offset, "mpg") : nil
            }
        }
        return packs > 2 ? (pos - offset, "mpg") : nil
    }
}

// MARK: - MPEG-TS (ts) y AVCHD (mts/m2ts de videocámaras)

struct TransportStreamSignature: FileSignature {
    let name = "MTS/TS"
    let extensions = ["mts", "ts"]
    let firstBytes: Set<UInt8> = Set(0x00...0x3F).union([0x47])

    func matches(_ h: [UInt8]) -> Bool {
        guard h.count >= 8 else { return false }
        if h[0] == 0x47 { return tsHeader(h, 0) }
        return h[4] == 0x47 && tsHeader(h, 4)
    }

    /// Sync 0x47, sin error de transporte, y con el campo de adaptación en un valor válido.
    private func tsHeader(_ h: [UInt8], _ i: Int) -> Bool {
        h[i] == 0x47 && h[i + 1] & 0x80 == 0 && h[i + 3] & 0x30 != 0
    }

    func carve(at offset: Int64, reader: DiskReader) -> (length: Int64, ext: String)? {
        let first = reader.bytes(at: offset, count: 192 * 8)
        guard first.count == 192 * 8 else { return nil }
        let (packet, sync, ext): (Int64, Int, String)
        if (0..<8).allSatisfy({ first[$0 * 192 + 4] == 0x47 }) { (packet, sync, ext) = (192, 4, "mts") }
        else if (0..<8).allSatisfy({ first[$0 * 188] == 0x47 }) { (packet, sync, ext) = (188, 0, "ts") }
        else { return nil }
        var pos = offset
        while pos - offset < 8192 * MB {
            let chunk = reader.bytes(at: pos, count: Int(packet) * 512)
            var i = 0
            while i + Int(packet) <= chunk.count, chunk[i + sync] == 0x47 { i += Int(packet) }
            pos += Int64(i)
            if i < chunk.count || chunk.isEmpty { break }
        }
        return (pos - offset, ext)
    }
}

// MARK: - MP3

/// Salta la etiqueta ID3v2 y recorre las tramas MPEG hasta que dejan de ser válidas.
struct MP3Signature: FileSignature {
    let name = "MP3"
    let extensions = ["mp3"]
    let firstBytes: Set<UInt8> = [0x49]
    private let rates: [[Int64]] = [[11025, 12000, 8000], [], [22050, 24000, 16000], [44100, 48000, 32000]]
    private let bitratesV1L3: [Int64] = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
    private let bitratesV1L2: [Int64] = [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384]
    private let bitratesV2: [Int64] = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]

    func matches(_ h: [UInt8]) -> Bool {
        h.starts(with: "ID3") && h[3] >= 2 && h[3] <= 4 && h[6..<10].allSatisfy { $0 < 0x80 }
    }

    func frameLength(_ b: [UInt8]) -> Int64? {
        guard b.count >= 4, b[0] == 0xFF, b[1] & 0xE0 == 0xE0 else { return nil }
        let version = Int(b[1] >> 3) & 3, layer = Int(b[1] >> 1) & 3
        let bitrateIndex = Int(b[2] >> 4), rateIndex = Int(b[2] >> 2) & 3, padding = Int64(b[2] >> 1) & 1
        guard version != 1, layer == 1 || layer == 2, (1...14).contains(bitrateIndex), rateIndex < 3 else { return nil }
        let bitrate = (version == 3 ? (layer == 1 ? bitratesV1L3 : bitratesV1L2) : bitratesV2)[bitrateIndex] * 1000
        let rate = rates[version][rateIndex]
        let factor: Int64 = version == 3 || layer == 2 ? 144 : 72
        return factor * bitrate / rate + padding
    }

    func carve(at offset: Int64, reader: DiskReader) -> (length: Int64, ext: String)? {
        let h = reader.bytes(at: offset, count: 10)
        guard h.count == 10 else { return nil }
        let tagSize = h[6..<10].reduce(Int64(0)) { $0 << 7 | Int64($1) }
        var pos = offset + 10 + tagSize + (h[5] & 0x10 != 0 ? 10 : 0)
        // Algunos codificadores dejan relleno después de la etiqueta.
        if let sync = reader.find([0xFF], from: pos, limit: pos + 64 * 1024) { pos = sync }
        var frames = 0
        while pos - offset < 512 * MB {
            let b = reader.bytes(at: pos, count: 4)
            guard let len = frameLength(b), len > 4 else {
                if b.starts(with: "TAG") { pos += 128 }
                break
            }
            pos += len
            frames += 1
        }
        return frames >= 2 ? (pos - offset, "mp3") : nil
    }
}

// MARK: - Ogg (ogg, opus, ogv)

struct OggSignature: FileSignature {
    let name = "Ogg"
    let extensions = ["ogg", "opus", "ogv"]
    let firstBytes: Set<UInt8> = [0x4F]

    func matches(_ h: [UInt8]) -> Bool { h.starts(with: "OggS") && h[4] == 0 && h[5] & 0x02 != 0 }

    func carve(at offset: Int64, reader: DiskReader) -> (length: Int64, ext: String)? {
        let firstPage = reader.bytes(at: offset, count: 64)
        let ext = firstPage.starts(with: "OpusHead", at: 28) ? "opus" : firstPage.starts(with: "theora", at: 29) ? "ogv" : "ogg"
        var pos = offset
        while pos - offset < 2048 * MB {
            let h = reader.bytes(at: pos, count: 27)
            guard h.count == 27, h.starts(with: "OggS") else { break }
            let segments = Int(h[26])
            let table = reader.bytes(at: pos + 27, count: segments)
            guard table.count == segments else { break }
            pos += 27 + Int64(segments) + table.reduce(Int64(0)) { $0 + Int64($1) }
        }
        return pos > offset ? (pos - offset, ext) : nil
    }
}

// MARK: - FLAC

struct FLACSignature: FileSignature {
    let name = "FLAC"
    let extensions = ["flac"]
    let firstBytes: Set<UInt8> = [0x66]
    var exactLength: Bool { false }

    func matches(_ h: [UInt8]) -> Bool { h.starts(with: "fLaC") && h[4] & 0x7F == 0 && h.be24(5) == 34 }

    func carve(at offset: Int64, reader: DiskReader) -> (length: Int64, ext: String)? {
        (Fallback.length(at: offset, reader: reader, max: 1024 * MB), "flac")
    }
}

// MARK: - AIFF

struct AIFFSignature: FileSignature {
    let name = "AIFF"
    let extensions = ["aif"]
    let firstBytes: Set<UInt8> = [0x46]

    func matches(_ h: [UInt8]) -> Bool { h.starts(with: "FORM") && (h.starts(with: "AIFF", at: 8) || h.starts(with: "AIFC", at: 8)) }

    func carve(at offset: Int64, reader: DiskReader) -> (length: Int64, ext: String)? {
        let h = reader.bytes(at: offset, count: 8)
        guard h.count == 8 else { return nil }
        return (h.be32(4) + 8, "aif")
    }
}

// MARK: - MIDI

struct MIDISignature: FileSignature {
    let name = "MIDI"
    let extensions = ["mid"]
    let firstBytes: Set<UInt8> = [0x4D]

    func matches(_ h: [UInt8]) -> Bool { h.starts(with: "MThd") && h.be32(4) == 6 }

    func carve(at offset: Int64, reader: DiskReader) -> (length: Int64, ext: String)? {
        var pos = offset + 14
        var tracks = 0
        while pos - offset < 64 * MB {
            let c = reader.bytes(at: pos, count: 8)
            guard c.count == 8, c.starts(with: "MTrk") else { break }
            pos += 8 + c.be32(4)
            tracks += 1
        }
        return tracks > 0 ? (pos - offset, "mid") : nil
    }
}

// MARK: - PDF

/// Los PDF linealizados (los "optimizados para web", muy comunes) declaran su longitud en /L.
/// Para el resto se corta en el primer %%EOF: los PDF con actualizaciones incrementales
/// pueden quedar truncados.
struct PDFSignature: FileSignature {
    let name = "PDF"
    let extensions = ["pdf"]
    let firstBytes: Set<UInt8> = [0x25]
    let maxSize = 512 * MB

    func matches(_ h: [UInt8]) -> Bool { h.starts(with: "%PDF-1.") || h.starts(with: "%PDF-2.") }

    func carve(at offset: Int64, reader: DiskReader) -> (length: Int64, ext: String)? {
        let head = String(decoding: reader.bytes(at: offset, count: 1024), as: UTF8.self)
        if head.contains("/Linearized"),
           let match = head.range(of: #"/L\s+(\d+)"#, options: .regularExpression),
           let length = Int64(head[match].dropFirst(2).trimmingCharacters(in: .whitespaces)),
           length > 0, length < maxSize {
            return (length, "pdf")
        }
        guard let eof = reader.find(Array("%%EOF".utf8), from: offset, limit: offset + maxSize) else { return nil }
        var end = eof + 5
        for byte in reader.bytes(at: end, count: 2) where byte == 0x0D || byte == 0x0A { end += 1 }
        return (end - offset, "pdf")
    }
}

// MARK: - ZIP y formatos basados en ZIP (docx, xlsx, pptx, odt, apk, jar...)

struct ZIPSignature: FileSignature {
    let name = "ZIP/Office"
    let extensions = ["zip", "docx", "xlsx", "pptx", "odt", "epub", "apk", "jar", "pages", "numbers", "key"]
    let firstBytes: Set<UInt8> = [0x50]
    let maxSize = 4096 * MB

    func matches(_ h: [UInt8]) -> Bool { h.starts(with: [0x50, 0x4B, 0x03, 0x04]) }

    func carve(at offset: Int64, reader: DiskReader) -> (length: Int64, ext: String)? {
        var from = offset + 30
        // Un ZIP puede contener otros ZIP sin comprimir: el EOCD correcto es el que apunta a un
        // directorio central que termina justo donde él empieza.
        while let eocd = reader.find([0x50, 0x4B, 0x05, 0x06], from: from, limit: offset + maxSize) {
            let e = reader.bytes(at: eocd, count: 22)
            guard e.count == 22 else { return nil }
            let cdSize = e.le32(12), cdOffset = e.le32(16)
            if cdOffset + cdSize == eocd - offset {
                let length = eocd + 22 + Int64(e.le16(20)) - offset
                return (length, kind(centralDirectory: reader.bytes(at: offset + cdOffset, count: Int(min(cdSize, MB)))))
            }
            from = eocd + 4
        }
        return nil
    }

    private func kind(centralDirectory cd: [UInt8]) -> String {
        let names = String(decoding: cd, as: UTF8.self)
        if names.contains("word/") { return "docx" }
        if names.contains("xl/") { return "xlsx" }
        if names.contains("ppt/") { return "pptx" }
        if names.contains("AndroidManifest.xml") { return "apk" }
        if names.contains("META-INF/container.xml") { return "epub" }
        if names.contains("META-INF/MANIFEST.MF") { return "jar" }
        if names.contains("Index/Document.iwa") { return "pages" }
        if names.contains("content.xml") && names.contains("mimetype") { return "odt" }
        return "zip"
    }
}

// MARK: - Office antiguo (doc, xls, ppt) y Outlook (msg): Compound File Binary

/// El tamaño sale de la tabla FAT interna: el último sector en uso marca el final.
struct OLESignature: FileSignature {
    let name = "Office 97-2003"
    let extensions = ["doc", "xls", "ppt", "msg"]
    let firstBytes: Set<UInt8> = [0xD0]

    func matches(_ h: [UInt8]) -> Bool { h.starts(with: [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) }

    func carve(at offset: Int64, reader: DiskReader) -> (length: Int64, ext: String)? {
        let h = reader.bytes(at: offset, count: 512)
        guard h.count == 512 else { return nil }
        let shift = h.le16(30)
        guard shift == 9 || shift == 12 else { return nil }
        let sector = Int64(1) << shift
        let perSector = Int(sector / 4)
        let numFAT = Int(h.le32(44))
        guard numFAT > 0, numFAT < 100_000 else { return nil }
        func sectorOffset(_ n: Int64) -> Int64 { offset + (n + 1) * sector }

        var fatSectors = (0..<min(109, numFAT)).map { h.le32(76 + $0 * 4) }
        var difat = h.le32(68)
        while fatSectors.count < numFAT, difat < 0xFFFF_FFFA {
            let d = reader.bytes(at: sectorOffset(difat), count: Int(sector))
            guard d.count == Int(sector) else { return nil }
            fatSectors += (0..<(perSector - 1)).map { d.le32($0 * 4) }
            difat = d.le32(Int(sector) - 4)
        }
        var fat: [Int64] = []
        for s in fatSectors.prefix(numFAT) {
            let d = reader.bytes(at: sectorOffset(s), count: Int(sector))
            guard d.count == Int(sector) else { return nil }
            fat += (0..<perSector).map { d.le32($0 * 4) }
        }
        guard let last = fat.lastIndex(where: { $0 != 0xFFFF_FFFF }) else { return nil }

        // Nombres de los flujos del directorio para saber qué tipo de documento es.
        var names = ""
        var dir = h.le32(48)
        for _ in 0..<8 where dir < fat.count {
            let d = reader.bytes(at: sectorOffset(dir), count: Int(sector))
            for e in stride(from: 0, to: d.count - 127, by: 128) {
                let len = min(64, d.le16(e + 64))
                names += String(decoding: stride(from: e, to: e + max(0, len - 2), by: 2).map { UInt16(d[$0]) | UInt16(d[$0 + 1]) << 8 }, as: UTF16.self) + "|"
            }
            dir = fat[Int(dir)]
        }
        let ext = names.contains("WordDocument") ? "doc" : names.contains("Workbook") || names.contains("Book|") ? "xls"
            : names.contains("PowerPoint Document") ? "ppt" : names.contains("__substg1.0_") ? "msg" : "doc"
        return (Int64(last + 2) * sector, ext)
    }
}

// MARK: - RTF

struct RTFSignature: FileSignature {
    let name = "RTF"
    let extensions = ["rtf"]
    let firstBytes: Set<UInt8> = [0x7B]
    var exactLength: Bool { false }

    func matches(_ h: [UInt8]) -> Bool { h.starts(with: "{\\rtf1") }

    func carve(at offset: Int64, reader: DiskReader) -> (length: Int64, ext: String)? {
        let estimate = Fallback.length(at: offset, reader: reader, max: 64 * MB)
        // Recortar al último "}" dentro del tramo estimado.
        let tail = reader.bytes(at: offset + max(0, estimate - 4096), count: Int(min(estimate, 4096)))
        guard let close = tail.lastIndex(of: 0x7D) else { return (estimate, "rtf") }
        return (max(0, estimate - 4096) + Int64(close) + 1, "rtf")
    }
}

// MARK: - 7z, RAR, GZip

struct SevenZipSignature: FileSignature {
    let name = "7-Zip"
    let extensions = ["7z"]
    let firstBytes: Set<UInt8> = [0x37]

    func matches(_ h: [UInt8]) -> Bool { h.starts(with: [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) }

    func carve(at offset: Int64, reader: DiskReader) -> (length: Int64, ext: String)? {
        let h = reader.bytes(at: offset, count: 32)
        guard h.count == 32 else { return nil }
        let length = 32 + h.le64(12) + h.le64(20)
        return length > 32 && length < 64 * 1024 * MB ? (length, "7z") : nil
    }
}

struct RARSignature: FileSignature {
    let name = "RAR"
    let extensions = ["rar"]
    let firstBytes: Set<UInt8> = [0x52]
    var exactLength: Bool { false }

    func matches(_ h: [UInt8]) -> Bool { h.starts(with: [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07]) }

    func carve(at offset: Int64, reader: DiskReader) -> (length: Int64, ext: String)? {
        (Fallback.length(at: offset, reader: reader, max: 2048 * MB), "rar")
    }
}

struct GZipSignature: FileSignature {
    let name = "GZip"
    let extensions = ["gz"]
    let firstBytes: Set<UInt8> = [0x1F]
    var exactLength: Bool { false }

    func matches(_ h: [UInt8]) -> Bool { h.starts(with: [0x1F, 0x8B, 0x08]) && h[3] & 0xE0 == 0 && h[9] <= 13 }

    func carve(at offset: Int64, reader: DiskReader) -> (length: Int64, ext: String)? {
        (Fallback.length(at: offset, reader: reader, max: 1024 * MB), "gz")
    }
}

// MARK: - ISO 9660 (imágenes de CD/DVD)

/// Los primeros 32 KB de una ISO son ceros; la firma está en el descriptor de volumen primario,
/// que también dice cuántos bloques ocupa la imagen.
struct ISOSignature: FileSignature {
    let name = "ISO"
    let extensions = ["iso"]
    let firstBytes: Set<UInt8> = [0x01]
    var headerOffset: Int64 { 0x8000 }

    func matches(_ h: [UInt8]) -> Bool { h.starts(with: [0x01, 0x43, 0x44, 0x30, 0x30, 0x31, 0x01]) }

    func carve(at offset: Int64, reader: DiskReader) -> (length: Int64, ext: String)? {
        let pvd = reader.bytes(at: offset + 0x8000, count: 136)
        guard pvd.count == 136 else { return nil }
        let blocks = pvd.le32(80), blockSize = Int64(pvd.le16(128))
        guard [512, 1024, 2048].contains(blockSize), blocks > 16 else { return nil }
        return (blocks * blockSize, "iso")
    }
}

// MARK: - SQLite (bases de datos de apps: mensajes, notas, historiales...)

struct SQLiteSignature: FileSignature {
    let name = "SQLite"
    let extensions = ["sqlite"]
    let firstBytes: Set<UInt8> = [0x53]

    func matches(_ h: [UInt8]) -> Bool { h.starts(with: "SQLite format 3\0") }

    func carve(at offset: Int64, reader: DiskReader) -> (length: Int64, ext: String)? {
        let h = reader.bytes(at: offset, count: 32)
        guard h.count == 32 else { return nil }
        let raw = h.be16(16)
        let pageSize = Int64(raw == 1 ? 65536 : raw)
        let pages = h.be32(28)
        guard pageSize >= 512, pageSize & (pageSize - 1) == 0, pages > 0 else { return nil }
        return (pageSize * pages, "sqlite")
    }
}
