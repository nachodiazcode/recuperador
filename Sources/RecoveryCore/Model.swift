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

public enum Extractor {
    /// Escribe el contenido de `file` en `url` leyendo sus tramos del disco.
    public static func write(_ file: FoundFile, from reader: DiskReader, to url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        for extent in file.extents {
            try reader.copy(from: extent.offset, length: extent.length, to: handle)
        }
    }
}
