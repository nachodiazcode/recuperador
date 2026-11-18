import Foundation
import XCTest
@testable import RecoveryCore

/// Lectura y extracción directas (sin pasar por la caché de páginas): es el camino que usan la
/// recuperación, las miniaturas y la reproducción de video directo del disco.
final class ExtractorTests: XCTestCase {
    private var tmp: URL!
    private var disk: [UInt8] = []
    private var reader: DiskReader!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        // 9 MB y pico: más que un tramo de transferencia (4 MB) y con un final que no cae en sector.
        disk = [UInt8](repeating: 0, count: (9 << 20) + 777)
        arc4random_buf(&disk, disk.count)
        let image = tmp.appendingPathComponent("disco.img")
        try Data(disk).write(to: image)
        reader = try DiskReader(path: image.path, pageSize: 64 * 1024)
    }

    override func tearDownWithError() throws {
        reader = nil
        try? FileManager.default.removeItem(at: tmp)
    }

    private func slice(_ offset: Int, _ count: Int) -> [UInt8] {
        Array(disk[offset..<min(disk.count, offset + count)])
    }

    func testDirectReadMatchesCachedReadAtAnyAlignment() {
        // Alineado, desalineado, cruzando sectores, más grande que un tramo y pegado al final.
        let cases = [(0, 512), (512, 4096), (1, 1), (511, 2), (1000, 70_000), (3, (5 << 20) + 11),
                     (disk.count - 1000, 1000), (disk.count - 10, 500)]
        for (offset, count) in cases {
            let expected = slice(offset, count)
            XCTAssertEqual(reader.read(at: Int64(offset), count: count), expected, "read \(offset)+\(count)")
            XCTAssertEqual(reader.readDirect(at: Int64(offset), count: count), expected, "readDirect \(offset)+\(count)")
            XCTAssertEqual(reader.bytes(at: Int64(offset), count: count), expected, "bytes \(offset)+\(count)")
        }
        XCTAssertEqual(reader.read(at: Int64(disk.count), count: 10), [])
        XCTAssertEqual(reader.read(at: -1, count: 10), [])
    }

    func testDataReadsWithoutCopyOnlyWhenSectorAligned() {
        XCTAssertEqual(reader.data(at: 1024, count: 100_001).map { [UInt8]($0) }, slice(1024, 100_001))
        // El último tramo del "disco" no es múltiplo de 512: tiene que leerse igual.
        let tail = disk.count - (disk.count % 512)
        XCTAssertEqual(reader.data(at: Int64(tail), count: disk.count - tail).map { [UInt8]($0) }, slice(tail, 1 << 20))
        XCTAssertNil(reader.data(at: 1025, count: 100), "un offset que no cae en sector usa el camino con copia")
        XCTAssertNil(reader.data(at: 1024, count: disk.count), "no se puede leer más allá del final")
    }

    func testWritesFragmentedFileAndReportsProgress() throws {
        // Tres tramos fuera de orden, uno de más de 4 MB y otro que no empieza en sector.
        let extents = [Extent(offset: 6 << 20, length: 123_457), Extent(offset: 512, length: (5 << 20) + 300),
                       Extent(offset: 5_500_001, length: 9_999)]
        let file = FoundFile(ext: "bin", extents: extents, origin: .fileSystem("NTFS"))
        let expected = extents.flatMap { slice(Int($0.offset), Int($0.length)) }

        var reports: [Int64] = []
        let out = tmp.appendingPathComponent("salida.bin")
        try Extractor.write(file, from: reader, to: out) { reports.append($0) }

        XCTAssertEqual(try [UInt8](Data(contentsOf: out)), expected)
        XCTAssertEqual(reports.last, Int64(expected.count))
        XCTAssertEqual(reports, reports.sorted(), "el avance nunca retrocede")
        XCTAssertGreaterThan(reports.count, 3, "un tramo de más de 4 MB se informa por partes")

        // Sobrescribir un archivo existente más largo no debe dejar restos del anterior.
        let short = FoundFile(ext: "bin", extents: [Extent(offset: 2048, length: 10)], origin: .carved(exactLength: true))
        try Extractor.write(short, from: reader, to: out)
        XCTAssertEqual(try [UInt8](Data(contentsOf: out)), slice(2048, 10))
    }

    func testLogicalReadCrossesExtents() {
        let extents = [Extent(offset: 4096, length: 1000), Extent(offset: 1 << 20, length: 3000),
                       Extent(offset: 70_001, length: 500)]
        let file = FoundFile(ext: "mp4", extents: extents, origin: .fileSystem("exFAT"))
        let whole = extents.flatMap { slice(Int($0.offset), Int($0.length)) }
        XCTAssertEqual(file.size, 4500)

        for (offset, count) in [(0, 4500), (0, 10), (990, 20), (999, 2), (1000, 3000), (3990, 100), (4400, 100), (4400, 5000), (0, 99_999)] {
            XCTAssertEqual(Extractor.read(file, from: reader, at: Int64(offset), count: count),
                           Array(whole[offset..<min(whole.count, offset + count)]), "tramo lógico \(offset)+\(count)")
        }
        XCTAssertEqual(Extractor.read(file, from: reader, at: 4500, count: 10), [])
        XCTAssertEqual(Extractor.data(file, from: reader, limit: 1 << 20).map { [UInt8]($0) }, whole)
        XCTAssertNil(Extractor.data(file, from: reader, limit: 4499), "más grande que el límite: no se carga en memoria")
    }

    func testDataOfSingleExtentFile() {
        let file = FoundFile(ext: "jpg", extents: [Extent(offset: 2 << 20, length: 1_234_567)], origin: .carved(exactLength: true))
        XCTAssertEqual(Extractor.data(file, from: reader, limit: 8 << 20).map { [UInt8]($0) }, slice(2 << 20, 1_234_567))
        // Un archivo incrustado en otro puede empezar en cualquier byte.
        let odd = FoundFile(ext: "jpg", extents: [Extent(offset: (2 << 20) + 5, length: 4321)], origin: .carved(exactLength: true))
        XCTAssertEqual(Extractor.data(odd, from: reader, limit: 8 << 20).map { [UInt8]($0) }, slice((2 << 20) + 5, 4321))
    }
}
