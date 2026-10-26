import Foundation

/// Escribe un archivo .tar (formato POSIX/PAX) en un flujo, sin necesitar espacio en disco:
/// permite mandar un respaldo directo a la nube (`recuperar … | rclone rcat drive:…`).
/// Los nombres largos o con tildes van en cabeceras PAX, así se conservan exactos.
public final class TarWriter {
    private let out: FileHandle
    public private(set) var bytesWritten: Int64 = 0

    public init(_ out: FileHandle) { self.out = out }

    public func addDirectory(_ path: String, modified: Date?) throws {
        try header(path.hasSuffix("/") ? path : path + "/", size: 0, type: "5", mode: 0o755, modified: modified)
    }

    /// Agrega un archivo; `write` debe escribir exactamente `size` bytes con `writeData`.
    public func addFile(_ path: String, size: Int64, modified: Date?,
                        contents: ((Data) throws -> Void) throws -> Void) throws {
        try header(path, size: size, type: "0", mode: 0o644, modified: modified)
        var written: Int64 = 0
        try contents { data in
            try self.write(data)
            written += Int64(data.count)
        }
        // Si la lectura quedó corta (sectores ilegibles), se completa con ceros para no romper el tar.
        if written < size { try write(Data(count: Int(size - written))) }
        try pad(size)
    }

    public func finish() throws {
        try write(Data(count: 1024))
    }

    private func write(_ data: Data) throws {
        try out.write(contentsOf: data)
        bytesWritten += Int64(data.count)
    }

    private func pad(_ size: Int64) throws {
        let rest = Int(size % 512)
        if rest != 0 { try write(Data(count: 512 - rest)) }
    }

    private func header(_ path: String, size: Int64, type: Character, mode: Int, modified: Date?) throws {
        let mtime = Int64((modified ?? Date()).timeIntervalSince1970)
        let utf8 = Array(path.utf8)
        let needsPax = utf8.count > 99 || utf8.contains { $0 >= 0x80 } || size > 0o77777777777
        if needsPax {
            var records = ""
            for (key, value) in [("path", path), ("size", String(size)), ("mtime", String(mtime))] {
                records += paxRecord(key, value)
            }
            let body = Data(records.utf8)
            try write(block(name: "PaxHeader", size: Int64(body.count), type: "x", mode: 0o644, mtime: mtime))
            try write(body)
            try pad(Int64(body.count))
        }
        let shortName = needsPax ? String(decoding: utf8.prefix(99).filter { $0 < 0x80 }, as: UTF8.self) : path
        try write(block(name: shortName, size: min(size, 0o77777777777), type: type, mode: mode, mtime: mtime))
    }

    /// "longitud clave=valor\n", donde la longitud incluye sus propios dígitos.
    private func paxRecord(_ key: String, _ value: String) -> String {
        let body = " \(key)=\(value)\n"
        var length = body.utf8.count + 1
        while String(length).count + body.utf8.count != length { length += 1 }
        return "\(length)\(body)"
    }

    private func block(name: String, size: Int64, type: Character, mode: Int, mtime: Int64) -> Data {
        var b = [UInt8](repeating: 0, count: 512)
        func put(_ s: String, _ at: Int, _ len: Int) {
            for (i, c) in s.utf8.prefix(len).enumerated() { b[at + i] = c }
        }
        func octal(_ v: Int64, _ at: Int, _ len: Int) {
            put(String(String(v, radix: 8).suffix(len - 1)).leftPadded(to: len - 1), at, len - 1)
        }
        put(name, 0, 100)
        octal(Int64(mode), 100, 8)
        octal(0, 108, 8)
        octal(0, 116, 8)
        octal(size, 124, 12)
        octal(mtime, 136, 12)
        put("        ", 148, 8)
        b[156] = type.asciiValue ?? 0x30
        put("ustar", 257, 6)
        put("00", 263, 2)
        let checksum = b.reduce(0) { $0 + Int64($1) }
        put(String(String(checksum, radix: 8)).leftPadded(to: 6) + "\0 ", 148, 8)
        return Data(b)
    }
}

private extension String {
    func leftPadded(to n: Int) -> String { count >= n ? self : String(repeating: "0", count: n - count) + self }
}
