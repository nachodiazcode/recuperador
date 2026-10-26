import Foundation

public struct Partition: Sendable {
    public let offset: Int64
    public let length: Int64
    public let name: String
}

public struct VolumeInfo: Sendable {
    public let name: String
    public let format: String
    public let offset: Int64
    public let length: Int64
    /// Falso si no sabemos leer sus nombres (NTFS, APFS, HFS+...): solo sirve el escaneo profundo.
    public let namesSupported: Bool
}

// MARK: - Tablas de particiones

public enum PartitionTable {
    public static func read(_ r: DiskReader) -> [Partition] {
        let whole = [Partition(offset: 0, length: r.size, name: "Disco completo")]
        let mbr = r.bytes(at: 0, count: 512)
        guard mbr.count == 512, mbr[510] == 0x55, mbr[511] == 0xAA else { return whole }
        if FileSystemScanner.format(of: mbr) != nil { return whole } // volumen sin tabla de particiones

        let entries = (0..<4).map { i -> (type: UInt8, lba: Int64, count: Int64) in
            let e = 446 + i * 16
            return (mbr[e + 4], mbr.le32(e + 8), mbr.le32(e + 12))
        }
        if entries.contains(where: { $0.type == 0xEE }) {
            for sector in [Int64(r.sectorSize), 512, 4096] {
                let gpt = readGPT(r, sectorSize: sector)
                if !gpt.isEmpty { return gpt }
            }
            return whole
        }
        let parts = entries.filter { $0.type != 0 && ![0x05, 0x0F].contains($0.type) && $0.count > 0 }
            .enumerated().map { Partition(offset: $1.lba * 512, length: $1.count * 512, name: "Partición \($0 + 1)") }
        return parts.isEmpty ? whole : parts
    }

    private static func readGPT(_ r: DiskReader, sectorSize: Int64) -> [Partition] {
        let h = r.bytes(at: sectorSize, count: 92)
        guard h.count == 92, h.starts(with: "EFI PART") else { return [] }
        let entriesLBA = h.le64(72), count = Int(min(h.le32(80), 256)), entrySize = Int(h.le32(84))
        guard entrySize >= 128 else { return [] }
        let table = r.bytes(at: entriesLBA * sectorSize, count: count * entrySize)
        var parts: [Partition] = []
        for i in 0..<count where (i + 1) * entrySize <= table.count {
            let e = i * entrySize
            guard table[e..<(e + 16)].contains(where: { $0 != 0 }) else { continue }
            let first = table.le64(e + 32), last = table.le64(e + 40)
            let units = stride(from: e + 56, to: e + 128, by: 2).map { UInt16(table[$0]) | UInt16(table[$0 + 1]) << 8 }
            let name = String(decoding: units.prefix { $0 != 0 }, as: UTF16.self)
            parts.append(Partition(offset: first * sectorSize, length: (last - first + 1) * sectorSize,
                                   name: name.isEmpty ? "Partición \(i + 1)" : name))
        }
        return parts
    }
}

// MARK: - Escáner de sistemas de archivos

/// Lee las entradas de directorio BORRADAS, que conservan nombre, tamaño, fecha y primer
/// cluster. Es casi instantáneo comparado con el carving y devuelve nombres originales.
public enum FileSystemScanner {
    static func format(of boot: [UInt8]) -> String? {
        guard boot.count >= 512 else { return nil }
        if boot.starts(with: "EXFAT   ", at: 3) { return "exFAT" }
        if boot.starts(with: "NTFS    ", at: 3) { return "NTFS" }
        if boot.starts(with: "FAT32   ", at: 82) { return "FAT32" }
        if boot.starts(with: "FAT16   ", at: 54) || boot.starts(with: "FAT12   ", at: 54) { return "FAT16" }
        return nil
    }

    /// Nombre del sistema de archivos (o del cifrado) de una partición.
    public static func identify(_ reader: DiskReader, _ part: Partition) -> String {
        let boot = reader.bytes(at: part.offset, count: 512)
        if boot.starts(with: "-FVE-FS-", at: 3) { return "BitLocker (cifrado)" }
        if let f = format(of: boot) { return f }
        if reader.bytes(at: part.offset + 32, count: 4).starts(with: "NXSB") { return "APFS" }
        let hfs = reader.bytes(at: part.offset + 1024, count: 2)
        if hfs.starts(with: "H+") || hfs.starts(with: "HX") { return "HFS+" }
        if reader.bytes(at: part.offset + 1080, count: 2) == [0x53, 0xEF] { return "ext4 (Linux)" }
        if boot.starts(with: "LUKS") { return "LUKS (cifrado)" }
        if boot.allSatisfy({ $0 == 0 }) { return "Vacío (ceros)" }
        return "Desconocido"
    }

