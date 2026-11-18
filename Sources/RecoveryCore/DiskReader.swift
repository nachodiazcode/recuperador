import Darwin
import Foundation

public enum ReaderError: Error, CustomStringConvertible {
    case open(String, Int32)
    case size(String)

    public var description: String {
        switch self {
        case let .open(path, err):
            return "No se pudo abrir \(path): \(String(cString: strerror(err)))"
        case let .size(path):
            return "No se pudo determinar el tamaño de \(path)"
        }
    }
}

// _IOR('d', 24, uint32_t) y _IOR('d', 25, uint64_t) de <sys/disk.h>; Swift no importa esas macros.
private let DKIOCGETBLOCKSIZE: UInt = 0x4004_6418
private let DKIOCGETBLOCKCOUNT: UInt = 0x4008_6419

/// Lector de SOLO LECTURA con acceso aleatorio sobre un dispositivo crudo (/dev/rdiskN)
/// o una imagen de disco. Los dispositivos crudos exigen offsets y tamaños alineados al
/// sector, así que todo se lee por páginas alineadas que se guardan en una caché LRU pequeña.
/// Es seguro usarlo desde varios hilos.
public final class DiskReader: @unchecked Sendable {
    public let path: String
    public let size: Int64
    public let sectorSize: Int
    public let pageSize: Int
    public let isDevice: Bool
    /// Sectores que no se pudieron leer (disco dañado); se rellenan con ceros.
    public var badSectors: Int { lock.withLock { _badSectors } }
    /// En discos dañados, ante un error se salta en tramos de 64 KB en vez de reintentar sector
    /// por sector: un disco que falla puede tardar segundos en cada intento.
    public var fastSkip = true

    private let fd: Int32
    private let lock = NSCondition()
    private var _badSectors = 0
    private var cache: [Int64: [UInt8]] = [:]
    private var lru: [Int64] = []
    /// Páginas que algún hilo está leyendo ahora; quien las pida espera en vez de leerlas dos veces.
    private var inFlight = Set<Int64>()
    /// Páginas ya solicitadas por el prefetch pero que todavía no han empezado a leerse.
    /// Evita encolar la misma página varias veces cuando el consumidor avanza más rápido que
    /// la cola de lectura.
    private var prefetchPending = Set<Int64>()
    private var prefetchWorkerActive = false
    private let maxCachedPages = 32
    private let prefetchQueue = DispatchQueue(label: "recuperador.prefetch", qos: .userInitiated)

    public convenience init(path: String, pageSize: Int = 1 << 20) throws {
        let fd = Darwin.open(path, O_RDONLY)
        guard fd >= 0 else { throw ReaderError.open(path, errno) }
        try self.init(fileDescriptor: fd, path: path, pageSize: pageSize)
    }

    /// Toma posesión de `fd` (por ejemplo uno obtenido con autorización de administrador).
    public init(fileDescriptor fd: Int32, path: String, pageSize: Int = 1 << 20) throws {
        self.path = path
        self.fd = fd

        var st = stat()
        guard fstat(fd, &st) == 0 else { close(fd); throw ReaderError.size(path) }
        let type = st.st_mode & S_IFMT
        isDevice = type == S_IFCHR || type == S_IFBLK

        if isDevice {
            var blockSize: UInt32 = 0
            var blockCount: UInt64 = 0
            let ok = withUnsafeMutablePointer(to: &blockSize) { ioctl(fd, DKIOCGETBLOCKSIZE, $0) } == 0
                && withUnsafeMutablePointer(to: &blockCount) { ioctl(fd, DKIOCGETBLOCKCOUNT, $0) } == 0
            guard ok, blockSize > 0 else { close(fd); throw ReaderError.size(path) }
            sectorSize = Int(blockSize)
            size = Int64(blockCount) * Int64(blockSize)
        } else {
            sectorSize = 512
            size = Int64(st.st_size)
        }
        self.pageSize = max(sectorSize, pageSize / sectorSize * sectorSize)
        // No contaminar la caché del sistema con lecturas de cientos de GB.
        _ = fcntl(fd, F_NOCACHE, 1)
    }

    deinit { close(fd) }

    /// Otro lector sobre el mismo disco con su propia caché, para leer en paralelo sin competir.
    public func duplicate() throws -> DiskReader {
        let copy = dup(fd)
        guard copy >= 0 else { throw ReaderError.open(path, errno) }
        return try DiskReader(fileDescriptor: copy, path: path, pageSize: pageSize)
    }

