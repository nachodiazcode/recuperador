import XCTest
@testable import RecoveryCore

final class NTFSTests: XCTestCase {
    func testRecoversDeletedFilesWithNamesAndSkipsLiveOnes() throws {
        let cluster = 4096
        let recordSize = 1024
        let recordCount = 20
        var disk = [UInt8](repeating: 0, count: 64 * cluster)

        // Sector de arranque NTFS.
        disk.replaceSubrange(3..<11, with: Array("NTFS    ".utf8))
        put(512, at: 11, bytes: 2, into: &disk)
        disk[13] = 8
        put(UInt64(disk.count / 512), at: 40, bytes: 8, into: &disk)
        put(4, at: 48, bytes: 8, into: &disk) // $MFT en el clúster 4
        put(2, at: 56, bytes: 8, into: &disk)
        disk[64] = 0xF6 // registro de 1024 bytes
        disk[510] = 0x55
        disk[511] = 0xAA

        func place(_ record: [UInt8], _ index: Int) {
            let at = 4 * cluster + index * recordSize
            disk.replaceSubrange(at..<(at + recordSize), with: record)
        }

        let mftRun: [UInt8] = [0x11, 0x05, 0x04, 0x00]
        place(fileRecord(index: 0, flags: 0x01, attributes: nonResidentData(size: recordCount * recordSize, allocated: 5 * cluster, lastVCN: 4, run: mftRun, id: 1)), 0)
        place(fileRecord(index: 3, flags: 0x01, attributes: volumeName("PRUEBA")), 3)
        place(fileRecord(index: 5, flags: 0x03, attributes: fileName(parent: 5, name: ".", id: 1)), 5)

        let fotoRun: [UInt8] = [0x11, 0x01, 0x28, 0x00] // 1 clúster en el LCN 40
        let foto = fileName(parent: 5, name: "foto.jpg", id: 2) + nonResidentData(size: 11, allocated: cluster, lastVCN: 0, run: fotoRun, id: 3)
        place(fileRecord(index: 16, flags: 0x00, attributes: foto), 16)
        disk.replaceSubrange((40 * cluster)..<(40 * cluster + 11), with: Array("hello world".utf8))

        place(fileRecord(index: 17, flags: 0x01, attributes: fileName(parent: 5, name: "vivo.txt", id: 2) + residentData(Array("no".utf8), id: 3)), 17)
        place(fileRecord(index: 18, flags: 0x02, attributes: fileName(parent: 5, name: "DCIM", id: 2)), 18)
        place(fileRecord(index: 19, flags: 0x00, attributes: fileName(parent: 18, name: "nota.txt", id: 2) + residentData(Array("hola".utf8), id: 3)), 19)

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(disk).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let reader = try DiskReader(path: tmp.path, pageSize: 8192)

        var volumes: [VolumeInfo] = []
        var found: [FoundFile] = []
        let allocated = FileSystemScanner.scan(reader, onVolume: { volumes.append($0) }, onFound: { found.append($0) })

        XCTAssertEqual(volumes.map(\.format), ["NTFS"])
        XCTAssertEqual(volumes.first?.name, "PRUEBA")
        XCTAssertEqual(volumes.first?.namesSupported, true)
        XCTAssertTrue(allocated.contains { $0.contains(4 * Int64(cluster)) })

        XCTAssertEqual(found.count, 2)
        let photo = try XCTUnwrap(found.first { $0.name == "foto.jpg" })
        XCTAssertEqual(photo.folder, "/")
        XCTAssertEqual(photo.ext, "jpg")
        XCTAssertEqual(photo.size, 11)
        XCTAssertEqual(photo.origin, .fileSystem("NTFS"))
        XCTAssertFalse(photo.likelyOverwritten)
        XCTAssertEqual(reader.bytes(at: photo.offset, count: 11), Array("hello world".utf8))

        let note = try XCTUnwrap(found.first { $0.name == "nota.txt" })
        XCTAssertEqual(note.folder, "/DCIM")
        XCTAssertEqual(note.size, 4)
        XCTAssertEqual(reader.bytes(at: note.offset, count: 4), Array("hola".utf8))
        XCTAssertNil(found.first { $0.name == "vivo.txt" })
    }
}

