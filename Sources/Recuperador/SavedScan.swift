import Foundation
import RecoveryCore

/// Cabecera liviana del último escaneo guardado en disco, para mostrarlo al abrir la app sin tener
/// que cargar cientos de miles de entradas en memoria hasta que el usuario pida retomarlo.
struct SavedScanHeader: Codable, Equatable, Sendable {
    let sourceName: String
    let sourceSymbol: String
    let readerPath: String
    let isDevice: Bool
    let diskID: String?
    let diskSize: Int64
    let fileCount: Int
    let totalBytes: Int64
    let badSectors: Int
    let finished: Bool
    let savedAt: Date
    let volumes: [VolumeInfo]
}

/// Guarda y restaura un escaneo en un archivo binario compacto (~25 bytes por archivo tallado:
/// medio millón de archivos ocupan ~12 MB y se leen o escriben en una fracción de segundo).
enum SavedScanStore {
    private static let magic: [UInt8] = Array("RCUP0001".utf8)

    static var fileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recuperador", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("ultimo-escaneo.rcup")
    }

    static func readHeader() -> SavedScanHeader? {
        guard let fh = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? fh.close() }
        guard let prefix = try? fh.read(upToCount: 12), prefix.count == 12,
              Array(prefix.prefix(8)) == magic else { return nil }
        let headerLen = Int(prefix.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self).littleEndian })
        guard headerLen > 0, headerLen < 1_000_000,
              let json = try? fh.read(upToCount: headerLen), json.count == headerLen else { return nil }
        return try? JSONDecoder().decode(SavedScanHeader.self, from: json)
    }

    static func save(header: SavedScanHeader, files: [FoundFile]) {
        guard !files.isEmpty, let headerJSON = try? JSONEncoder().encode(header) else { return }
        var out = Data()
        out.reserveCapacity(12 + headerJSON.count + files.count * 32)
        out.append(contentsOf: magic)
        out.appendLE(UInt32(headerJSON.count))
        out.append(headerJSON)
        for f in files {
            var flags: UInt8 = 0
            if f.name != nil { flags |= 1 << 0 }
            if f.folder != nil { flags |= 1 << 1 }
            if f.modified != nil { flags |= 1 << 2 }
            switch f.origin {
            case .fileSystem: flags |= 1 << 3
            case let .carved(exact): if exact { flags |= 1 << 4 }
            }
            if f.likelyOverwritten { flags |= 1 << 5 }
            if f.embedded { flags |= 1 << 6 }
            out.append(flags)
            out.appendShortString(f.ext)
            if let name = f.name { out.appendString(name) }
            if let folder = f.folder { out.appendString(folder) }
            if case let .fileSystem(fs) = f.origin { out.appendShortString(fs) }
            if let mod = f.modified { out.appendLE(mod.timeIntervalSince1970.bitPattern) }
            let extents = f.extents.prefix(Int(UInt16.max))
            out.appendLE(UInt16(extents.count))
            for e in extents {
                out.appendLE(e.offset)
                out.appendLE(e.length)
            }
        }
        try? out.write(to: fileURL, options: .atomic)
    }

    static func load() -> (SavedScanHeader, [FoundFile])? {
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
              data.count >= 12 else { return nil }
        return data.withUnsafeBytes { raw -> (SavedScanHeader, [FoundFile])? in
            var c = Cursor(raw: raw)
            guard c.bytes(8) == magic, let headerLen: UInt32 = c.le(),
                  let json = c.slice(Int(headerLen)),
                  let header = try? JSONDecoder().decode(SavedScanHeader.self, from: json) else { return nil }
            var files: [FoundFile] = []
            files.reserveCapacity(header.fileCount)
            for _ in 0..<header.fileCount {
                guard let flags = c.u8(), let ext = c.shortString() else { break }
                let name: String?
                if flags & (1 << 0) != 0 {
                    guard let s = c.string() else { break }
                    name = s
                } else { name = nil }
                let folder: String?
                if flags & (1 << 1) != 0 {
                    guard let s = c.string() else { break }
                    folder = s
                } else { folder = nil }
                let origin: FoundFile.Origin
                if flags & (1 << 3) != 0 {
                    guard let fs = c.shortString() else { break }
                    origin = .fileSystem(fs)
                } else {
                    origin = .carved(exactLength: flags & (1 << 4) != 0)
                }
                let modified: Date?
                if flags & (1 << 2) != 0 {
                    guard let bits: UInt64 = c.le() else { break }
                    modified = Date(timeIntervalSince1970: Double(bitPattern: bits))
                } else { modified = nil }
                guard let extentCount: UInt16 = c.le() else { break }
                var extents: [Extent] = []
                extents.reserveCapacity(Int(extentCount))
                var ok = true
                for _ in 0..<extentCount {
                    guard let off: Int64 = c.le(), let len: Int64 = c.le() else { ok = false; break }
                    extents.append(Extent(offset: off, length: len))
                }
                guard ok else { break }
                files.append(FoundFile(name: name, folder: folder, ext: ext, extents: extents,
                                       modified: modified, origin: origin,
                                       likelyOverwritten: flags & (1 << 5) != 0,
                                       embedded: flags & (1 << 6) != 0))
            }
            return files.isEmpty ? nil : (header, files)
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ v: T) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }

    mutating func appendShortString(_ s: String) {
        let utf8 = Array(s.utf8.prefix(255))
        append(UInt8(utf8.count))
        append(contentsOf: utf8)
    }

    mutating func appendString(_ s: String) {
        let utf8 = Array(s.utf8.prefix(Int(UInt16.max)))
        appendLE(UInt16(utf8.count))
        append(contentsOf: utf8)
    }
}

private struct Cursor {
    let raw: UnsafeRawBufferPointer
    var pos = 0

    mutating func u8() -> UInt8? {
        guard pos < raw.count else { return nil }
        defer { pos += 1 }
        return raw[pos]
    }

    mutating func bytes(_ n: Int) -> [UInt8]? {
        guard n >= 0, pos + n <= raw.count else { return nil }
        defer { pos += n }
        return Array(raw[pos..<(pos + n)])
    }

    mutating func slice(_ n: Int) -> Data? {
        guard n >= 0, pos + n <= raw.count, let base = raw.baseAddress else { return nil }
        defer { pos += n }
        return Data(bytes: base + pos, count: n)
    }

    mutating func le<T: FixedWidthInteger>() -> T? {
        let size = MemoryLayout<T>.size
        guard pos + size <= raw.count else { return nil }
        defer { pos += size }
        return raw.loadUnaligned(fromByteOffset: pos, as: T.self).littleEndian
    }

    mutating func shortString() -> String? {
        guard let n = u8(), let b = bytes(Int(n)) else { return nil }
        return String(decoding: b, as: UTF8.self)
    }

    mutating func string() -> String? {
        guard let n: UInt16 = le(), let b = bytes(Int(n)) else { return nil }
        return String(decoding: b, as: UTF8.self)
    }
}
