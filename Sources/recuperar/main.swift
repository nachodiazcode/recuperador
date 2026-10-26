import Darwin
import Foundation
import RecoveryCore

let usage = """
recuperar — recuperación de archivos borrados por firmas (file carving)

USO
  sudo recuperar escanear <origen> -o <carpeta> [opciones]
  sudo recuperar clonar <origen> <imagen.img>
  recuperar tipos

ORIGEN
  Un disco crudo (/dev/rdisk4, /dev/rdisk4s1) o una imagen de disco (.img/.dd/.dmg sin comprimir).
  Usa `diskutil list` para ver los discos. Prefiere /dev/rdiskN (mucho más rápido que /dev/diskN).

OPCIONES DE ESCANEO
  -o, --salida <carpeta>   Dónde guardar lo recuperado (¡en OTRO disco!)
  -t, --tipos jpg,png,...  Solo estos tipos (ver `recuperar tipos`)
  --alineacion <bytes>     Cada cuántos bytes buscar firmas (por defecto 512; 1 = exhaustivo y lento)
  --desde <bytes>          Empezar en este offset
  --hasta <bytes>          Terminar en este offset
  --rapido                 Solo archivos borrados con nombre (FAT, exFAT, NTFS), sin escaneo profundo
  --embebidos              También recupera archivos que están dentro de otros
  --solo-listar            No guardar nada, solo mostrar lo que se encontraría
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func human(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

func openReader(_ path: String) -> DiskReader {
    do {
        // Sin sudo, los discos se abren con el diálogo de autorización de macOS (authopen).
        if path.hasPrefix("/dev/") && geteuid() != 0 {
            return try DiskReader(fileDescriptor: PrivilegedOpen.open(path), path: path)
        }
        return try DiskReader(path: path)
    } catch {
        fail("\(error.localizedDescription)")
    }
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { print(usage); exit(0) }
args.removeFirst()

switch command {
case "tipos":
    for sig in Signatures.all {
        print("\(sig.name.padding(toLength: 12, withPad: " ", startingAt: 0)) \(sig.extensions.joined(separator: ", "))")
    }

case "respaldar-hfs":
    guard args.count >= 1 else { fail("uso: recuperar respaldar-hfs <partición HFS+> [-o carpeta]") }
    let reader = openReader(args[0])
    guard let volume = HFSPlusVolume(reader: reader, partitionOffset: 0) else { fail("\(args[0]) no es un volumen HFS+") }
    print("Leyendo el índice del volumen (solo lectura)…")
    var shown = -1
    let catalog = volume.readCatalog(progress: { p in
        let pct = Int(p * 100)
        if pct != shown { shown = pct; print("\r  \(pct)%", terminator: ""); fflush(stdout) }
    })
    print("\r  \(catalog.volumeName): \(catalog.files.count) archivos, \(human(catalog.totalSize))")
    guard let o = args.firstIndex(of: "-o"), o + 1 < args.count else { break }
    let root = URL(fileURLWithPath: args[o + 1]).appendingPathComponent(catalog.volumeName)
    if DiskSafety.isSameDisk(source: args[0], output: root.deletingLastPathComponent()) {
        fail("el respaldo debe ir a un disco distinto")
    }
    let free = (try? root.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
        .volumeAvailableCapacityForImportantUsage ?? 0
    if free < catalog.totalSize { fail("no hay espacio: se necesitan \(human(catalog.totalSize)) y hay \(human(free)) libres") }
    print("Copiando a \(root.path)")
    let began = Date()
    do {
        try HFSPlusBackup.copy(catalog, from: reader, to: root) { p in
            let speed = Double(p.bytes) / max(1, Date().timeIntervalSince(began))
            print(String(format: "\r  %5.1f%%  %d/%d archivos  %@ de %@  %@/s  errores: %d   ",
                         Double(p.bytes) / Double(max(1, p.totalBytes)) * 100, p.done, p.total, human(p.bytes),
                         human(p.totalBytes), human(Int64(speed)), p.failed), terminator: "")
            fflush(stdout)
        }
    } catch { fail("\(error)") }
    print("\nListo. Detalle en \(root.path)/_reporte_respaldo.csv")

case "nube-hfs":
    // recuperar nube-hfs <partición HFS+> <remoto rclone>  → un .tar por carpeta, subido sin pasar por el disco local
    guard args.count >= 2 else { fail("uso: recuperar nube-hfs <partición HFS+> <remoto:ruta> [--solo-listar]") }
    let err = FileHandle.standardError
    func say(_ text: String, newline: Bool = true) { err.write(Data((text + (newline ? "\n" : "")).utf8)) }
    let reader = openReader(args[0])
    guard let volume = HFSPlusVolume(reader: reader, partitionOffset: 0) else { fail("\(args[0]) no es un volumen HFS+") }
    say("Leyendo el índice del volumen (solo lectura)…")
    let catalog = volume.readCatalog()
    say("\(catalog.volumeName): \(catalog.files.count) archivos, \(human(catalog.totalSize))\n")

    // Unidades de subida: cada carpeta principal; las de más de 60 GB se dividen por subcarpeta
    // para que un corte no obligue a repetir 140 GB.
    func unitKey(_ folder: String, depth: Int) -> String {
        let parts = folder.split(separator: "/").map(String.init)
        return parts.isEmpty ? "_archivos sueltos" : parts.prefix(depth).joined(separator: "/")
    }
    var sizes: [String: Int64] = [:]
    for f in catalog.files { sizes[unitKey(f.folder, depth: 1), default: 0] += f.size }
    let big = Set(sizes.filter { $0.value > 60 << 30 }.keys)
    var units: [String: [HFSPlusFile]] = [:]
    for f in catalog.files {
        let top = unitKey(f.folder, depth: 1)
        units[big.contains(top) ? unitKey(f.folder, depth: 2) : top, default: []].append(f)
    }
    let ordered = units.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
    for (name, files) in ordered {
        say("  \(name)  —  \(files.count) archivos, \(human(files.reduce(0) { $0 + $1.size }))  [\(uploadLoose(files) ? "sueltos" : ".tar")]")
    }
    if args.contains("--solo-listar") { break }

    let remote = args[1]
    // Reintentos ante cortes de internet o límites momentáneos de Google.
    let rcloneArgs = ["--drive-chunk-size", "64M", "--retries", "10", "--low-level-retries", "50",
                      "--retries-sleep", "30s", "--drive-pacer-min-sleep", "50ms"]

    /// Carpetas con pocos archivos y grandes (fotos, videos, música) se suben sueltas: así se
    /// pueden ver y reproducir en drive.google.com. Las que tienen miles de archivos chicos
    /// (respaldos de Mac) van en .tar porque sueltas tardarían días.
    func uploadLoose(_ files: [HFSPlusFile]) -> Bool {
        guard !files.isEmpty, files.count <= 6000 else { return false }
        let bytes = files.reduce(0) { $0 + $1.size }
        let media = files.filter { [.photo, .video, .audio, .document].contains(FileCategory(extension: ($0.name as NSString).pathExtension)) }
        return bytes / Int64(files.count) >= 1 << 20 && media.count * 2 >= files.count
    }

    func rcloneRun(_ arguments: [String], retries: Bool = true, input: ((FileHandle) throws -> Void)? = nil) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/rclone")
        p.arguments = (retries ? rcloneArgs : []) + arguments
        p.standardInput = FileHandle.nullDevice
        let output = Pipe()
        p.standardOutput = output
        p.standardError = FileHandle.standardError
        let pipe = Pipe()
        if input != nil { p.standardInput = pipe }
        guard (try? p.run()) != nil else { return (-1, "") }
        if let input {
            try? input(pipe.fileHandleForWriting)
            try? pipe.fileHandleForWriting.close()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    let stateURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".recuperador-nube-\(catalog.volumeName).txt")
    var finished = Set(((try? String(contentsOf: stateURL, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init))
    let began = Date()
    var uploaded: Int64 = 0
    let total = catalog.totalSize

    for (index, (name, files)) in ordered.enumerated() {
        let unitBytes = files.reduce(0) { $0 + $1.size }
        let loose = uploadLoose(files)
        let doneKey = loose ? "sueltos:" + name : name
        if finished.contains(doneKey) { uploaded += unitBytes; say("✓ ya estaba subido: \(name)"); continue }

        if loose {
            say("\n[\(index + 1)/\(ordered.count)] Subiendo \(name) como archivos sueltos (\(files.count) archivos, \(human(unitBytes)))")
            let folderRemote = "\(remote)/\(name)"
            // Lo que ya está en la nube con el tamaño correcto no se vuelve a subir.
            var existing: [String: Int64] = [:]
            let (status, json) = rcloneRun(["lsjson", "-R", "--files-only", folderRemote])
            if status == 0, let list = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] {
                for item in list { if let p = item["Path"] as? String, let s = item["Size"] as? Int64 { existing[p] = s } }
            }
            let prefix = name == "_archivos sueltos" ? "" : name
            var unitDone: Int64 = 0, failed = 0
            var last = Date.distantPast
            // rclone touch espera "2006-01-02T15:04:05" en UTC.
            let stamp = DateFormatter()
            stamp.locale = Locale(identifier: "en_US_POSIX")
            stamp.timeZone = TimeZone(identifier: "UTC")
            stamp.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            for f in files.sorted(by: { ($0.extents.first?.offset ?? .max) < ($1.extents.first?.offset ?? .max) }) {
                let folder = String(f.folder.drop { $0 == "/" })
                let relativeFolder = prefix.isEmpty ? folder : String(folder.dropFirst(min(folder.count, prefix.count)).drop { $0 == "/" })
                let relative = (relativeFolder.isEmpty ? "" : relativeFolder + "/") + (f.name.isEmpty ? "sin_nombre_\(f.id)" : f.name)
                defer {
                    unitDone += f.size
                    if Date().timeIntervalSince(last) > 1 {
                        last = Date()
                        let done = uploaded + unitDone
                        let speed = Double(done) / max(1, Date().timeIntervalSince(began))
                        let eta = speed > 0 ? Double(total - done) / speed : 0
                        say(String(format: "\r  total %5.1f%%  %@ de %@  %@/s  quedan ~%dh %02dm   ",
                                   Double(done) / Double(max(1, total)) * 100, human(done), human(total), human(Int64(speed)),
                                   Int(eta) / 3600, Int(eta) / 60 % 60), newline: false)
                    }
                }
                if existing[relative] == f.size { continue }
                let target = "\(folderRemote)/\(relative)"
                let (code, _) = rcloneRun(["rcat", "--size", String(f.size), target]) { handle in
                    var written: Int64 = 0
                    for e in f.extents {
                        var pos = e.offset
                        while pos < e.offset + e.length {
                            let chunk = reader.bytes(at: pos, count: Int(min(Int64(reader.pageSize), e.offset + e.length - pos)))
                            if chunk.isEmpty { break }
                            try handle.write(contentsOf: Data(chunk))
                            pos += Int64(chunk.count)
                            written += Int64(chunk.count)
                        }
                    }
                    if written < f.size { try handle.write(contentsOf: Data(count: Int(f.size - written))) }
                }
                if code != 0 { failed += 1; say("\n  ✗ no se pudo subir \(relative)"); continue }
                if let m = f.modified { _ = rcloneRun(["touch", "--no-create", "-t", stamp.string(from: m), target], retries: false) }
            }
            guard failed == 0 else {
                fail("\(failed) archivo(s) de \(name) no se subieron. Vuelve a ejecutar el mismo comando: solo se reintentarán esos.")
            }
            uploaded += unitBytes
            finished.insert(doneKey)
            try? finished.sorted().joined(separator: "\n").write(to: stateURL, atomically: true, encoding: .utf8)
            say("\n  ✓ \(name) subido (archivos sueltos)")
            continue
        }
        let tarName = name.replacingOccurrences(of: "/", with: " ▸ ") + ".tar"
        say("\n[\(index + 1)/\(ordered.count)] Subiendo \(tarName) (\(human(unitBytes)))")

        let rclone = Process()
        rclone.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/rclone")
        rclone.arguments = rcloneArgs + ["rcat", "\(remote)/\(tarName)"]
        let pipe = Pipe()
        rclone.standardInput = pipe
        do { try rclone.run() } catch { fail("no se pudo iniciar rclone: \(error)") }
        let tar = TarWriter(pipe.fileHandleForWriting)
        var last = Date.distantPast
        let prefix = name == "_archivos sueltos" ? "" : name

        do {
            var dirs = Set<String>()
            for f in files.sorted(by: { ($0.extents.first?.offset ?? .max) < ($1.extents.first?.offset ?? .max) }) {
                let folder = String(f.folder.drop { $0 == "/" })
                let relative = prefix.isEmpty ? folder : String(folder.dropFirst(min(folder.count, prefix.count)).drop { $0 == "/" })
                let inside = ([prefix.split(separator: "/").last.map(String.init) ?? "", relative].filter { !$0.isEmpty }).joined(separator: "/")
                if !inside.isEmpty, dirs.insert(inside).inserted { try tar.addDirectory(inside, modified: nil) }
                let path = (inside.isEmpty ? "" : inside + "/") + (f.name.isEmpty ? "sin_nombre_\(f.id)" : f.name)
                try tar.addFile(path, size: f.size, modified: f.modified) { emit in
                    for e in f.extents {
                        var pos = e.offset
                        while pos < e.offset + e.length {
                            let chunk = reader.bytes(at: pos, count: Int(min(Int64(reader.pageSize), e.offset + e.length - pos)))
                            if chunk.isEmpty { return }
                            try emit(Data(chunk))
                            pos += Int64(chunk.count)
                        }
                    }
                }
                if Date().timeIntervalSince(last) > 1 {
                    last = Date()
                    let done = uploaded + tar.bytesWritten
                    let speed = Double(done) / max(1, Date().timeIntervalSince(began))
                    let eta = speed > 0 ? Double(total - done) / speed : 0
                    say(String(format: "\r  total %5.1f%%  %@ de %@  %@/s  quedan ~%dh %02dm   ",
                               Double(done) / Double(max(1, total)) * 100, human(done), human(total), human(Int64(speed)),
                               Int(eta) / 3600, Int(eta) / 60 % 60), newline: false)
                }
            }
            try tar.finish()
        } catch {
            say("\n  error escribiendo \(tarName): \(error.localizedDescription)")
        }
        try? pipe.fileHandleForWriting.close()
        rclone.waitUntilExit()
        guard rclone.terminationStatus == 0 else {
            fail("rclone no pudo subir \(tarName). Revisa la conexión y vuelve a ejecutar el mismo comando: continuará desde aquí.")
        }
        uploaded += unitBytes
        finished.insert(name)
        try? finished.sorted().joined(separator: "\n").write(to: stateURL, atomically: true, encoding: .utf8)
        say("\n  ✓ \(tarName) subido")
    }
    say("\n🎉 Respaldo completo en \(remote). Sectores ilegibles: \(reader.badSectors)")

case "clonar":
    guard args.count == 2 else { fail("uso: recuperar clonar <origen> <imagen.img>") }
    let reader = openReader(args[0])
    let destination = URL(fileURLWithPath: args[1])
    if DiskSafety.isSameDisk(source: args[0], output: destination.deletingLastPathComponent()) {
        fail("la imagen debe guardarse en un disco distinto al que se clona")
    }
    print("Clonando \(args[0]) (\(human(reader.size))) → \(destination.path)")
    do {
        try cloneDisk(reader, to: destination) { done, total in
            print(String(format: "\r  %.1f%%  %@ / %@", Double(done) / Double(total) * 100, human(done), human(total)),
                  terminator: "")
            fflush(stdout)
        }
    } catch { fail("\(error)") }
    print("\nListo. Sectores ilegibles (rellenados con ceros): \(reader.badSectors)")

case "escanear":
    var source: String?
    var output: URL?
    var options = CarveOptions()
    var listOnly = false
    var quickOnly = false
    var i = 0
    func value() -> String {
        i += 1
        guard i < args.count else { fail("falta el valor para \(args[i - 1])") }
        return args[i]
    }
    while i < args.count {
        switch args[i] {
        case "-o", "--salida": output = URL(fileURLWithPath: value())
        case "-t", "--tipos":
            let wanted = Set(value().lowercased().split(separator: ",").map(String.init))
            options.signatures = Signatures.all.filter { !wanted.isDisjoint(with: $0.extensions) }
            if options.signatures.isEmpty { fail("ningún tipo coincide con \(wanted.sorted())") }
        case "--alineacion": options.alignment = Int(value()) ?? 512
        case "--desde": options.start = Int64(value()) ?? 0
        case "--hasta": options.end = Int64(value())
        case "--solo-listar": listOnly = true
        case "--rapido": quickOnly = true
        case "--embebidos": options.skipInteriors = false
        case let arg where !arg.hasPrefix("-") && source == nil: source = arg
        default: fail("opción desconocida: \(args[i])\n\n\(usage)")
        }
        i += 1
    }
    guard let source else { fail("falta el origen\n\n\(usage)") }
    guard listOnly || output != nil else { fail("indica la carpeta de salida con -o (o usa --solo-listar)") }

    if let output, DiskSafety.isSameDisk(source: source, output: output) {
        fail("la carpeta de salida está en el MISMO disco que vas a escanear; eso puede sobrescribir lo que quieres recuperar. Usa otro disco.")
    }
    let outputDirectory = listOnly ? nil : output

    let reader = openReader(source)
    print("Escaneando \(source) (\(human(reader.size)), sector \(reader.sectorSize) B)\n")

    var found: [FoundFile] = []
    var seen = Set<Int64>()
    var report: FileHandle?
    if let dir = outputDirectory {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("reporte.csv")
        FileManager.default.createFile(atPath: url.path, contents: Data("archivo,tipo,offset,bytes,origen\n".utf8))
        report = try? FileHandle(forWritingTo: url)
        _ = try? report?.seekToEnd()
    }
    func keep(_ file: FoundFile) {
        guard seen.insert(file.offset).inserted else { return }
        found.append(file)
        guard let dir = outputDirectory else { return }
        let folder = dir.appendingPathComponent(file.ext)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = file.name.map { "\(found.count)_\($0)" } ?? String(format: "f%06d_%012llx.%@", found.count, file.offset, file.ext)
        let url = folder.appendingPathComponent(base)
        do { try Extractor.write(file, from: reader, to: url) } catch { print("\n  no se pudo guardar \(base): \(error)") }
        let origin: String
        switch file.origin {
        case let .fileSystem(fs): origin = fs
        case .carved: origin = file.embedded ? "firma (dentro de otro)" : "firma"
        }
        try? report?.write(contentsOf: Data("\(file.ext)/\(base),\(file.ext),\(file.offset),\(file.size),\(origin)\n".utf8))
    }

    let wanted = Set(options.signatures.flatMap(\.extensions))
    let allocated = FileSystemScanner.scan(reader, onVolume: { v in
        print("  Volumen \(v.name) [\(v.format)]" + (v.namesSupported ? "" : " — sin soporte de nombres, se usará el escaneo profundo"))
    }, onFound: { file in
        if options.signatures.count == Signatures.all.count || wanted.contains(file.ext) { keep(file) }
    })
    print("  Borrados con nombre: \(found.count)\n")

    if !quickOnly {
        options.skip = allocated
        Carver(reader: reader, options: options).run(progress: { p in
            print(String(format: "\r  %5.1f%%  %@ / %@  %@/s  encontrados: %d   ",
                         p.fraction * 100, human(p.scanned), human(p.total), human(Int64(p.bytesPerSecond)), p.found), terminator: "")
            fflush(stdout)
        }, onFound: keep)
        print("\n")
    }
    try? report?.close()

    var byType: [String: (count: Int, bytes: Int64)] = [:]
    for f in found {
        byType[f.ext, default: (0, 0)].count += 1
        byType[f.ext, default: (0, 0)].bytes += f.size
        if listOnly { print(String(format: "  0x%012llx  %10@  %@", f.offset, human(f.size), f.name ?? f.ext)) }
    }
    for (ext, s) in byType.sorted(by: { $0.key < $1.key }) {
        print("  \(ext.padding(toLength: 8, withPad: " ", startingAt: 0)) \(s.count) archivos, \(human(s.bytes))")
    }
    print("\nTotal: \(found.count) archivos." + (listOnly ? "" : " Guardados en \(output!.path)"))
    if reader.badSectors > 0 { print("Sectores ilegibles: \(reader.badSectors)") }

default:
    print(usage)
    exit(command == "-h" || command == "--help" || command == "ayuda" ? 0 : 1)
}
