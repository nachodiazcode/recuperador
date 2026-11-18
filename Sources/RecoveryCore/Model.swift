import Darwin
import Foundation

/// Un tramo contiguo de bytes en el disco.
public struct Extent: Hashable, Sendable {
    public let offset: Int64
    public let length: Int64
    public init(offset: Int64, length: Int64) {
        self.offset = offset
        self.length = length
    }
}

public enum FileCategory: String, CaseIterable, Sendable {
    case photo = "Fotos"
    case video = "Videos"
    case audio = "Música"
    case document = "Documentos"
    case archive = "Comprimidos"
    case other = "Otros"

    public init(extension ext: String) {
        switch ext.lowercased() {
        case "jpg", "jpeg", "png", "gif", "bmp", "heic", "avif", "webp", "tif", "tiff", "cr2", "cr3",
             "nef", "arw", "dng", "orf", "pef", "psd":
            self = .photo
        case "mp4", "mov", "avi", "mkv", "webm", "wmv", "flv", "mts", "m2ts", "ts", "3gp", "mpg", "ogv", "m4v":
            self = .video
        case "mp3", "wav", "m4a", "flac", "ogg", "opus", "wma", "mid", "aif", "aiff":
            self = .audio
        case "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "rtf", "epub", "msg", "txt", "pages",
             "numbers", "key":
            self = .document
        case "zip", "rar", "7z", "gz", "apk", "jar", "iso", "dmg", "img":
            self = .archive
        default:
            self = .other
        }
    }
}

/// Un archivo encontrado, ya sea por su entrada en el sistema de archivos o por carving.
public struct FoundFile: Hashable, Sendable {
    public enum Origin: Hashable, Sendable {
        /// Entrada borrada del sistema de archivos (FAT, exFAT, NTFS...): tiene nombre original.
        case fileSystem(String)
        /// Encontrado por firma. `exactLength` es falso cuando el tamaño es estimado.
        case carved(exactLength: Bool)
    }

    public var name: String?
    public var folder: String?
    public var ext: String
    public var extents: [Extent]
    public var modified: Date?
    public var origin: Origin
    /// El sistema de archivos ya reasignó esos sectores a otro archivo.
    public var likelyOverwritten = false
    /// La firma estaba dentro de otro archivo ya recuperado (una foto dentro de un Word, por ejemplo).
    public var embedded = false

    public var offset: Int64 { extents.first?.offset ?? 0 }
    public var size: Int64 { extents.reduce(0) { $0 + $1.length } }
    public var category: FileCategory { FileCategory(extension: ext) }

    public init(name: String? = nil, folder: String? = nil, ext: String, extents: [Extent],
                modified: Date? = nil, origin: Origin, likelyOverwritten: Bool = false, embedded: Bool = false) {
        self.name = name
        self.folder = folder
        self.ext = ext
        self.extents = extents
        self.modified = modified
        self.origin = origin
        self.likelyOverwritten = likelyOverwritten
        self.embedded = embedded
    }
}

public enum ExtractError: Error { case create(String, Int32), write(String, Int32) }

public enum Extractor {
    /// Escribe el contenido de `file` en `url` leyendo sus tramos del disco. `progress` recibe
    /// los bytes escritos hasta el momento.
    public static func write(_ file: FoundFile, from reader: DiskReader, to url: URL,
                             progress: ((Int64) -> Void)? = nil) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw ExtractError.create(url.path, errno) }
        defer { close(fd) }
        var done: Int64 = 0
        for extent in file.extents {
            var pos = extent.offset
            let end = min(reader.size, extent.offset + extent.length)
            while pos < end {
                let chunk = reader.read(at: pos, count: Int(min(Int64(DiskReader.transferChunk), end - pos)))
                guard !chunk.isEmpty else { break }
                var written = 0
                while written < chunk.count {
                    let n = chunk.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + written, chunk.count - written) }
                    if n < 0 {
                        if errno == EINTR { continue }
                        throw ExtractError.write(url.path, errno)
                    }
                    written += n
                }
                pos += Int64(chunk.count)
                done += Int64(chunk.count)
                progress?(done)
            }
        }
    }

    /// Lee `count` bytes del archivo a partir de su posición lógica `offset`, cruzando tramos si
    /// está fragmentado. Sirve para leer un archivo del disco sin escribirlo antes en ninguna parte.
    public static func read(_ file: FoundFile, from reader: DiskReader, at offset: Int64, count: Int) -> [UInt8] {
        var out = [UInt8]()
        var skip = max(0, offset)
        var left = count
        for extent in file.extents where left > 0 {
            if skip >= extent.length { skip -= extent.length; continue }
            let n = Int(min(Int64(left), extent.length - skip))
            let part = reader.read(at: extent.offset + skip, count: n)
            if out.isEmpty { out = part } else { out.append(contentsOf: part) }
            guard part.count == n else { break }
            left -= n
            skip = 0
        }
        return out
    }

    /// El archivo entero en memoria; nil si pesa más que `limit`.
    public static func data(_ file: FoundFile, from reader: DiskReader, limit: Int64) -> Data? {
        let size = file.size
        guard size > 0, size <= limit else { return nil }
        if file.extents.count == 1, let data = reader.data(at: file.offset, count: Int(size)) { return data }
        let bytes = read(file, from: reader, at: 0, count: Int(size))
        return bytes.isEmpty ? nil : Data(bytes)
    }
}