private func put(_ value: UInt64, at i: Int, bytes n: Int, into b: inout [UInt8]) {
    for k in 0..<n { b[i + k] = UInt8((value >> (8 * k)) & 0xFF) }
}

private func align8(_ n: Int) -> Int { (n + 7) & ~7 }

private func fileRecord(index: Int, flags: Int, attributes: [UInt8]) -> [UInt8] {
    var rec = [UInt8](repeating: 0, count: 1024)
    rec.replaceSubrange(0..<4, with: Array("FILE".utf8))
    put(48, at: 4, bytes: 2, into: &rec)
    put(3, at: 6, bytes: 2, into: &rec)
    put(1, at: 16, bytes: 2, into: &rec)
    put(1, at: 18, bytes: 2, into: &rec)
    put(56, at: 20, bytes: 2, into: &rec)
    put(UInt64(flags), at: 22, bytes: 2, into: &rec)
    put(UInt64(56 + attributes.count), at: 24, bytes: 4, into: &rec)
    put(1024, at: 28, bytes: 4, into: &rec)
    put(UInt64(index), at: 44, bytes: 4, into: &rec)
    rec[48] = 1
    rec.replaceSubrange(56..<(56 + attributes.count), with: attributes)
    rec[510] = 1
    rec[1022] = 1
    return rec
}

private func fileName(parent: UInt64, name: String, id: Int) -> [UInt8] {
    let units = Array(name.utf16)
    let valueLen = 66 + units.count * 2
    var a = [UInt8](repeating: 0, count: align8(24 + valueLen))
    put(0x30, at: 0, bytes: 4, into: &a)
    put(UInt64(a.count), at: 4, bytes: 4, into: &a)
    put(UInt64(id), at: 14, bytes: 2, into: &a)
    put(UInt64(valueLen), at: 16, bytes: 4, into: &a)
    put(24, at: 20, bytes: 2, into: &a)
    put(parent, at: 24, bytes: 8, into: &a)
    a[24 + 64] = UInt8(units.count)
    a[24 + 65] = 1
    for (i, unit) in units.enumerated() {
        a[24 + 66 + i * 2] = UInt8(unit & 0xFF)
        a[24 + 67 + i * 2] = UInt8(unit >> 8)
    }
    return a
}

private func residentData(_ bytes: [UInt8], id: Int) -> [UInt8] {
    var a = [UInt8](repeating: 0, count: align8(24 + bytes.count))
    put(0x80, at: 0, bytes: 4, into: &a)
    put(UInt64(a.count), at: 4, bytes: 4, into: &a)
    put(UInt64(id), at: 14, bytes: 2, into: &a)
    put(UInt64(bytes.count), at: 16, bytes: 4, into: &a)
    put(24, at: 20, bytes: 2, into: &a)
    for (i, byte) in bytes.enumerated() { a[24 + i] = byte }
    return a
}

private func nonResidentData(size: Int, allocated: Int, lastVCN: UInt64, run: [UInt8], id: Int) -> [UInt8] {
    var a = [UInt8](repeating: 0, count: align8(64 + run.count))
    put(0x80, at: 0, bytes: 4, into: &a)
    put(UInt64(a.count), at: 4, bytes: 4, into: &a)
    a[8] = 1
    put(UInt64(id), at: 14, bytes: 2, into: &a)
    put(lastVCN, at: 24, bytes: 8, into: &a)
    put(64, at: 32, bytes: 2, into: &a)
    put(UInt64(allocated), at: 40, bytes: 8, into: &a)
    put(UInt64(size), at: 48, bytes: 8, into: &a)
    put(UInt64(size), at: 56, bytes: 8, into: &a)
    for (i, byte) in run.enumerated() { a[64 + i] = byte }
    return a
}

private func volumeName(_ name: String) -> [UInt8] {
    let units = Array(name.utf16)
    var a = [UInt8](repeating: 0, count: align8(24 + units.count * 2))
    put(0x60, at: 0, bytes: 4, into: &a)
    put(UInt64(a.count), at: 4, bytes: 4, into: &a)
    put(UInt64(units.count * 2), at: 16, bytes: 4, into: &a)
    put(24, at: 20, bytes: 2, into: &a)
    for (i, unit) in units.enumerated() {
        a[24 + i * 2] = UInt8(unit & 0xFF)
        a[25 + i * 2] = UInt8(unit >> 8)
    }
    return a
}
