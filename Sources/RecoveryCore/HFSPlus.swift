import Foundation

/// Un archivo encontrado en el catálogo de un volumen HFS+ (Mac OS Plus).
public struct HFSPlusFile: Sendable {
    public let id: UInt32
    public let name: String
    public let parentID: UInt32
    public var folder = ""
    public let size: Int64
    public var extents: [Extent]
    public let created: Date?
    public let modified: Date?
    /// Comprimido por el sistema (decmpfs): sus datos no están en el data fork.
    public let compressed: Bool
    /// Los tramos conocidos cubren todo el tamaño del archivo.
    public var complete: Bool
}

public struct HFSPlusCatalog: Sendable {
    public var volumeName = ""
    public var files: [HFSPlusFile] = []
    public var folderCount = 0
    public var leafNodes = 0
    public var damagedNodes = 0
    public var orphans = 0

    public var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }
}

/// Lector de SOLO LECTURA del catálogo de un volumen HFS+.
///
/// No recorre el árbol B desde la raíz (que es justo lo que está roto cuando macOS no monta el
/// disco): lee todos los nodos del archivo de catálogo uno por uno y aprovecha cada nodo hoja
/// que siga sano. Así recupera nombres, carpetas, fechas y la ubicación de los datos aunque
/// los nodos índice estén dañados.
public final class HFSPlusVolume {
    struct Fork {
        let logicalSize: Int64
        var extents: [(start: Int64, count: Int64)]
    }

    private let r: DiskReader
    private let base: Int64
    public let blockSize: Int64
    private let catalog: Fork
    private let overflow: Fork

    public init?(reader: DiskReader, partitionOffset: Int64) {
        r = reader
        base = partitionOffset
        let h = reader.bytes(at: partitionOffset + 1024, count: 512)
        guard h.count == 512, h.starts(with: "H+") || h.starts(with: "HX") else { return nil }
        blockSize = h.be32(40)
        guard blockSize >= 512, blockSize & (blockSize - 1) == 0 else { return nil }
        overflow = Self.fork(h, 192)
        catalog = Self.fork(h, 272)
        guard catalog.logicalSize > 0 else { return nil }
    }

    private static func fork(_ b: [UInt8], _ at: Int) -> Fork {
        Fork(logicalSize: b.be64(at), extents: (0..<8).map { (b.be32(at + 16 + $0 * 8), b.be32(at + 20 + $0 * 8)) }.filter { $0.1 > 0 })
    }

    /// Lee `count` bytes desde una posición lógica dentro de un fork, siguiendo sus tramos.
    private func read(_ fork: Fork, at logical: Int64, count: Int) -> [UInt8]? {
        var out = [UInt8]()
        var pos = logical
        let end = logical + Int64(count)
        while pos < end {
            var skipped: Int64 = 0
            var found = false
            for e in fork.extents {
                let length = e.count * blockSize
                if pos < skipped + length {
                    let inside = pos - skipped
                    let n = Int(min(end - pos, length - inside))
                    let chunk = r.bytes(at: base + e.start * blockSize + inside, count: n)
                    guard chunk.count == n else { return nil }
                    out += chunk
                    pos += Int64(n)
                    found = true
                    break
                }
                skipped += length
            }
            if !found { return nil }
        }
        return out
    }

    /// Tamaño de nodo del árbol B (está en el nodo cabecera; si está dañado se prueban los habituales).
    private func nodeSize(_ fork: Fork) -> Int {
        if let header = read(fork, at: 0, count: 64), header.count == 64, Int8(bitPattern: header[8]) == 1 {
            let size = header.be16(32)
            if [512, 1024, 2048, 4096, 8192, 16384, 32768].contains(size) { return size }
        }
        return 8192
    }

    /// Recorre todos los nodos hoja del fork y entrega cada registro como (clave, datos).
    private func scanLeaves(_ fork: Fork, isCancelled: () -> Bool, progress: (Double) -> Void,
                            stats: inout (leaves: Int, damaged: Int), visit: ([UInt8], Int, Int) -> Void) {
        let size = nodeSize(fork)
        let nodes = Int(fork.logicalSize / Int64(size))
        for n in 0..<nodes {
            if n % 512 == 0 {
                if isCancelled() { return }
                progress(Double(n) / Double(max(1, nodes)))
            }
            guard let node = read(fork, at: Int64(n) * Int64(size), count: size), node.count == size else {
                stats.damaged += 1
                continue
            }
            guard Int8(bitPattern: node[8]) == -1 else { continue } // solo nodos hoja
            let records = node.be16(10)
            guard records > 0, records < size / 8 else { stats.damaged += 1; continue }
            stats.leaves += 1
            var lastOffset = 13
            for k in 0..<records {
                let offset = node.be16(size - 2 * (k + 1))
                guard offset > lastOffset, offset < size - 2 * (records + 1) else { stats.damaged += 1; break }
                lastOffset = offset
                visit(node, offset, size)
            }
        }
        progress(1)
    }

