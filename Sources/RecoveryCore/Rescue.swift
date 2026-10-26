import Foundation

/// Clonado de rescate al estilo `ddrescue`: primero copia rápido todo lo que se puede leer
/// saltando las zonas con errores, y después vuelve a esas zonas para rescatar sector por sector.
/// Así se aprovecha al máximo un disco que se está muriendo antes de insistir en lo difícil.
public final class RescueCloner: @unchecked Sendable {
    public enum Block: UInt8, Sendable { case pending, ok, bad, partial }

    public struct Snapshot: Sendable {
        public let pass: Int
        public let copied: Int64
        public let total: Int64
        public let badBytes: Int64
        public let elapsed: TimeInterval
        /// Estado de cada bloque, reducido a `cells` celdas para dibujar el mapa.
        public let map: [Block]
    }

    public let blockSize: Int64 = 1 << 20
    private let reader: DiskReader
    private var blocks: [Block]
    private var badBytes: Int64 = 0

    public init(reader: DiskReader) {
        self.reader = reader
        blocks = Array(repeating: .pending, count: Int((reader.size + (1 << 20) - 1) >> 20))
    }

    public func run(to destination: URL, cells: Int = 1200, isCancelled: () -> Bool,
                    progress: (Snapshot) -> Void) throws {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let out = try FileHandle(forWritingTo: destination)
        defer { try? out.close() }
        try out.truncate(atOffset: UInt64(reader.size)) // imagen dispersa: lo ilegible queda en ceros
        let began = Date()
        var last = Date.distantPast
        var copied: Int64 = 0

        func report(_ pass: Int, force: Bool = false) {
            guard force || Date().timeIntervalSince(last) > 0.2 else { return }
            last = Date()
            progress(Snapshot(pass: pass, copied: copied, total: reader.size, badBytes: badBytes,
                              elapsed: Date().timeIntervalSince(began), map: map(cells)))
        }

        // Pasada 1: bloques completos; un error marca el bloque y se sigue de largo.
        for i in blocks.indices where !isCancelled() {
            let offset = Int64(i) * blockSize
            let length = Int(min(blockSize, reader.size - offset))
            if let data = reader.readDirect(at: offset, count: length) {
                try out.seek(toOffset: UInt64(offset))
                try out.write(contentsOf: data)
                blocks[i] = .ok
            } else {
                blocks[i] = .bad
                badBytes += Int64(length)
            }
            copied += Int64(length)
            report(1)
        }

        // Pasada 2: rescatar sector por sector dentro de los bloques dañados.
        let sector = Int64(reader.sectorSize)
        for i in blocks.indices where blocks[i] == .bad && !isCancelled() {
            let offset = Int64(i) * blockSize
            let length = min(blockSize, reader.size - offset)
            var good: Int64 = 0
            var s: Int64 = 0
            while s < length, !isCancelled() {
                if let data = reader.readDirect(at: offset + s, count: Int(sector)) {
                    try out.seek(toOffset: UInt64(offset + s))
                    try out.write(contentsOf: data)
                    good += sector
                }
                s += sector
            }
            badBytes -= good
            blocks[i] = good == length ? .ok : good > 0 ? .partial : .bad
            report(2)
        }
        report(2, force: true)
    }

    private func map(_ cells: Int) -> [Block] {
        guard !blocks.isEmpty else { return [] }
        let n = min(cells, blocks.count)
        return (0..<n).map { c in
            let range = (c * blocks.count / n)..<max(c * blocks.count / n + 1, (c + 1) * blocks.count / n)
            let slice = blocks[range]
            if slice.contains(.bad) { return .bad }
            if slice.contains(.partial) { return .partial }
            if slice.contains(.pending) { return slice.contains(.ok) ? .ok : .pending }
            return .ok
        }
    }
}