    /// Página alineada número `index` (la última puede ser más corta). La lectura se hace fuera
    /// del candado, así una lectura anticipada no bloquea a quien usa páginas ya en caché.
    public func page(_ index: Int64) -> [UInt8] {
        lock.lock()
        while true {
            if let cached = cache[index] {
                if let i = lru.lastIndex(of: index) { lru.remove(at: i) }
                lru.append(index)
                lock.unlock()
                return cached
            }
            if !inFlight.contains(index) { break }
            lock.wait()
        }
        inFlight.insert(index)
        lock.unlock()

        let start = index * Int64(pageSize)
        let length = Int(max(0, min(Int64(pageSize), size - start)))
        let (data, bad) = readRobust(at: start, count: length)

        lock.lock()
        _badSectors += bad
        cache[index] = data
        lru.append(index)
        if lru.count > maxCachedPages { cache[lru.removeFirst()] = nil }
        inFlight.remove(index)
        lock.broadcast()
        lock.unlock()
        return data
    }

    /// Lee en segundo plano, en orden, las páginas `range` que no estén en caché. Sirve para que
    /// el disco siga leyendo mientras se analiza la página actual.
    public func prefetch(_ range: Range<Int64>) {
        let last = (size - 1) / Int64(pageSize)
        let wanted = range.clamped(to: 0..<(last + 1))
        guard !wanted.isEmpty else { return }
        lock.lock()
        for index in wanted where cache[index] == nil && !inFlight.contains(index) {
            prefetchPending.insert(index)
        }
        let startWorker = !prefetchPending.isEmpty && !prefetchWorkerActive
        if startWorker { prefetchWorkerActive = true }
        lock.unlock()
        guard startWorker else { return }
        prefetchQueue.async { [self] in runPrefetchWorker() }
    }

    /// Mantiene una sola tarea de prefetch viva. Las solicitudes que llegan mientras lee se
    /// acumulan en `prefetchPending`, en vez de crear una tarea GCD por cada página del disco.
    private func runPrefetchWorker() {
        while true {
            lock.lock()
            guard let index = prefetchPending.min() else {
                prefetchWorkerActive = false
                lock.unlock()
                return
            }
            prefetchPending.remove(index)
            let alreadyAvailable = cache[index] != nil || inFlight.contains(index)
            lock.unlock()

            if !alreadyAvailable { _ = page(index) }
        }
    }

    /// Lee `count` bytes desde `offset` (recortado al final del disco).
    public func bytes(at offset: Int64, count: Int) -> [UInt8] {
        guard offset >= 0, offset < size, count > 0 else { return [] }
        let end = min(size, offset + Int64(count))
        var out = [UInt8]()
        out.reserveCapacity(Int(end - offset))
        var pos = offset
        while pos < end {
            let index = pos / Int64(pageSize)
            let pageStart = index * Int64(pageSize)
            let p = page(index)
            let from = Int(pos - pageStart)
            let to = Int(min(Int64(p.count), end - pageStart))
            guard to > from else { break }
            out.append(contentsOf: p[from..<to])
            pos = pageStart + Int64(to)
        }
        return out
    }

    /// Busca `pattern` empezando en `start`; la coincidencia debe comenzar antes de `limit`.
    public func find(_ pattern: [UInt8], from start: Int64, limit: Int64) -> Int64? {
        let end = min(limit, size)
        var pos = max(0, start)
        while pos < end {
            let index = pos / Int64(pageSize)
            let pageStart = index * Int64(pageSize)
            let p = page(index)
            let from = Int(pos - pageStart)
            let hit: Int? = p.withUnsafeBytes { raw in
                guard p.count - from >= pattern.count, let base = raw.baseAddress else { return nil }
                let window = base + from
                guard let m = memmem(window, p.count - from, pattern, pattern.count) else { return nil }
                return from + window.distance(to: UnsafeRawPointer(m))
            }
            if let hit, pageStart + Int64(hit) < end { return pageStart + Int64(hit) }
            if hit != nil { return nil }

            // Coincidencia que cruza el borde entre dos páginas.
            let next = pageStart + Int64(p.count)
            guard next < end, pattern.count > 1 else { return nil }
            let tailStart = max(pos, next - Int64(pattern.count - 1))
            let window = bytes(at: tailStart, count: Int(next - tailStart) + pattern.count - 1)
            if window.count >= pattern.count {
                for i in 0...(window.count - pattern.count) where window[i..<(i + pattern.count)].elementsEqual(pattern) {
                    let found = tailStart + Int64(i)
                    return found < end ? found : nil
                }
            }
            pos = next
        }
        return nil
    }

