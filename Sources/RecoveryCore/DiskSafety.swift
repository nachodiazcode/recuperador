import Darwin
import Foundation

/// Escribir los archivos recuperados en el mismo disco que se escanea puede sobrescribir
/// justamente los datos que se intenta recuperar. Esto lo detecta, incluyendo volúmenes APFS
/// cuyo disco físico real es otro (p. ej. disk3s1 vive en disk0).
public enum DiskSafety {
    /// "diskN" físico de un dispositivo como /dev/rdisk4s2, o nil si `path` no es un dispositivo.
    public static func wholeDisk(ofDevice path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        guard name.hasPrefix("disk") || name.hasPrefix("rdisk") else { return nil }
        let id = name.hasPrefix("r") ? String(name.dropFirst()) : name
        return physicalDisks(of: id).first ?? stripSlice(id)
    }

    /// Discos físicos que respaldan el volumen donde está `directory`.
    public static func physicalDisks(containing directory: URL) -> [String] {
        var fs = statfs()
        guard statfs(directory.path, &fs) == 0 else { return [] }
        let from = withUnsafeBytes(of: &fs.f_mntfromname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        guard from.hasPrefix("/dev/") else { return [] }
        return physicalDisks(of: (from as NSString).lastPathComponent)
    }

    public static func isSameDisk(source: String, output: URL) -> Bool {
        guard let src = wholeDisk(ofDevice: source) else { return false }
        return physicalDisks(containing: output).contains(src)
    }

    private static func physicalDisks(of id: String) -> [String] {
        guard let info = diskInfo(id) else { return [stripSlice(id)] }
        if let stores = info["APFSPhysicalStores"] as? [[String: Any]] {
            let disks = stores.compactMap { $0["APFSPhysicalStore"] as? String }.map(stripSlice)
            if !disks.isEmpty { return disks }
        }
        if let parent = info["ParentWholeDisk"] as? String, parent != id {
            return physicalDisks(of: parent)
        }
        return [stripSlice(id)]
    }

    private static func diskInfo(_ id: String) -> [String: Any]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["info", "-plist", id]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    private static func stripSlice(_ id: String) -> String {
        guard let range = id.range(of: #"^disk\d+"#, options: .regularExpression) else { return id }
        return String(id[range])
    }
}

/// Clona un disco completo a un archivo de imagen. Es lo recomendable con discos que fallan:
/// se lee el disco una sola vez y luego se analiza la imagen todas las veces que haga falta.
public func cloneDisk(_ reader: DiskReader, to destination: URL, progress: ((Int64, Int64) -> Void)? = nil) throws {
    FileManager.default.createFile(atPath: destination.path, contents: nil)
    let handle = try FileHandle(forWritingTo: destination)
    defer { try? handle.close() }
    var index: Int64 = 0
    var copied: Int64 = 0
    var last = Date.distantPast
    while copied < reader.size {
        let page = reader.page(index)
        guard !page.isEmpty else { break }
        try handle.write(contentsOf: page)
        copied += Int64(page.count)
        index += 1
        if Date().timeIntervalSince(last) > 0.5 { last = Date(); progress?(copied, reader.size) }
    }
    progress?(copied, reader.size)
}
