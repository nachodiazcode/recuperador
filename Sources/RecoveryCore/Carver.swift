import Foundation

public struct CarveProgress: Sendable {
    public let scanned: Int64
    public let total: Int64
    public let found: Int
    public let elapsed: TimeInterval

    public var fraction: Double { total > 0 ? Double(scanned) / Double(total) : 1 }
    public var bytesPerSecond: Double { Double(scanned) / max(0.001, elapsed) }
}

public struct CarveOptions {
    public var signatures: [FileSignature] = Signatures.all
    /// Los sistemas de archivos colocan los archivos al inicio de un sector/bloque, así que basta
    /// revisar cada `alignment` bytes. Es mucho más rápido y da menos falsos positivos.
    public var alignment: Int = 512
    public var minSize: Int64 = 128
    public var start: Int64 = 0
    public var end: Int64?
    /// Rangos ocupados por archivos que existen: no hay nada borrado ahí, así que se saltan.
    public var skip: [Range<Int64>] = []
    /// Si es verdadero, al encontrar un archivo de longitud exacta se salta su interior.
    /// Así una foto metida en un Word no aparece como un segundo archivo. Con falso, esos
    /// archivos se recuperan igual y quedan marcados como embebidos.
    public var skipInteriors = true

    public init() {}
}

/// "File carving": recorre el disco entero buscando firmas de archivos, ignorando el sistema de
/// archivos. Funciona aunque el archivo esté borrado o el disco formateado, mientras los sectores
/// no se hayan sobrescrito (ni borrado vía TRIM en un SSD) y el archivo no esté fragmentado.
public final class Carver {
    /// Páginas que se piden por adelantado (8 MB con páginas de 1 MB).
    static let readAhead: Int64 = 8

    private let reader: DiskReader
    private let options: CarveOptions

    public init(reader: DiskReader, options: CarveOptions = CarveOptions()) {
        self.reader = reader
        self.options = options
    }

    @discardableResult
    public func run(isCancelled: () -> Bool = { false },
                    progress: ((CarveProgress) -> Void)? = nil,
                    onFound: (FoundFile) -> Void = { _ in }) -> [FoundFile] {
        var candidates = [[FileSignature]](repeating: [], count: 256)
        for sig in options.signatures {
            for b in sig.firstBytes { candidates[Int(b)].append(sig) }
        }
        let skip = options.skip.sorted { $0.lowerBound < $1.lowerBound }
        var skipIndex = 0

        let align = Int64(max(1, options.alignment))
        func alignUp(_ v: Int64) -> Int64 { (v + align - 1) / align * align }
        let end = min(options.end ?? reader.size, reader.size)
        var offset = alignUp(options.start)
        let began = Date()
        var lastReport = Date.distantPast
        var found: [FoundFile] = []
        // Archivos de longitud exacta que todavía cubren la posición actual. Sirve para marcar
        // lo que está dentro de otro cuando no se salta el interior.
        var active: [(range: Range<Int64>, ext: String)] = []

        while offset < end, !isCancelled() {
            while skipIndex < skip.count, skip[skipIndex].upperBound <= offset { skipIndex += 1 }
            if skipIndex < skip.count, skip[skipIndex].lowerBound <= offset {
                offset = alignUp(skip[skipIndex].upperBound)
                continue
            }
            let nextSkip = skipIndex < skip.count ? skip[skipIndex].lowerBound : Int64.max

            let index = offset / Int64(reader.pageSize)
            let pageStart = index * Int64(reader.pageSize)
            // Que el disco vaya leyendo lo que sigue mientras se analiza esta página.
            let lastNeeded = (min(end, nextSkip) - 1) / Int64(reader.pageSize)
            reader.prefetch((index + 1)..<min(index + 1 + Self.readAhead, lastNeeded + 1))
            let page = reader.page(index)
            if page.isEmpty { break }
            var local = Int(offset - pageStart)
            let limit = Int(min(Int64(page.count), end - pageStart, nextSkip - pageStart))
            var pageJump: Int64?

            while local < limit {
                let sigs = candidates[Int(page[local])]
                var jumpedInside = false
                if !sigs.isEmpty, !Self.isBlank(page, at: local) {
                    let absolute = pageStart + Int64(local)
                    let header = local + 32 <= page.count
                        ? Array(page[local..<(local + 32)])
                        : reader.bytes(at: absolute, count: 32)
                    for sig in sigs where sig.matches(header) {
                        let start = absolute - sig.headerOffset
                        guard start >= 0, let (length, ext) = sig.carve(at: start, reader: reader),
                              length >= options.minSize, start + length <= reader.size else { continue }
                        active.removeAll { $0.range.upperBound <= start }
                        let parent = active.first { $0.range.lowerBound < start && start < $0.range.upperBound }
                        let file = FoundFile(ext: ext, extents: [Extent(offset: start, length: length)],
                                             origin: .carved(exactLength: sig.exactLength),
                                             embedded: parent != nil)
                        found.append(file)
                        onFound(file)
                        if sig.exactLength && parent == nil {
                            let covered = start..<(start + length)
                            active.append((covered, ext))
                            if options.skipInteriors {
                                let jump = alignUp(start + length)
                                let jumpLocal = Int(jump - pageStart)
                                if jumpLocal >= limit {
                                    pageJump = jump
                                } else if jumpLocal > local {
                                    local = jumpLocal
                                    jumpedInside = true
                                }
                            }
                        }
                        break
                    }
                }
                if pageJump != nil { break }
                if !jumpedInside { local += Int(align) }
            }
            offset = pageJump ?? alignUp(pageStart + Int64(limit))

            if let progress, Date().timeIntervalSince(lastReport) > 0.25 {
                lastReport = Date()
                progress(CarveProgress(scanned: min(offset, end) - options.start, total: end - options.start,
                                       found: found.count, elapsed: Date().timeIntervalSince(began)))
            }
        }
        progress?(CarveProgress(scanned: min(offset, end) - options.start, total: end - options.start,
                                found: found.count, elapsed: Date().timeIntervalSince(began)))
        return found
    }

    /// ¿Son cero los primeros 16 bytes? Ninguna firma empieza así, y es lo más común en el
    /// espacio libre, así que se descarta sin mirar las firmas.
    static func isBlank(_ page: [UInt8], at i: Int) -> Bool {
        guard i + 16 <= page.count else { return false }
        return page.withUnsafeBytes { raw in
            raw.loadUnaligned(fromByteOffset: i, as: UInt64.self) == 0
                && raw.loadUnaligned(fromByteOffset: i + 8, as: UInt64.self) == 0
        }
    }
}
