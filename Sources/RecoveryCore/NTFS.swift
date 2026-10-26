import Foundation

/// Lee la MFT de un volumen NTFS y recupera los archivos borrados que todavía tienen
/// registro: nombre, carpeta, fechas y la lista de clústeres. No escribe nada.
///
/// Un archivo borrado en NTFS conserva su registro `FILE` con el bit "en uso" apagado, hasta
/// que ese registro se reutiliza. Los datos se leen de los data runs que quedaron escritos.
/// Los archivos comprimidos o cifrados por NTFS se omiten: sus bytes no están en claro.
final class NTFSVolume {
    let r: DiskReader
    let base: Int64
    let clusterSize: Int64
    let recordSize: Int
    private let clusterCount: Int64
    private var mftRuns: [(lcn: Int64, clusters: Int64)] = []
    private var bitmapRuns: [(lcn: Int64, clusters: Int64)] = []
    private(set) var label: String?

    init?(reader: DiskReader, base: Int64, boot b: [UInt8]) {
        guard b.count >= 512, b.starts(with: "NTFS    ", at: 3), b[510] == 0x55, b[511] == 0xAA else { return nil }
        r = reader
        self.base = base
        let bps = Int64(b.le16(11))
        let spc = Int64(b[13])
        guard [512, 1024, 2048, 4096].contains(bps), spc > 0, spc <= 128 else { return nil }
        clusterSize = bps * spc
        let totalSectors = b.le64(40)
        guard totalSectors > 16 else { return nil }
        clusterCount = totalSectors * bps / clusterSize
        let mftLCN = b.le64(48)
        guard mftLCN > 0, mftLCN < clusterCount else { return nil }

        let raw = Int8(bitPattern: b[64])
        if raw < 0 {
            recordSize = 1 << Int(-raw)
        } else {
            recordSize = Int(raw) * Int(clusterSize)
        }
        guard [1024, 2048, 4096].contains(recordSize) else { return nil }

        // El registro 0 es $MFT y describe dónde está el resto de la tabla.
        let first = reader.bytes(at: base + mftLCN * clusterSize, count: recordSize)
        guard first.count == recordSize, let fixed = Self.fixup(first),
              let data = Self.attributes(fixed).first(where: { $0.type == 0x80 && $0.name.isEmpty }),
              let runs = data.runs, !runs.isEmpty else { return nil }
        mftRuns = runs
        if let volume = readRecord(3), let fixed = Self.fixup(volume),
           let text = Self.attributes(fixed).first(where: { $0.type == 0x60 })?.text, !text.isEmpty {
            label = text
        }
    }