    /// Escanea todas las particiones. Devuelve los rangos ocupados por archivos existentes, que el
    /// escaneo profundo puede saltarse.
    @discardableResult
    public static func scan(_ reader: DiskReader,
                            isCancelled: () -> Bool = { false },
                            onVolume: (VolumeInfo) -> Void = { _ in },
                            onFound: (FoundFile) -> Void) -> [Range<Int64>] {
        var allocated: [Range<Int64>] = []
        for part in PartitionTable.read(reader) where !isCancelled() {
            let boot = reader.bytes(at: part.offset, count: 512)
            let label = part.name
            switch format(of: boot) {
            case "FAT32", "FAT16":
                guard let v = FATVolume(reader: reader, base: part.offset, boot: boot) else { continue }
                onVolume(VolumeInfo(name: v.label ?? label, format: v.isFAT32 ? "FAT32" : "FAT16",
                                    offset: part.offset, length: part.length, namesSupported: true))
                v.scan(isCancelled: isCancelled, onFound: onFound)
                allocated += v.allocatedRanges()
            case "exFAT":
                guard let v = ExFATVolume(reader: reader, base: part.offset, boot: boot) else { continue }
                onVolume(VolumeInfo(name: v.label ?? label, format: "exFAT",
                                    offset: part.offset, length: part.length, namesSupported: true))
                v.scan(isCancelled: isCancelled, onFound: onFound)
                allocated += v.allocatedRanges()
            case "NTFS":
                if let v = NTFSVolume(reader: reader, base: part.offset, boot: boot) {
                    onVolume(VolumeInfo(name: v.label ?? label, format: "NTFS",
                                        offset: part.offset, length: part.length, namesSupported: true))
                    v.scan(isCancelled: isCancelled, onFound: onFound)
                    allocated += v.allocatedRanges()
                } else {
                    onVolume(VolumeInfo(name: label, format: "NTFS", offset: part.offset,
                                        length: part.length, namesSupported: false))
                }
            default:
                onVolume(VolumeInfo(name: label, format: identify(reader, part), offset: part.offset,
                                    length: part.length, namesSupported: false))
            }
        }
        return allocated
    }

    static func dosDate(date d: Int, time t: Int) -> Date? {
        guard d != 0 else { return nil }
        var c = DateComponents()
        c.year = 1980 + (d >> 9)
        c.month = (d >> 5) & 15
        c.day = d & 31
        c.hour = t >> 11
        c.minute = (t >> 5) & 63
        c.second = (t & 31) * 2
        guard (1...12).contains(c.month!), (1...31).contains(c.day!) else { return nil }
        return Calendar.current.date(from: c)
    }

    static func splitName(_ name: String) -> (String, String) {
        let ext = (name as NSString).pathExtension.lowercased()
        return (name, ext.isEmpty ? "bin" : ext)
    }

    /// Une celdas de un mapa de ocupación en rangos de bytes contiguos.
    static func ranges(clusterCount: Int, clusterSize: Int64, heap: Int64,
                       isAllocated: (Int) -> Bool) -> [Range<Int64>] {
        var out: [Range<Int64>] = []
        var runStart: Int?
        for i in 0...clusterCount {
            let used = i < clusterCount && isAllocated(i)
            if used, runStart == nil { runStart = i }
            if !used, let s = runStart {
                out.append((heap + Int64(s) * clusterSize)..<(heap + Int64(i) * clusterSize))
                runStart = nil
            }
        }
        return out
    }
}

// MARK: - FAT16 / FAT32

final class FATVolume {
    let r: DiskReader
    let base: Int64
    let isFAT32: Bool
    let clusterSize: Int64
    let fatOffset: Int64
    let dataStart: Int64
    let clusterCount: Int
    let rootCluster: Int64
    let rootDir: Range<Int64>?
    let label: String?
    private var visited = Set<Int64>()