    /// Lee el catálogo completo. `progress` va de 0 a 1.
    public func readCatalog(isCancelled: () -> Bool = { false }, progress: (Double) -> Void = { _ in }) -> HFSPlusCatalog {
        var result = HFSPlusCatalog()
        var stats = (leaves: 0, damaged: 0)

        // 1) Tramos extra de archivos muy fragmentados (archivo de desbordamiento de extents).
        var extra: [UInt32: [(Int64, [(Int64, Int64)])]] = [:]
        if overflow.logicalSize > 0 {
            var s = (leaves: 0, damaged: 0)
            scanLeaves(overflow, isCancelled: isCancelled, progress: { _ in }, stats: &s) { node, at, size in
                guard at + 12 + 64 <= size, node.be16(at) == 10, node[at + 2] == 0 else { return } // fork de datos
                let fileID = UInt32(node.be32(at + 4)), startBlock = node.be32(at + 8)
                let list = (0..<8).map { (node.be32(at + 12 + $0 * 8), node.be32(at + 16 + $0 * 8)) }.filter { $0.1 > 0 }
                extra[fileID, default: []].append((startBlock, list))
            }
        }

        // 2) Catálogo: carpetas y archivos.
        var folders: [UInt32: (parent: UInt32, name: String)] = [:]
        var files: [UInt32: HFSPlusFile] = [:]
        var hardLinks: [(file: HFSPlusFile, inode: UInt32)] = []
        var inodes: [UInt32: HFSPlusFile] = [:]

        scanLeaves(catalog, isCancelled: isCancelled, progress: progress, stats: &stats) { node, at, size in
            let keyLength = node.be16(at)
            guard keyLength >= 6, keyLength <= 516, at + 2 + keyLength + 2 <= size else { return }
            let parent = UInt32(node.be32(at + 2))
            let nameLength = node.be16(at + 6)
            guard 6 + nameLength * 2 <= keyLength else { return }
            let units = (0..<nameLength).map { UInt16(node[at + 8 + $0 * 2]) << 8 | UInt16(node[at + 9 + $0 * 2]) }
            // HFS+ guarda los nombres descompuestos (NFD) y usa ":" donde POSIX usa "/".
            let name = String(decoding: units, as: UTF16.self).precomposedStringWithCanonicalMapping
                .replacingOccurrences(of: "/", with: ":")
            var data = at + 2 + keyLength
            if data % 2 == 1 { data += 1 }
            guard data + 2 <= size else { return }

            switch node.be16(data) {
            case 1 where data + 88 <= size: // carpeta
                folders[UInt32(node.be32(data + 8))] = (parent, name)
            case 3 where data + 10 <= size: // hilo de carpeta: sirve si se perdió el registro de la carpeta
                let id = parent
                if folders[id] == nil {
                    let n = node.be16(data + 8)
                    guard data + 10 + n * 2 <= size else { return }
                    let u = (0..<n).map { UInt16(node[data + 10 + $0 * 2]) << 8 | UInt16(node[data + 11 + $0 * 2]) }
                    folders[id] = (UInt32(node.be32(data + 4)), String(decoding: u, as: UTF16.self).precomposedStringWithCanonicalMapping)
                }
            case 2 where data + 248 <= size: // archivo
                let id = UInt32(node.be32(data + 8))
                let ownerFlags = node[data + 41]
                let type = node.ascii((data + 48)..<(data + 52)), creator = node.ascii((data + 52)..<(data + 56))
                let logical = node.be64(data + 88)
                var list = (0..<8).map { (node.be32(data + 104 + $0 * 8), node.be32(data + 108 + $0 * 8)) }.filter { $0.1 > 0 }
                if let more = extra[id] { list += more.sorted { $0.0 < $1.0 }.flatMap(\.1) }
                let file = HFSPlusFile(id: id, name: name, parentID: parent, size: logical,
                                       extents: extents(list, size: logical),
                                       created: date(node.be32(data + 12)), modified: date(node.be32(data + 16)),
                                       compressed: ownerFlags & 0x20 != 0,
                                       complete: list.reduce(0) { $0 + $1.1 } * blockSize >= logical)
                if type == "hlnk" && creator == "hfs+" {
                    hardLinks.append((file, UInt32(node.be32(data + 44))))
                } else if name.hasPrefix("iNode"), let n = UInt32(name.dropFirst(5)) {
                    inodes[n] = file
                } else if let existing = files[id], (existing.modified ?? .distantPast) >= (file.modified ?? .distantPast) {
                    return // nodo viejo con una versión anterior del mismo archivo
                } else {
                    files[id] = file
                }
            default:
                break
            }
        }

        // 3) Enlaces duros (los usa Time Machine, por ejemplo): apuntan a un "iNode" oculto.
        for (link, inode) in hardLinks {
            guard let target = inodes[inode] else { continue }
            files[link.id] = HFSPlusFile(id: link.id, name: link.name, parentID: link.parentID, size: target.size,
                                         extents: target.extents, created: target.created, modified: target.modified,
                                         compressed: target.compressed, complete: target.complete)
        }

        // 4) Rutas completas de carpeta.
        result.volumeName = folders[2]?.name ?? "Volumen"
        var cache: [UInt32: String] = [1: "", 2: ""]
        func path(_ id: UInt32, depth: Int = 0) -> String? {
            if let p = cache[id] { return p }
            guard depth < 256, let f = folders[id], let parent = path(f.parent, depth: depth + 1) else { return nil }
            let p = parent + "/" + f.name
            cache[id] = p
            return p
        }
        let hidden: Set<String> = [".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100", ".TemporaryItems",
                                   "\u{0}\u{0}\u{0}\u{0}HFS+ Private Data", ".HFS+ Private Directory Data\r", ".journal", ".journal_info_block"]
        for var file in files.values {
            if let p = path(file.parentID) {
                if p.split(separator: "/").contains(where: { hidden.contains(String($0)) }) { continue }
                file.folder = p.isEmpty ? "/" : p
            } else {
                result.orphans += 1
                file.folder = "/_Sin carpeta (carpeta \(file.parentID))"
            }
            if hidden.contains(file.name) { continue }
            result.files.append(file)
        }
        result.folderCount = folders.count
        result.leafNodes = stats.leaves
        result.damagedNodes = stats.damaged
        return result
    }