    func scan(isCancelled: () -> Bool, onFound: (FoundFile) -> Void) {
        guard let mft = Self.attributes(Self.fixup(readRecord(0) ?? []) ?? []).first(where: { $0.type == 0x80 && $0.name.isEmpty }),
              let dataSize = mft.dataSize, dataSize >= Int64(recordSize) else { return }
        let count = min(dataSize / Int64(recordSize), 50_000_000)

        struct Dir { var parent: UInt64; var name: String }
        struct Deleted {
            var parent: UInt64
            var name: String
            var extents: [Extent]
            var size: Int64
            var modified: Date?
            var overwritten: Bool
        }
        var dirs: [UInt64: Dir] = [:]
        var deleted: [Deleted] = []

        var bitmap: [UInt8] = []
        if let rec6 = readRecord(6), let fixed = Self.fixup(rec6),
           let data = Self.attributes(fixed).first(where: { $0.type == 0x80 && $0.name.isEmpty }) {
            bitmapRuns = data.runs ?? []
            // Se carga solo si cabe en memoria; si no, el mapa de ocupación se lee por tramos al final.
            if let size = data.dataSize, size > 0, size <= 32 * MB, let bytes = readFork(bitmapRuns, at: 0, count: Int(size)) {
                bitmap = bytes
            }
        }

        func allocated(_ lcn: Int64) -> Bool {
            guard lcn >= 0, !bitmap.isEmpty else { return false }
            let i = Int(lcn)
            guard i / 8 < bitmap.count else { return false }
            return bitmap[i / 8] & (1 << (i % 8)) != 0
        }

        for index in 0..<count {
            if index % 4096 == 0, isCancelled() { return }
            guard let raw = readRecord(index), let rec = Self.fixup(raw) else { continue }
            let flags = rec.le16(22)
            let inUse = flags & 0x01 != 0
            let isDir = flags & 0x02 != 0
            let attrs = Self.attributes(rec)
            guard let nameAttr = attrs.filter({ $0.type == 0x30 && !$0.name.isEmpty && $0.name != "." && $0.name != ".." })
                .sorted(by: { Self.nameRank($0.namespace) < Self.nameRank($1.namespace) }).first else { continue }
            let recordNumber = UInt64(index)
            if isDir {
                dirs[recordNumber] = Dir(parent: nameAttr.parent, name: nameAttr.name)
                continue
            }
            guard !inUse, index >= 16, !nameAttr.name.hasPrefix("$") else { continue }
            guard let data = attrs.first(where: { $0.type == 0x80 && $0.name.isEmpty && !$0.compressed && !$0.encrypted }),
                  let size = data.dataSize, size > 0 else { continue }

            let extents: [Extent]
            let overwritten: Bool
            if let resident = data.resident {
                // Los dos últimos bytes de cada sector son el número de secuencia, no datos.
                // Si el archivo residente los pisa, no se puede copiar tal cual del disco.
                let sectors = recordSize / 512
                let valueEnd = resident.offset + resident.count
                let collides = (1...sectors).contains { i in
                    let at = i * 512 - 2
                    return at < valueEnd && at + 2 > resident.offset
                }
                guard !collides, resident.count > 0,
                      let phys = physicalOffset(ofMFTByte: Int64(index) * Int64(recordSize) + Int64(resident.offset)) else { continue }
                extents = [Extent(offset: phys, length: Int64(resident.count))]
                overwritten = false
            } else if let runs = data.runs {
                extents = Self.extents(runs, size: size, clusterSize: clusterSize, base: base)
                let firstCluster = extents.first.map { ($0.offset - base) / clusterSize } ?? -1
                overwritten = allocated(firstCluster)
            } else {
                continue
            }
            guard !extents.isEmpty else { continue }
            let modified = attrs.first { $0.type == 0x10 }?.modified ?? nameAttr.modified
            deleted.append(Deleted(parent: nameAttr.parent, name: nameAttr.name, extents: extents,
                                   size: size, modified: modified, overwritten: overwritten))
        }

        func folder(_ parent: UInt64) -> String {
            if parent == 5 || parent == 0 { return "/" }
            var names: [String] = []
            var id = parent
            var seen = Set<UInt64>()
            while id != 5 && id != 0 && seen.insert(id).inserted && names.count < 64 {
                guard let dir = dirs[id] else { return "/_Sin carpeta" }
                names.append(dir.name)
                id = dir.parent
            }
            return "/" + names.reversed().joined(separator: "/")
        }

        for file in deleted {
            let (full, ext) = FileSystemScanner.splitName(file.name)
            onFound(FoundFile(name: full, folder: folder(file.parent), ext: ext, extents: file.extents,
                              modified: file.modified, origin: .fileSystem("NTFS"),
                              likelyOverwritten: file.overwritten))
        }
    }

    /// Clústeres ocupados por archivos que siguen vivos. El escaneo profundo los salta.
    func allocatedRanges() -> [Range<Int64>] {
        var out: [Range<Int64>] = []
        for run in mftRuns where run.lcn >= 0 {
            let start = base + run.lcn * clusterSize
            out.append(start..<(start + run.clusters * clusterSize))
        }
        guard !bitmapRuns.isEmpty else { return out }
        let bytesCount = (clusterCount + 7) / 8
        var logical: Int64 = 0
        var runStart: Int64?
        func close(_ at: Int64) {
            if let s = runStart {
                out.append((base + s * clusterSize)..<(base + at * clusterSize))
                runStart = nil
            }
        }
        while logical < bytesCount {
            let n = Int(min(256 * 1024, bytesCount - logical))
            guard let chunk = readFork(bitmapRuns, at: logical, count: n), chunk.count == n else { break }
            for (i, byte) in chunk.enumerated() {
                if byte == 0 {
                    close((logical + Int64(i)) * 8)
                    continue
                }
                if byte == 0xFF {
                    let start = (logical + Int64(i)) * 8
                    if runStart == nil { runStart = start }
                    continue
                }
                for bit in 0..<8 {
                    let cluster = (logical + Int64(i)) * 8 + Int64(bit)
                    if cluster >= clusterCount { close(cluster); return out }
                    if byte & (1 << bit) != 0 {
                        if runStart == nil { runStart = cluster }
                    } else {
                        close(cluster)
                    }
                }
            }
            logical += Int64(n)
        }
        close(clusterCount)
        return out
    }