    init?(reader: DiskReader, base: Int64, boot b: [UInt8]) {
        r = reader
        self.base = base
        let bps = Int64(b.le16(11)), spc = Int64(b[13]), reserved = Int64(b.le16(14)), fats = Int64(b[16])
        guard [512, 1024, 2048, 4096].contains(bps), spc > 0, fats > 0 else { return nil }
        isFAT32 = b.le16(22) == 0
        let fatSize = isFAT32 ? b.le32(36) : Int64(b.le16(22))
        let totalSectors = b.le16(19) != 0 ? Int64(b.le16(19)) : b.le32(32)
        let rootEntries = Int64(b.le16(17))
        clusterSize = bps * spc
        fatOffset = base + reserved * bps
        let rootStart = fatOffset + fats * fatSize * bps
        if isFAT32 {
            rootDir = nil
            dataStart = rootStart
            rootCluster = b.le32(44)
        } else {
            rootDir = rootStart..<(rootStart + rootEntries * 32)
            dataStart = rootStart + (rootEntries * 32 + bps - 1) / bps * bps
            rootCluster = 0
        }
        clusterCount = Int(max(0, (base + totalSectors * bps - dataStart) / clusterSize))
        let raw = (isFAT32 ? b.ascii(71..<82) : b.ascii(43..<54)).trimmingCharacters(in: .whitespaces)
        label = raw.isEmpty || raw == "NO NAME" ? nil : raw
    }

    func clusterOffset(_ c: Int64) -> Int64 { dataStart + (c - 2) * clusterSize }
    func validCluster(_ c: Int64) -> Bool { c >= 2 && c < Int64(clusterCount) + 2 }

    func fatEntry(_ c: Int64) -> Int64 {
        if isFAT32 {
            let b = r.bytes(at: fatOffset + c * 4, count: 4)
            return b.count == 4 ? b.le32(0) & 0x0FFF_FFFF : 0
        }
        let b = r.bytes(at: fatOffset + c * 2, count: 2)
        return b.count == 2 ? Int64(b.le16(0)) : 0
    }

    func chain(_ start: Int64) -> [Int64] {
        var out: [Int64] = []
        var c = start
        let end: Int64 = isFAT32 ? 0x0FFF_FFF8 : 0xFFF8
        while validCluster(c), out.count < 1_000_000 {
            out.append(c)
            let next = fatEntry(c)
            if next >= end || next < 2 || next == c { break }
            c = next
        }
        return out
    }

    func scan(isCancelled: () -> Bool, onFound: (FoundFile) -> Void) {
        let root: [UInt8]
        if let rootDir {
            root = r.bytes(at: rootDir.lowerBound, count: rootDir.count)
        } else {
            root = chain(rootCluster).flatMap { r.bytes(at: clusterOffset($0), count: Int(clusterSize)) }
        }
        walk(root, path: "", depth: 0, isCancelled: isCancelled, onFound: onFound)
    }

    private func walk(_ dir: [UInt8], path: String, depth: Int, isCancelled: () -> Bool, onFound: (FoundFile) -> Void) {
        guard depth < 32, !isCancelled() else { return }
        var lfn: [String] = []
        for e in stride(from: 0, to: dir.count - 31, by: 32) {
            let first = dir[e], attr = dir[e + 11]
            if first == 0x00 { break }
            if attr == 0x0F {
                let units = (Array(stride(from: e + 1, to: e + 11, by: 2)) + Array(stride(from: e + 14, to: e + 26, by: 2))
                    + Array(stride(from: e + 28, to: e + 32, by: 2))).map { UInt16(dir[$0]) | UInt16(dir[$0 + 1]) << 8 }
                lfn.append(String(decoding: units.prefix { $0 != 0 && $0 != 0xFFFF }, as: UTF16.self))
                continue
            }
            defer { lfn = [] }
            if attr & 0x08 != 0 { continue }
            let deleted = first == 0xE5
            var name = lfn.reversed().joined()
            if name.isEmpty { name = shortName(dir, e, deleted: deleted) }
            if name == "." || name == ".." || name.isEmpty { continue }

            let cluster = (isFAT32 ? Int64(dir.le16(e + 20)) << 16 : 0) | Int64(dir.le16(e + 26))
            if attr & 0x10 != 0 {
                guard validCluster(cluster), visited.insert(cluster).inserted else { continue }
                // Al borrar una carpeta su cadena FAT queda en cero: se lee al menos su primer cluster.
                let clusters = deleted ? [cluster] : chain(cluster)
                let sub = clusters.flatMap { r.bytes(at: clusterOffset($0), count: Int(clusterSize)) }
                walk(sub, path: path + "/" + name, depth: depth + 1, isCancelled: isCancelled, onFound: onFound)
                continue
            }
            let size = dir.le32(e + 28)
            guard deleted, size > 0, validCluster(cluster) else { continue }
            // FAT pone en cero la cadena del archivo borrado: se asume contiguo, que es lo habitual.
            let (fullName, ext) = FileSystemScanner.splitName(name)
            onFound(FoundFile(name: fullName, folder: path.isEmpty ? "/" : path, ext: ext,
                              extents: [Extent(offset: clusterOffset(cluster), length: size)],
                              modified: FileSystemScanner.dosDate(date: dir.le16(e + 24), time: dir.le16(e + 22)),
                              origin: .fileSystem(isFAT32 ? "FAT32" : "FAT16"),
                              likelyOverwritten: fatEntry(cluster) != 0))
        }
    }