    private func extents(_ list: [(Int64, Int64)], size: Int64) -> [Extent] {
        var out: [Extent] = []
        var remaining = size
        for (start, count) in list where remaining > 0 {
            let n = min(count * blockSize, remaining)
            out.append(Extent(offset: base + start * blockSize, length: n))
            remaining -= n
        }
        return out
    }

    private func date(_ hfs: Int64) -> Date? {
        hfs == 0 ? nil : Date(timeIntervalSince1970: Double(hfs) - 2_082_844_800) // segundos desde 1904
    }
}

/// Copia de respaldo de un volumen HFS+ dañado: escribe cada archivo con su carpeta, nombre y
/// fechas originales. Nunca escribe en el disco de origen. Si se interrumpe, al reanudar se
/// saltan los archivos que ya están copiados con el tamaño correcto.
public enum HFSPlusBackup {
    public struct Progress: Sendable {
        public let done: Int
        public let total: Int
        public let bytes: Int64
        public let totalBytes: Int64
        public let current: String
        public let failed: Int
    }

    public static func copy(_ catalog: HFSPlusCatalog, from reader: DiskReader, to root: URL,
                            isCancelled: () -> Bool = { false }, progress: (Progress) -> Void) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let logURL = root.appendingPathComponent("_reporte_respaldo.csv")
        fm.createFile(atPath: logURL.path, contents: Data("estado,ruta,bytes,detalle\n".utf8))
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        func note(_ state: String, _ path: String, _ size: Int64, _ detail: String) {
            let safe = path.replacingOccurrences(of: "\"", with: "\"\"")
            try? log.write(contentsOf: Data("\(state),\"\(safe)\",\(size),\(detail)\n".utf8))
        }

        // En orden físico: en un disco mecánico evita saltos del cabezal y copia mucho más rápido.
        let files = catalog.files.sorted { ($0.extents.first?.offset ?? .max) < ($1.extents.first?.offset ?? .max) }
        let totalBytes = catalog.totalSize
        var bytes: Int64 = 0, failed = 0
        var last = Date.distantPast

        for (i, file) in files.enumerated() {
            if isCancelled() { break }
            let folder = root.appendingPathComponent(String(file.folder.drop { $0 == "/" }), isDirectory: true)
            let url = folder.appendingPathComponent(file.name.isEmpty ? "sin_nombre_\(file.id)" : file.name)
            let relative = file.folder + "/" + file.name
            defer {
                bytes += file.size
                if Date().timeIntervalSince(last) > 0.3 || i == files.count - 1 {
                    last = Date()
                    progress(Progress(done: i + 1, total: files.count, bytes: bytes, totalBytes: totalBytes,
                                      current: relative, failed: failed))
                }
            }
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int64, size == file.size {
                continue // ya copiado en una ejecución anterior
            }
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                if file.compressed && file.size == 0 {
                    note("omitido", relative, 0, "comprimido por el sistema (decmpfs)")
                    continue
                }
                try Extractor.write(FoundFile(ext: "", extents: file.extents, origin: .fileSystem("HFS+")), from: reader, to: url)
                var attrs: [FileAttributeKey: Any] = [:]
                if let m = file.modified { attrs[.modificationDate] = m }
                if let c = file.created { attrs[.creationDate] = c }
                try? fm.setAttributes(attrs, ofItemAtPath: url.path)
                if !file.complete { note("incompleto", relative, file.size, "faltan tramos del archivo en el índice") }
            } catch {
                failed += 1
                note("error", relative, file.size, error.localizedDescription.replacingOccurrences(of: ",", with: ";"))
            }
        }
    }
}