    // MARK: - Registros

    private func readRecord(_ index: Int64) -> [UInt8]? {
        readFork(mftRuns, at: index * Int64(recordSize), count: recordSize)
    }

    /// Offset físico de un byte de la MFT, si ese byte cae en un tramo contiguo.
    private func physicalOffset(ofMFTByte logical: Int64) -> Int64? {
        var skipped: Int64 = 0
        for run in mftRuns {
            let length = run.clusters * clusterSize
            if logical < skipped + length {
                guard run.lcn >= 0 else { return nil }
                return base + run.lcn * clusterSize + (logical - skipped)
            }
            skipped += length
        }
        return nil
    }

    private func readFork(_ runs: [(lcn: Int64, clusters: Int64)], at logical: Int64, count: Int) -> [UInt8]? {
        guard count > 0 else { return [] }
        var out = [UInt8]()
        out.reserveCapacity(count)
        var pos = logical
        let end = logical + Int64(count)
        while pos < end {
            var skipped: Int64 = 0
            var found = false
            for run in runs {
                let length = run.clusters * clusterSize
                if pos < skipped + length {
                    guard run.lcn >= 0 else { return nil }
                    let inside = pos - skipped
                    let n = Int(min(end - pos, length - inside))
                    let chunk = r.bytes(at: base + run.lcn * clusterSize + inside, count: n)
                    guard chunk.count == n else { return nil }
                    out.append(contentsOf: chunk)
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

    /// Restaura los últimos dos bytes de cada sector, que NTFS sustituye por el número de secuencia.
    private static func fixup(_ raw: [UInt8]) -> [UInt8]? {
        guard raw.count >= 42, raw.starts(with: "FILE") else { return nil }
        var b = raw
        let usaOff = b.le16(4)
        let usaCount = b.le16(6)
        let sectors = b.count / 512
        guard usaCount == sectors + 1, usaOff >= 42, usaOff + usaCount * 2 <= b.count else { return nil }
        let usn = b.le16(usaOff)
        for i in 1..<usaCount {
            let at = i * 512 - 2
            guard b.le16(at) == usn else { return nil }
            let repl = usaOff + i * 2
            b[at] = b[repl]
            b[at + 1] = b[repl + 1]
        }
        return b
    }

    private static func nameRank(_ namespace: Int) -> Int {
        switch namespace {
        case 1, 3: return 0 // Win32
        case 0: return 1    // POSIX
        default: return 2   // DOS 8.3
        }
    }

    private static func extents(_ runs: [(lcn: Int64, clusters: Int64)], size: Int64, clusterSize: Int64, base: Int64) -> [Extent] {
        var out: [Extent] = []
        var remaining = size
        for run in runs where remaining > 0 {
            let bytes = run.clusters * clusterSize
            let n = min(bytes, remaining)
            if run.lcn >= 0 {
                let offset = base + run.lcn * clusterSize
                if let last = out.last, last.offset + last.length == offset {
                    out[out.count - 1] = Extent(offset: last.offset, length: last.length + n)
                } else {
                    out.append(Extent(offset: offset, length: n))
                }
            }
            remaining -= n
        }
        return out
    }

    // MARK: - Atributos

    private struct Attr {
        var type: Int64
        var name: String
        var namespace: Int
        var parent: UInt64
        var modified: Date?
        var dataSize: Int64?
        var runs: [(lcn: Int64, clusters: Int64)]?
        var resident: (offset: Int, count: Int)?
        var compressed: Bool
        var encrypted: Bool
        var text: String?
    }

    private static func attributes(_ rec: [UInt8]) -> [Attr] {
        guard rec.count > 22 else { return [] }
        var pos = rec.le16(20)
        var out: [Attr] = []
        while pos + 8 <= rec.count {
            let type = rec.le32(pos)
            if type == 0xFFFF_FFFF || type == 0 { break }
            let length = Int(rec.le32(pos + 4))
            guard length >= 24, pos + length <= rec.count else { break }
            let nonResident = rec[pos + 8] != 0
            let nameLen = Int(rec[pos + 9])
            let nameOff = rec.le16(pos + 10)
            let flags = rec.le16(pos + 12)
            var attr = Attr(type: type, name: "", namespace: 0, parent: 0, modified: nil, dataSize: nil,
                            runs: nil, resident: nil, compressed: flags & 0x0001 != 0, encrypted: flags & 0x4000 != 0,
                            text: nil)
            if nameLen > 0, nameOff + nameLen * 2 <= length {
                attr.name = utf16(rec, pos + nameOff, nameLen)
            }
            if !nonResident {
                let valueLen = Int(rec.le32(pos + 16))
                let valueOff = rec.le16(pos + 20)
                guard valueOff >= 0, valueLen >= 0, valueOff + valueLen <= length else { pos += length; continue }
                let value = pos + valueOff
                if type == 0x80 || type == 0x60 {
                    attr.resident = (value, valueLen)
                    attr.dataSize = Int64(valueLen)
                    if type == 0x60 { attr.text = utf16(rec, value, valueLen / 2) }
                } else if type == 0x10, valueLen >= 16 {
                    attr.modified = fileTime(rec.le64(value + 8))
                } else if type == 0x30, valueLen >= 66 {
                    attr.parent = UInt64(bitPattern: rec.le64(value)) & 0x0000_FFFF_FFFF_FFFF
                    attr.modified = fileTime(rec.le64(value + 16))
                    let n = Int(rec[value + 64])
                    attr.namespace = Int(rec[value + 65])
                    guard 66 + n * 2 <= valueLen else { pos += length; continue }
                    attr.name = utf16(rec, value + 66, n)
                }
            } else if length >= 64 {
                attr.dataSize = rec.le64(pos + 48)
                let runOff = rec.le16(pos + 32)
                if runOff >= 32, runOff < length {
                    attr.runs = dataRuns(rec, start: pos + runOff, end: pos + length)
                }
            }
            out.append(attr)
            pos += length
        }
        return out
    }

    private static func dataRuns(_ b: [UInt8], start: Int, end: Int) -> [(lcn: Int64, clusters: Int64)] {
        var runs: [(lcn: Int64, clusters: Int64)] = []
        var p = start
        var lcn: Int64 = 0
        while p < end, b[p] != 0 {
            let lenBytes = Int(b[p] & 0x0F)
            let offBytes = Int(b[p] >> 4)
            p += 1
            guard lenBytes > 0, lenBytes <= 8, offBytes <= 8, p + lenBytes + offBytes <= end else { break }
            let length = le(b, p, lenBytes, signed: false)
            p += lenBytes
            if offBytes == 0 {
                runs.append((-1, length))
            } else {
                lcn += le(b, p, offBytes, signed: true)
                runs.append((lcn, length))
            }
            p += offBytes
        }
        return runs
    }

    /// Entero little-endian de 1 a 8 bytes. `signed` extiende el signo (los offsets de un data run son relativos y con signo).
    private static func le(_ b: [UInt8], _ p: Int, _ n: Int, signed: Bool) -> Int64 {
        var u: UInt64 = 0
        for i in 0..<n { u |= UInt64(b[p + i]) << (8 * i) }
        if signed, n > 0, n < 8, b[p + n - 1] & 0x80 != 0 {
            u = u &- (UInt64(1) << (8 * n))
        }
        return Int64(bitPattern: u)
    }

    private static func utf16(_ b: [UInt8], _ at: Int, _ units: Int) -> String {
        guard units > 0, at + units * 2 <= b.count else { return "" }
        let codes = (0..<units).map { UInt16(b[at + $0 * 2]) | UInt16(b[at + $0 * 2 + 1]) << 8 }
        return String(decoding: codes, as: UTF16.self)
    }

    private static func fileTime(_ ticks: Int64) -> Date? {
        guard ticks > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(ticks) / 10_000_000 - 11_644_473_600)
    }
}