    private func shortName(_ d: [UInt8], _ e: Int, deleted: Bool) -> String {
        // Windows guarda en el byte 12 si el nombre o la extensión iban en minúsculas.
        var base = d.ascii(e..<(e + 8)).trimmingCharacters(in: .whitespaces)
        var ext = d.ascii((e + 8)..<(e + 11)).trimmingCharacters(in: .whitespaces)
        if d[e + 12] & 0x08 != 0 { base = base.lowercased() }
        if d[e + 12] & 0x10 != 0 { ext = ext.lowercased() }
        if deleted {
            // El primer carácter se pierde al borrar; las cámaras usan nombres predecibles.
            base = "_" + base.dropFirst()
            for (lost, guess) in [("_MG_", "IMG_"), ("_SC", "DSC"), ("_VID", "MVID"), ("_IMG", "PIMG")] where base.hasPrefix(lost) {
                base = guess + base.dropFirst(lost.count)
                break
            }
        }
        return ext.isEmpty ? base : "\(base).\(ext)"
    }

    func allocatedRanges() -> [Range<Int64>] {
        let entrySize = isFAT32 ? 4 : 2
        let table = r.bytes(at: fatOffset, count: (clusterCount + 2) * entrySize)
        let metadata = base..<dataStart
        return [metadata] + FileSystemScanner.ranges(clusterCount: clusterCount, clusterSize: clusterSize, heap: dataStart) { i in
            let at = (i + 2) * entrySize
            guard at + entrySize <= table.count else { return false }
            return (isFAT32 ? table.le32(at) & 0x0FFF_FFFF : Int64(table.le16(at))) != 0
        }
    }
}

// MARK: - exFAT

final class ExFATVolume {
    let r: DiskReader
    let base: Int64
    let clusterSize: Int64
    let fatOffset: Int64
    let heap: Int64
    let clusterCount: Int
    let rootCluster: Int64
    private(set) var label: String?
    private var bitmap: [UInt8] = []
    private var visited = Set<Int64>()

    init?(reader: DiskReader, base: Int64, boot b: [UInt8]) {
        r = reader
        self.base = base
        let bps = Int64(1) << Int64(b[108]), spc = Int64(1) << Int64(b[109])
        guard b[108] >= 9, b[108] <= 12, b[109] <= 25 else { return nil }
        clusterSize = bps * spc
        fatOffset = base + b.le32(80) * bps
        heap = base + b.le32(88) * bps
        clusterCount = Int(b.le32(92))
        rootCluster = b.le32(96)
    }

    func clusterOffset(_ c: Int64) -> Int64 { heap + (c - 2) * clusterSize }
    func validCluster(_ c: Int64) -> Bool { c >= 2 && c < Int64(clusterCount) + 2 }

    func fatEntry(_ c: Int64) -> Int64 {
        let b = r.bytes(at: fatOffset + c * 4, count: 4)
        return b.count == 4 ? b.le32(0) : 0
    }

    func isAllocated(_ c: Int64) -> Bool {
        let i = Int(c - 2)
        guard i >= 0, i / 8 < bitmap.count else { return false }
        return bitmap[i / 8] & (1 << (i % 8)) != 0
    }

    /// Clusters de un archivo: contiguos si tiene la marca NoFatChain, si no, siguiendo la FAT.
    func clusters(first: Int64, length: Int64, contiguous: Bool) -> [Int64] {
        let needed = max(1, (length + clusterSize - 1) / clusterSize)
        if contiguous || fatEntry(first) == 0 {
            return (0..<min(needed, 4_000_000)).map { first + $0 }.filter(validCluster)
        }
        var out: [Int64] = []
        var c = first
        while validCluster(c), out.count < needed {
            out.append(c)
            let next = fatEntry(c)
            if next >= 0xFFFF_FFF7 || next < 2 { break }
            c = next
        }
        return out
    }