    /// Copia `length` bytes desde `offset` a un manejador de archivo.
    public func copy(from offset: Int64, length: Int64, to handle: FileHandle) throws {
        var pos = offset
        let end = min(size, offset + length)
        while pos < end {
            let chunk = read(at: pos, count: Int(min(Int64(Self.transferChunk), end - pos)))
            guard !chunk.isEmpty else { break }
            try handle.write(contentsOf: chunk)
            pos += Int64(chunk.count)
        }
    }

    /// Tramo que se pide de una vez al extraer archivos. Leer 4 MB por llamada es bastante más
    /// rápido en un dispositivo crudo que ir página a página por la caché.
    public static let transferChunk = 4 << 20

    /// Lectura para extraer archivos: una sola llamada al disco, sin pasar por la caché de páginas
    /// (así no la ensucia ni compite por el candado). Si el disco da error en ese tramo, cae a la
    /// ruta tolerante que rellena con ceros lo ilegible.
    public func read(at offset: Int64, count: Int) -> [UInt8] {
        guard offset >= 0, offset < size, count > 0 else { return [] }
        return readDirect(at: offset, count: count) ?? bytes(at: offset, count: count)
    }

    /// Como `read`, pero directo a un `Data` sin copias intermedias: para cargar fotos enteras en
    /// memoria. nil si el tramo no empieza en un sector o si el disco da error ahí.
    public func data(at offset: Int64, count: Int) -> Data? {
        let sector = Int64(sectorSize)
        guard offset >= 0, count > 0, offset % sector == 0, offset + Int64(count) <= size else { return nil }
        let padded = Int(min(size - offset, (Int64(count) + sector - 1) / sector * sector))
        guard let buffer = malloc(padded) else { return nil }
        var done = 0
        while done < padded {
            let n = pread(fd, buffer + done, padded - done, offset + Int64(done))
            if n < 0 {
                if errno == EINTR { continue }
                free(buffer)
                return nil
            }
            if n == 0 { break }
            done += n
        }
        guard done >= count else {
            free(buffer)
            return nil
        }
        return Data(bytesNoCopy: buffer, count: count, deallocator: .free)
    }

    /// Lectura directa sin caché (alineada a sector). nil si hubo un error de E/S.
    public func readDirect(at offset: Int64, count: Int) -> [UInt8]? {
        let start = offset / Int64(sectorSize) * Int64(sectorSize)
        let end = min(size, (offset + Int64(count) + Int64(sectorSize) - 1) / Int64(sectorSize) * Int64(sectorSize))
        guard end > start else { return [] }
        var buffer = [UInt8](repeating: 0, count: Int(end - start))
        guard readFully(into: &buffer, range: 0..<buffer.count, at: start) else { return nil }
        let from = Int(offset - start)
        let to = min(buffer.count, from + count)
        if from == 0, to == buffer.count { return buffer }
        return Array(buffer[from..<to])
    }

    /// Lee un rango alineado; si hay errores de E/S reintenta por tramos y rellena con ceros
    /// lo ilegible, para que un disco con sectores dañados no detenga el escaneo.
    private func readRobust(at offset: Int64, count: Int) -> (data: [UInt8], badSectors: Int) {
        var buffer = [UInt8](repeating: 0, count: count)
        if readFully(into: &buffer, range: 0..<count, at: offset) { return (buffer, 0) }
        var bad = 0
        let step = fastSkip ? max(sectorSize, 64 * 1024) : sectorSize
        var i = 0
        while i < count {
            let n = min(step, count - i)
            if !readFully(into: &buffer, range: i..<(i + n), at: offset + Int64(i)) {
                buffer.replaceSubrange(i..<(i + n), with: repeatElement(0, count: n))
                bad += n / sectorSize
            }
            i += n
        }
        return (buffer, bad)
    }

    private func readFully(into buffer: inout [UInt8], range: Range<Int>, at offset: Int64) -> Bool {
        var done = 0
        let want = range.count
        while done < want {
            let n = buffer.withUnsafeMutableBytes { raw in
                pread(fd, raw.baseAddress! + range.lowerBound + done, want - done, offset + Int64(done))
            }
            if n < 0 {
                if errno == EINTR { continue }
                return false
            }
            if n == 0 { return false }
            done += n
        }
        return true
    }
}
