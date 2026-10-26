import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import RecoveryCore

final class CarverTests: XCTestCase {
    /// Genera una imagen real con ImageIO en el formato pedido.
    private func makeImage(_ type: UTType, size: Int = 200) -> [UInt8] {
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for i in 0..<20 {
            ctx.setFillColor(red: CGFloat(i) / 20, green: CGFloat(i % 3) / 3, blue: 0.5, alpha: 1)
            ctx.fill(CGRect(x: i * 7, y: i * 5, width: 60, height: 40))
        }
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return [UInt8](data as Data)
    }

    /// Simula un disco "formateado": basura aleatoria con archivos en offsets alineados a sector.
    func testRecoversFilesExactlyFromRawImage() throws {
        let files: [(ext: String, bytes: [UInt8])] = [
            ("jpg", makeImage(.jpeg)), ("png", makeImage(.png)), ("gif", makeImage(.gif)),
        ]
        var disk = (0..<(4 << 20)).map { _ in UInt8.random(in: 0...255) }
        var placed: [Int: [UInt8]] = [:]
        for (n, file) in files.enumerated() {
            let offset = 512 * (1000 + n * 2500)
            disk.replaceSubrange(offset..<(offset + file.bytes.count), with: file.bytes)
            placed[offset] = file.bytes
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let image = tmp.appendingPathComponent("disco.img")
        try Data(disk).write(to: image)

        let reader = try DiskReader(path: image.path, pageSize: 64 * 1024) // páginas chicas: fuerza cruces de borde
        let found = Carver(reader: reader).run()

        for (offset, bytes) in placed {
            let hit = try XCTUnwrap(found.first { $0.offset == Int64(offset) }, "no se encontró el archivo en \(offset)")
            let out = tmp.appendingPathComponent("out.\(hit.ext)")
            try Extractor.write(hit, from: reader, to: out)
            XCTAssertEqual(try [UInt8](Data(contentsOf: out)), bytes)
        }
    }

    func testSkipInteriorsDoesNotReturnAFileInsideAnother() throws {
        func bmp(size: Int, mark: UInt8) -> [UInt8] {
            var b = [UInt8](repeating: mark, count: size)
            for i in 0..<54 { b[i] = 0 }
            b[0] = 0x42
            b[1] = 0x4D
            for (i, byte) in withUnsafeBytes(of: UInt32(size).littleEndian, Array.init).enumerated() { b[2 + i] = byte }
            b[10] = 54
            b[14] = 40
            return b
        }
        var disk = [UInt8](repeating: 0, count: 8192)
        let outer = bmp(size: 4096, mark: 1)
        let inner = bmp(size: 256, mark: 2)
        disk.replaceSubrange(512..<(512 + outer.count), with: outer)
        disk.replaceSubrange(1024..<(1024 + inner.count), with: inner)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(disk).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try DiskReader(path: url.path, pageSize: 4096)

        var skipping = CarveOptions()
        skipping.skipInteriors = true
        let quiet = Carver(reader: reader, options: skipping).run()
        XCTAssertEqual(quiet.map(\.offset), [512])

        var nested = CarveOptions()
        nested.skipInteriors = false
        let both = Carver(reader: reader, options: nested).run()
        XCTAssertEqual(both.map(\.offset).sorted(), [512, 1024])
        XCTAssertEqual(both.first { $0.offset == 1024 }?.embedded, true)
        XCTAssertEqual(both.first { $0.offset == 512 }?.embedded, false)
    }

    func testFindAcrossPageBoundary() throws {
        var disk = [UInt8](repeating: 0, count: 8192)
        disk[4095] = 0xFF
        disk[4096] = 0xD9
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(disk).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try DiskReader(path: url.path, pageSize: 4096)
        XCTAssertEqual(reader.find([0xFF, 0xD9], from: 0, limit: 8192), 4095)
    }
}