    func extents(of clusters: [Int64], length: Int64) -> [Extent] {
        var out: [Extent] = []
        var remaining = length
        for c in clusters where remaining > 0 {
            let n = min(clusterSize, remaining)
            if let last = out.last, last.offset + last.length == clusterOffset(c) {
                out[out.count - 1] = Extent(offset: last.offset, length: last.length + n)
            } else {
                out.append(Extent(offset: clusterOffset(c), length: n))
            }
            remaining -= n
        }
        return out
    }

    private func read(_ clusters: [Int64]) -> [UInt8] {
        clusters.flatMap { r.bytes(at: clusterOffset($0), count: Int(clusterSize)) }
    }

    func scan(isCancelled: () -> Bool, onFound: (FoundFile) -> Void) {
        var root: [Int64] = []
        var c = rootCluster
        while validCluster(c), root.count < 100_000 {
            root.append(c)
            let next = fatEntry(c)
            if next >= 0xFFFF_FFF7 || next < 2 { break }
            c = next
        }
        let dir = read(root)
        // El mapa de bits de ocupación está en la raíz; hace falta antes de evaluar los borrados.
        for e in stride(from: 0, to: dir.count - 31, by: 32) {
            if dir[e] == 0x81 {
                bitmap = r.bytes(at: clusterOffset(dir.le32(e + 20)), count: Int(min(dir.le64(e + 24), 512 * MB)))
            } else if dir[e] == 0x83 {
                let n = Int(min(dir[e + 1], 11))
                label = String(decoding: (0..<n).map { UInt16(dir[e + 2 + $0 * 2]) | UInt16(dir[e + 3 + $0 * 2]) << 8 }, as: UTF16.self)
            }
        }
        walk(dir, path: "", depth: 0, isCancelled: isCancelled, onFound: onFound)
    }

    private func walk(_ dir: [UInt8], path: String, depth: Int, isCancelled: () -> Bool, onFound: (FoundFile) -> Void) {
        guard depth < 32, !isCancelled() else { return }
        var e = 0
        while e + 32 <= dir.count {
            let type = dir[e]
            if type == 0x00 { break }
            guard type == 0x85 || type == 0x05 else { e += 32; continue }
            let deleted = type == 0x05
            let secondary = Int(dir[e + 1])
            let attrs = dir.le16(e + 4)
            let modified = FileSystemScanner.dosDate(date: Int(dir.le32(e + 12) >> 16), time: Int(dir.le32(e + 12) & 0xFFFF))
            let streamAt = e + 32
            guard secondary >= 2, streamAt + 32 <= dir.count, dir[streamAt] & 0x7F == 0x40 else { e += 32; continue }

            let flags = dir[streamAt + 1], nameLength = Int(dir[streamAt + 3])
            let validLength = dir.le64(streamAt + 8), first = dir.le32(streamAt + 20), dataLength = dir.le64(streamAt + 24)
            var units: [UInt16] = []
            for n in 2...secondary where e + n * 32 + 32 <= dir.count && dir[e + n * 32] & 0x7F == 0x41 {
                let at = e + n * 32
                units += (0..<15).map { UInt16(dir[at + 2 + $0 * 2]) | UInt16(dir[at + 3 + $0 * 2]) << 8 }
            }
            let name = String(decoding: units.prefix(nameLength), as: UTF16.self)
            e += 32 * (secondary + 1)
            guard !name.isEmpty, validCluster(first) else { continue }
            let contiguous = flags & 0x02 != 0

            if attrs & 0x10 != 0 {
                guard visited.insert(first).inserted else { continue }
                let sub = read(clusters(first: first, length: dataLength, contiguous: contiguous))
                walk(sub, path: path + "/" + name, depth: depth + 1, isCancelled: isCancelled, onFound: onFound)
                continue
            }
            guard deleted, dataLength > 0 else { continue }
            let length = validLength > 0 ? min(validLength, dataLength) : dataLength
            let (fullName, ext) = FileSystemScanner.splitName(name)
            onFound(FoundFile(name: fullName, folder: path.isEmpty ? "/" : path, ext: ext,
                              extents: extents(of: clusters(first: first, length: length, contiguous: contiguous), length: length),
                              modified: modified, origin: .fileSystem("exFAT"),
                              likelyOverwritten: isAllocated(first)))
        }
    }

    func allocatedRanges() -> [Range<Int64>] {
        guard !bitmap.isEmpty else { return [] }
        return [base..<heap] + FileSystemScanner.ranges(clusterCount: clusterCount, clusterSize: clusterSize, heap: heap) {
            isAllocated(Int64($0) + 2)
        }
    }
}
