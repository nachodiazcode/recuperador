import AppKit
import RecoveryCore
import SwiftUI

/// Un archivo encontrado tal como lo muestra la interfaz. Se va completando a medida que se
/// extrae y analiza en segundo plano.
@MainActor
final class Item: ObservableObject, Identifiable {
    let id: Int
    let file: FoundFile
    let category: FileCategory
    let isSystemFile: Bool
    @Published var name: String
    @Published var date: Date?
    @Published var rows: [MetaRow] = []
    @Published var labels: [String] = []
    @Published var health: Int?
    @Published var healthNote = "Todavía no se ha comprobado el contenido."
    @Published var localURL: URL?
    @Published var preparing = false
    /// Cada tarjeta mira solo su propio estado: al mover la selección se redibujan dos tarjetas,
    /// no la galería entera.
    @Published var isSelected = false
    /// Se está copiando del disco a la carpeta temporal (para la vista previa).
    @Published var loading = false
    /// Avance de esa copia (0–1) cuando el archivo es grande.
    @Published var progress: Double?
    /// No se pudo leer del disco.
    @Published var failed = false
    /// Ya pasó por el análisis de contenido (aunque no se haya podido comprobar: `health` nil).
    @Published var analyzed = false

    init(id: Int, file: FoundFile) {
        self.id = id
        self.file = file
        category = file.category
        name = file.name ?? "Archivo \(id).\(file.ext)"
        date = file.modified
        let root = file.folder?.split(separator: "/", maxSplits: 1).first?.lowercased()
        isSystemFile = root == ".spotlight-v100" || root == ".fseventsd"
            || file.name?.lowercased() == ".ds_store"
    }

    var hasOriginalName: Bool { file.name != nil }
    var year: Int? { date.map { Calendar.current.component(.year, from: $0) } }

    var searchText: String {
        ([name, file.ext, file.folder ?? "", category.rawValue, year.map(String.init) ?? ""]
            + labels + rows.map(\.value)).joined(separator: " ").lowercased()
    }

    func apply(_ a: Analysis) {
        date = a.date ?? date
        rows = a.rows
        labels = a.labels
        health = a.verified ? a.health : nil
        healthNote = a.healthNote.trimmingCharacters(in: .whitespaces)
        if file.name == nil, let suggested = a.suggestedName {
            name = "\(suggested).\(file.ext)".replacingOccurrences(of: "/", with: "-")
        }
    }
}

enum Phase: Equatable {
    case idle, opening, quick, deep, finished, cancelled
    case failed(String)

    var isScanning: Bool { self == .opening || self == .quick || self == .deep }
}

enum SortOrder: String, CaseIterable, Identifiable {
    case date = "Fecha", name = "Nombre", size = "Tamaño", health = "Recuperabilidad"
    var id: String { rawValue }
}

enum SidebarFilter: Hashable {
    case all
    case category(FileCategory)
    case named
}

/// Recibe resultados desde el hilo del escaneo; la interfaz los recoge periódicamente para no
/// redibujar miles de veces por segundo.
final class ScanSink: @unchecked Sendable {
    private let lock = NSLock()
    private var files: [FoundFile] = []
    private var fileHead = 0
    private var volumes: [VolumeInfo] = []
    private var progress: CarveProgress?
    private var cancelled = false

    func add(_ f: FoundFile) { lock.withLock { files.append(f) } }
    func add(_ v: VolumeInfo) { lock.withLock { volumes.append(v) } }
    func set(_ p: CarveProgress) { lock.withLock { progress = p } }
    func cancel() { lock.withLock { cancelled = true } }
    var isCancelled: Bool { lock.withLock { cancelled } }

    /// Devuelve un lote pequeño para que un disco con muchos resultados no bloquee el hilo
    /// principal intentando insertar miles de filas en una sola actualización de SwiftUI.
    func drain(maxFiles: Int = 1200) -> ([FoundFile], [VolumeInfo], CarveProgress?) {
        lock.withLock {
            let available = max(0, files.count - fileHead)
            let count = min(maxFiles, available)
            let batch = count == 0 ? [] : Array(files[fileHead..<(fileHead + count)])
            fileHead += count
            if fileHead == files.count {
                files.removeAll(keepingCapacity: false)
                fileHead = 0
            } else if fileHead >= 1024, fileHead * 2 >= files.count {
                files.removeFirst(fileHead)
                fileHead = 0
            }
            let pendingVolumes = volumes
            volumes = []
            return (batch, pendingVolumes, progress)
        }
    }
}

/// Cola de trabajo para extraer y analizar archivos con varios hilos.
actor WorkQueue {
    private var jobs: [(Int, FoundFile)] = []
    private var head = 0
    private var closed = false
    private let capacity = 48

    /// Encola solo una ventana corta. Si el scanner produce resultados más rápido que ImageIO,
    /// Vision o PDFKit, el resto se deja para análisis bajo demanda al abrir el archivo.
    func push(contentsOf newJobs: [(Int, FoundFile)]) -> [Int] {
        guard !newJobs.isEmpty, !closed else { return newJobs.map(\.0) }
        if head == jobs.count {
            jobs.removeAll(keepingCapacity: true)
            head = 0
        } else if head >= 1024, head * 2 >= jobs.count {
            jobs.removeFirst(head)
            head = 0
        }
        let available = max(0, capacity - (jobs.count - head))
        let accepted = min(available, newJobs.count)
        if accepted > 0 { jobs.append(contentsOf: newJobs.prefix(accepted)) }
        return newJobs.dropFirst(accepted).map(\.0)
    }

    func close() {
        closed = true
        if head == jobs.count {
            jobs.removeAll(keepingCapacity: false)
            head = 0
        }
    }

    func next() async -> (Int, FoundFile)? {
        while true {
            if head < jobs.count {
                let job = jobs[head]
                head += 1
                return job
            }
            if closed { return nil }
            try? await Task.sleep(for: .milliseconds(150))
        }
    }
}

/// Lo que cambia muchas veces por segundo al usar la app: la selección y el visor. Va en un
/// objeto aparte para que moverse con las flechas redibuje solo lo que depende de eso, y no la
/// ventana entera (barra de herramientas, barra lateral, galería...).
@MainActor
final class Focus: ObservableObject {
    @Published fileprivate(set) var selection = Set<Int>()
    @Published fileprivate(set) var selectedBytes: Int64 = 0
    @Published var viewerOpen = false
}

/// Avance de una recuperación en curso.
struct RecoverStatus: Equatable {
    var done = 0
    var total = 0
    var failed = 0
    var finished = false
    var folder: URL?
    /// Bytes ya escritos y bytes a escribir: con cientos de miles de archivos de tamaños muy
    /// distintos, el avance real es el de los bytes, no el de la cantidad.
    var bytesDone: Int64 = 0
    var bytesTotal: Int64 = 0
    var started = Date()
    /// Se detuvo a pedido (o porque se llenó el destino) antes de terminar.
    var stopped = false
    var stopReason: String?

    /// Bytes por segundo desde que empezó.
    var speed: Double {
        let elapsed = Date().timeIntervalSince(started)
        return elapsed > 1 ? Double(bytesDone) / elapsed : 0
    }
}

/// Cuántos archivos y cuántos bytes.
struct Tally: Equatable {
    var count = 0
    var bytes: Int64 = 0
    mutating func add(_ size: Int64) { count += 1; bytes += size }
    static func += (a: inout Tally, b: Tally) { a.count += b.count; a.bytes += b.bytes }
}

/// Distintas formas de recuperar los datos escaneados según lo que necesites o el espacio disponible.
enum RecoveryMode: String, CaseIterable, Identifiable, Hashable {
    case all
    case categories
    case named
    case current
    case batches

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "Todo lo escaneado"
        case .categories: return "Por tipo de archivo"
        case .named: return "Con nombre original"
        case .current: return "Vista o selección"
        case .batches: return "Por tandas de GB"
        }
    }

    var symbol: String {
        switch self {
        case .all: return "externaldrive.fill.badge.arrow.down"
        case .categories: return "checklist"
        case .named: return "folder.fill.badge.person.crop"
        case .current: return "line.3.horizontal.decrease.circle.fill"
        case .batches: return "square.split.2x2.fill"
        }
    }

    var subtitle: String {
        switch self {
        case .all: return "Copia todos los archivos encontrados sin borrar el escaneo."
        case .categories: return "Marca Fotos, Videos, Documentos… y mide cuántos GB suma cada uno."
        case .named: return "Solo archivos con su nombre real y carpeta rescatados del índice."
        case .current: return "Recupera lo que filtraste en la galería o los archivos seleccionados."
        case .batches: return "Divide todo en partes de X GB si tu disco destino tiene poco espacio."
        }
    }
}

/// Una parte cuando se divide toda la recuperación en tandas de cierto límite de GB.
struct RecoveryBatch: Equatable, Identifiable {
    let index: Int
    let count: Int
    let bytes: Int64
    let startOffset: Int
    let endOffset: Int
    var id: Int { index }
}

/// Configuración elegida en la ventana «Recuperar datos».
struct EverythingScope: Hashable {
    var mode: RecoveryMode = .all
    var categories: Set<FileCategory> = Set(FileCategory.allCases)
    /// Fotos o miniaturas que estaban dentro de otro archivo (ya vienen dentro de ese archivo).
    var includeEmbedded = false
    /// Archivos cuyos sectores el sistema de archivos ya dio a otro archivo.
    var includeOverwritten = true
    /// Omitir archivos internos de macOS (.DS_Store, Spotlight, fseventsd).
    var excludeSystemFiles = false
    /// Recuperar únicamente archivos verificados con salud alta (≥ 70 %).
    var onlyHealthy = false
    /// En modo `.current`, usar toda la vista filtrada aunque haya archivos seleccionados.
    var useFilteredInsteadOfSelection = false
    /// Límite por tanda en gigabytes (modo `.batches`).
    var batchSizeGB: Int = 64
    var batchIndex: Int = 0
}

/// Medición completa en archivos y bytes/GB para todas las formas de recuperar.
struct EverythingSummary: Equatable {
    var selected = Tally()
    var byCategory: [FileCategory: Tally] = [:]
    var embedded = Tally()
    var overwritten = Tally()
    var systemFiles = Tally()
    var healthy = Tally()
    var named = Tally()
    var currentSelection = Tally()
    var currentFiltered = Tally()
    var allMatchingToggles = Tally()
    var everything = Tally()
    var largest: Int64 = 0
    var batches: [RecoveryBatch] = []
}

/// Espacio en la carpeta o volumen de destino.
struct DestinationInfo: Equatable, Identifiable {
    var id: String { url.path }
    let url: URL
    let name: String
    let free: Int64?
    let capacity: Int64?
    let format: String?
    let isRemovable: Bool
    let isInternal: Bool
    /// FAT32 no acepta archivos de 4 GB o más.
    var isFAT32: Bool {
        guard let f = format?.lowercased() else { return false }
        return f.contains("ms-dos") || f.contains("fat32") || f.contains("fat 32")
    }

    static func read(_ url: URL) -> DestinationInfo {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
            .volumeTotalCapacityKey, .volumeLocalizedFormatDescriptionKey,
            .volumeIsRemovableKey, .volumeIsInternalKey,
        ]
        let v = try? url.resourceValues(forKeys: keys)
        // En discos externos "importantUsage" a veces vuelve 0 o nada: se usa el mayor de los dos.
        let important = v?.volumeAvailableCapacityForImportantUsage ?? 0
        let plain = Int64(v?.volumeAvailableCapacity ?? 0)
        let free = max(important, plain)
        let volName = v?.volumeName ?? url.lastPathComponent
        return DestinationInfo(
            url: url,
            name: volName.isEmpty ? url.path : volName,
            free: v == nil ? nil : free,
            capacity: v?.volumeTotalCapacity.map(Int64.init),
            format: v?.volumeLocalizedFormatDescription,
            isRemovable: v?.volumeIsRemovable ?? false,
            isInternal: v?.volumeIsInternal ?? true
        )
    }

    /// Lista los discos/volúmenes montados actualmente en el Mac con su espacio libre en GB.
    static func mountedVolumes() -> [DestinationInfo] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
            .volumeTotalCapacityKey, .volumeLocalizedFormatDescriptionKey,
            .volumeIsRemovableKey, .volumeIsInternalKey, .volumeIsBrowsableKey, .volumeIsReadOnlyKey,
        ]
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) else { return [] }
        var seenNames = Set<String>()
        var result: [DestinationInfo] = []
        for url in urls {
            let rv = try? url.resourceValues(forKeys: Set(keys))
            if rv?.volumeIsReadOnly == true { continue }
            let info = read(url)
            let dedupKey = "\(info.name)|\(info.capacity ?? 0)"
            if seenNames.insert(dedupKey).inserted {
                result.append(info)
            }
        }
        return result
    }
}

enum Bytes {
    private static let oneGB = 1_000_000_000.0
    private static let twoDecimalFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f
    }()
    private static let oneDecimalFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 1
        f.maximumFractionDigits = 1
        return f
    }()

    static func format(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    /// Siempre expresa el tamaño en gigabytes (GB) decimales, igual que el Finder de macOS,
    /// para saber de inmediato cuántos gigas ocupa la recuperación.
    static func gigabytes(_ b: Int64) -> String {
        if b <= 0 { return "0 GB" }
        let gb = Double(b) / oneGB
        if gb < 0.01 { return "< 0,01 GB" }
        let formatted: String
        if gb < 10 {
            formatted = twoDecimalFormatter.string(from: NSNumber(value: gb)) ?? String(format: "%.2f", gb)
        } else {
            formatted = oneDecimalFormatter.string(from: NSNumber(value: gb)) ?? String(format: "%.1f", gb)
        }
        return "\(formatted) GB"
    }

    /// Muestra siempre los GB y, si es menor a 1 GB o mayor a 1 TB, añade también MB o TB entre paréntesis.
    static func gigabytesDetailed(_ b: Int64) -> String {
        if b <= 0 { return "0 GB" }
        if b < 1_000_000_000 || b >= 1_000_000_000_000 {
            return "\(gigabytes(b)) (\(format(b)))"
        }
        return gigabytes(b)
    }
}

/// Lo que se actualiza solo durante un escaneo o una recuperación.
@MainActor
final class LiveStatus: ObservableObject {
    @Published var progress: CarveProgress?
    @Published var badSectors = 0
    @Published var recover: RecoverStatus?
}

@MainActor
final class AppModel: ObservableObject {
    @Published var disks: [DiskInfo] = []
    @Published var phase: Phase = .idle
    @Published var sourceName = ""
    @Published var sourceSymbol = "externaldrive.fill"
    @Published var sourceDisk: DiskInfo?
    let focus = Focus()
    let live = LiveStatus()
    var progress: CarveProgress? {
        get { live.progress }
        set { live.progress = newValue }
    }
    @Published var quickElapsed: TimeInterval?
    @Published var volumes: [VolumeInfo] = []
    @Published private(set) var items: [Item] = []
    @Published private(set) var totalBytes: Int64 = 0
    @Published private(set) var revision = 0
    @Published private(set) var savedScan: SavedScanHeader?

    /// Qué buscar, elegido antes de escanear (tipos, años, tamaño mínimo).
    @Published var scanFilter = ScanFilter() { didSet { filtersChanged() } }
    @Published var filter: SidebarFilter = .all { didSet { filtersChanged() } }
    @Published var year: Int? { didSet { filtersChanged() } }
    @Published var search = "" { didSet { filtersChanged() } }
    @Published var onlyRecoverable = false { didSet { filtersChanged() } }
    @Published var hideEmbedded = true { didSet { filtersChanged() } }
    @Published var hideOverwritten = false { didSet { filtersChanged() } }
    @Published var hideSystemFiles = false { didSet { filtersChanged() } }
    @Published var sort: SortOrder = .date { didSet { filterGeneration += 1 } }
    /// Visor grande (barra espaciadora o doble clic) sobre el archivo seleccionado.
    var viewerOpen: Bool {
        get { focus.viewerOpen }
        set {
            guard focus.viewerOpen != newValue else { return }
            Crossfade.next(0.18)
            focus.viewerOpen = newValue
        }
    }
    var badSectors: Int {
        get { live.badSectors }
        set { if live.badSectors != newValue { live.badSectors = newValue } }
    }
    private(set) var selection: Set<Int> {
        get { focus.selection }
        set {
            let old = focus.selection
            guard newValue != old else { return }
            if newValue.isEmpty {
                for id in old { byId[id]?.isSelected = false }
                focus.selectedBytes = 0
            } else {
                var delta: Int64 = 0
                for id in old.subtracting(newValue) {
                    if let item = byId[id] { item.isSelected = false; delta -= item.file.size }
                }
                for id in newValue.subtracting(old) {
                    if let item = byId[id] { item.isSelected = true; delta += item.file.size }
                }
                focus.selectedBytes = max(0, focus.selectedBytes + delta)
            }
            previousSelectionChange = lastSelectionChange
            lastSelectionChange = Date()
            focus.selection = newValue
        }
    }
    @Published var alert: String?
    /// Hoja de «Recuperar datos» con todas las modalidades y medición en GB.
    @Published var showRecoverAll = false
    @Published var initialRecoverMode: RecoveryMode = .all
    @Published var completedBatches: Set<String> = []
    private var everythingCache: (revision: Int, filterGen: Int, selCount: Int, selBytes: Int64,
                                  scope: EverythingScope, value: EverythingSummary)?
    private var recoverState: RecoverState?
    private var lastSnapshot = Date.distantPast
    private var snapshotTask: Task<Void, Never>?

    private var byId: [Int: Item] = [:]
    /// Filtrar y ordenar decenas de miles de archivos en cada redibujo trababa la interfaz:
    /// el resultado se guarda y solo se recalcula cuando cambian los datos o los filtros.
    private var filterGeneration = 0
    private var filteredCache: (revision: Int, generation: Int, items: [Item], bytes: Int64)?
    private var summaryCache: (revision: Int, generation: Int,
                               value: (counts: [SidebarFilter: Int], bytes: [SidebarFilter: Int64],
                                       years: [(year: Int, count: Int)], hasEmbedded: Bool))?
    private var pendingCache: (revision: Int, generation: Int, count: Int)?
    private var extractions: [Int: Task<URL?, Never>] = [:]
    private var lastSelectionChange = Date.distantPast
    private var previousSelectionChange = Date.distantPast
    /// Análisis pedidos al seleccionar. Pocos a la vez: Vision y AVFoundation consumen mucha memoria.
    private let onDemand = Limiter(2)

    /// La selección está cambiando muy seguido (flecha mantenida): conviene esperar a que se
    /// detenga antes de copiar archivos del disco.
    var isBrowsingFast: Bool { lastSelectionChange.timeIntervalSince(previousSelectionChange) < 0.25 }
    private var seenOffsets = Set<Int64>()
    private var sink = ScanSink()
    private var queue = WorkQueue()
    private var reader: DiskReader?
    private var workReader: DiskReader?
    private var timer: Timer?
    private var dirty = false
    private var scanStarted = Date()
    private let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Recuperador", isDirectory: true)
    private var session: URL
    private var diskWatcher: DiskWatcher?
    private var refreshTask: Task<Void, Never>?

    /// Archivos más grandes que esto se extraen solo cuando se piden (videos largos, imágenes de disco...).
    private var memoryConstrained: Bool {
        ProcessInfo.processInfo.physicalMemory <= 12 * 1024 * 1024 * 1024
    }

    private var analysisWorkerCount: Int { memoryConstrained ? 1 : 2 }
    private var eagerLimit: Int64 { memoryConstrained ? 64 * 1024 * 1024 : 150 * 1024 * 1024 }
    /// Hasta este tamaño la vista previa se carga sola al seleccionar; lo más grande espera un clic.
    let autoPreviewLimit: Int64 = 1 << 30

    private func filtersChanged() {
        filterGeneration += 1
        pruneSelection()
    }

    func resetFilters() {
        filter = .all
        year = nil
        search = ""
        onlyRecoverable = false
        hideSystemFiles = false
        hideOverwritten = false
    }

    init() {
        session = cacheRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        cleanStaleCacheSessions()
        savedScan = SavedScanStore.readHeader()
        refreshDisks()
        // Al conectar un disco llegan varios avisos seguidos (disco + particiones): se agrupan.
        diskWatcher = DiskWatcher { [weak self] in
            Task { @MainActor in
                self?.refreshTask?.cancel()
                self?.refreshTask = Task {
                    try? await Task.sleep(for: .milliseconds(800))
                    if !Task.isCancelled { self?.refreshDisks() }
                }
            }
        }
    }

    /// Borra solo sesiones temporales viejas (>24 h) en vez de la carpeta raíz entera, para no
    /// pisar la caché de otra instancia de Recuperador que esté abierta al mismo tiempo.
    private func cleanStaleCacheSessions() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-86_400)
        for url in entries {
            let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if mod < cutoff { try? fm.removeItem(at: url) }
        }
    }

    // MARK: Discos

    func refreshDisks() {
        Task.detached {
            let disks = DiskLister.list()
            await MainActor.run { self.disks = disks }
        }
    }

    func openImage(deep: Bool) {
        let panel = NSOpenPanel()
        panel.message = "Elige una imagen de disco (.img, .dd, .dmg sin comprimir, .iso)"
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openImage(at: url, deep: deep)
    }

    func openImage(at url: URL, deep: Bool) {
        do {
            let reader = try DiskReader(path: url.path)
            start(reader: reader, name: url.lastPathComponent, symbol: "opticaldiscdrive.fill", disk: nil, deep: deep)
        } catch {
            alert = "\(error)"
            Signals.failed("\(error)")
        }
    }

    func scan(_ disk: DiskInfo, deep: Bool) {
        phase = .opening
        sourceName = disk.name
        sourceSymbol = disk.symbol
        Task.detached {
            do {
                let fd = try PrivilegedOpen.open(disk.devicePath)
                let reader = try DiskReader(fileDescriptor: fd, path: disk.devicePath)
                await MainActor.run { self.start(reader: reader, name: disk.name, symbol: disk.symbol, disk: disk, deep: deep) }
            } catch {
                await MainActor.run {
                    self.phase = .idle
                    self.alert = error.localizedDescription
                    Signals.failed(error.localizedDescription)
                }
            }
        }
    }

    // MARK: Escaneo

    private func start(reader: DiskReader, name: String, symbol: String, disk: DiskInfo?, deep: Bool) {
        reset(keepPhase: true)
        self.reader = reader
        workReader = try? reader.duplicate()
        ThumbnailStore.shared.reset(reader: workReader, model: self)
        sourceName = name
        sourceSymbol = symbol
        sourceDisk = disk
        phase = .quick
        Signals.started()
        let wanted = scanFilter
        if wanted.includeEmbedded { hideEmbedded = false }
        scanStarted = Date()
        try? FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)

        let sink = self.sink
        // La lista no necesita redibujarse varias veces por segundo. Un intervalo más relajado
        // evita que SwiftUI compita con el scanner por el hilo principal.
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        let signatures = wanted.signatures
        Task.detached(priority: .userInitiated) {
            let allocated = FileSystemScanner.scan(reader, isCancelled: { sink.isCancelled },
                                                   onVolume: sink.add, onFound: sink.add)
            await MainActor.run {
                self.quickElapsed = Date().timeIntervalSince(self.scanStarted)
                if deep && !sink.isCancelled { self.phase = .deep }
            }
            if deep && !sink.isCancelled && !signatures.isEmpty {
                var options = CarveOptions()
                options.signatures = signatures
                options.minSize = max(128, wanted.minSize)
                options.skipInteriors = !wanted.includeEmbedded
                options.skip = allocated
                Carver(reader: reader, options: options).run(isCancelled: { sink.isCancelled },
                                                             progress: sink.set, onFound: sink.add,
                                                             collectResults: false)
            }
            await MainActor.run {
                self.tick()
                self.timer?.invalidate()
                let cancelled = sink.isCancelled
                self.phase = cancelled ? .cancelled : .finished
                self.persistScan(finished: !cancelled, force: true)
                // No competir con el lector secuencial por el mismo disco. El análisis empieza
                // cuando ya terminó el carving, conservando la fluidez sin ralentizar el scan.
                if !cancelled { self.startAnalysisWorkers() }
                let count = self.items.count
                let source = self.sourceName
                if cancelled {
                    Signals.stopped(count: count, source: source)
                } else {
                    Signals.finished(count: count, source: source)
                }
            }
        }
    }

    func stop() {
        sink.cancel()
        let queue = self.queue
        Task { await queue.close() }
    }

    func newScan() {
        reset(keepPhase: false)
        savedScan = SavedScanStore.readHeader()
        refreshDisks()
    }

    func discardSavedScan() {
        SavedScanStore.clear()
        savedScan = nil
    }

    /// Reabre el disco o la imagen en modo solo lectura y restaura los resultados guardados sin
    /// volver a recorrer el disco entero.
    func resumeSavedScan() {
        guard let header = savedScan else { return }
        phase = .opening
        sourceName = header.sourceName
        sourceSymbol = header.sourceSymbol
        let matchedDisk = header.diskID.flatMap { id in disks.first { $0.id == id } }
        Task.detached(priority: .userInitiated) {
            do {
                let reader: DiskReader
                if header.isDevice {
                    let fd = try PrivilegedOpen.open(header.readerPath)
                    reader = try DiskReader(fileDescriptor: fd, path: header.readerPath)
                } else {
                    reader = try DiskReader(path: header.readerPath)
                }
                guard reader.size == header.diskSize else {
                    throw NSError(domain: "Recuperador", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "El tamaño de \(header.sourceName) (\(Bytes.format(reader.size))) no coincide con el del escaneo guardado (\(Bytes.format(header.diskSize))). Verifica que sea el mismo disco."
                    ])
                }
                guard let (_, files) = SavedScanStore.load() else {
                    throw NSError(domain: "Recuperador", code: 2, userInfo: [
                        NSLocalizedDescriptionKey: "No se pudo leer el archivo del escaneo guardado."
                    ])
                }
                await MainActor.run {
                    self.restore(reader: reader, header: header, disk: matchedDisk, files: files)
                }
            } catch {
                await MainActor.run {
                    self.phase = .idle
                    self.alert = error.localizedDescription
                    Signals.failed(error.localizedDescription)
                }
            }
        }
    }

    private func restore(reader: DiskReader, header: SavedScanHeader, disk: DiskInfo?, files: [FoundFile]) {
        reset(keepPhase: true)
        self.reader = reader
        workReader = try? reader.duplicate()
        ThumbnailStore.shared.reset(reader: workReader, model: self)
        sourceName = header.sourceName
        sourceSymbol = header.sourceSymbol
        sourceDisk = disk
        volumes = header.volumes
        badSectors = header.badSectors
        try? FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)

        var restored: [Item] = []
        var restoredJobs: [(Int, FoundFile)] = []
        restored.reserveCapacity(files.count)
        var bytes: Int64 = 0
        for f in files where seenOffsets.insert(f.offset).inserted {
            if f.embedded { hideEmbedded = false }
            let item = Item(id: restored.count + 1, file: f)
            let automatic = analyzesItself(f)
            if !automatic { item.healthNote = "Archivo grande: se analiza al seleccionarlo." }
            restored.append(item)
            byId[item.id] = item
            bytes += f.size
            if automatic && restoredJobs.count < 48 { restoredJobs.append((item.id, f)) }
        }
        items = restored
        totalBytes = bytes
        phase = header.finished ? .finished : .cancelled
        revision += 1
        if !restoredJobs.isEmpty {
            let queue = self.queue
            Task { _ = await queue.push(contentsOf: restoredJobs) }
            startAnalysisWorkers()
        }
    }

    private func persistScan(finished: Bool, force: Bool = false) {
        guard !items.isEmpty, let reader else { return }
        let now = Date()
        if !force, now.timeIntervalSince(lastSnapshot) < 45 { return }
        lastSnapshot = now
        let header = SavedScanHeader(
            sourceName: sourceName,
            sourceSymbol: sourceSymbol,
            readerPath: reader.path,
            isDevice: reader.isDevice,
            diskID: sourceDisk?.id,
            diskSize: reader.size,
            fileCount: items.count,
            totalBytes: totalBytes,
            badSectors: badSectors,
            finished: finished,
            savedAt: now,
            volumes: volumes
        )
        let files = items.map(\.file)
        savedScan = header
        snapshotTask?.cancel()
        snapshotTask = Task.detached(priority: .utility) {
            SavedScanStore.save(header: header, files: files)
        }
    }

    private func reset(keepPhase: Bool) {
        sink.cancel()
        Task { [queue] in await queue.close() }
        timer?.invalidate()
        sink = ScanSink()
        queue = WorkQueue()
        items = []
        totalBytes = 0
        byId = [:]
        seenOffsets = []
        selection = []
        volumes = []
        progress = nil
        badSectors = 0
        quickElapsed = nil
        filter = .all
        year = nil
        search = ""
        reader = nil
        workReader = nil
        viewerOpen = false
        extractions = [:]
        filteredCache = nil
        summaryCache = nil
        pendingCache = nil
        everythingCache = nil
        completedBatches = []
        showRecoverAll = false
        lastSnapshot = .distantPast
        ThumbnailStore.shared.reset(reader: nil, model: self)
        try? FileManager.default.removeItem(at: session)
        session = cacheRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        if !keepPhase { phase = .idle }
    }

    private func tick() {
        let (files, vols, p) = sink.drain()
        // Asignar aunque no haya nada nuevo avisaba a toda la interfaz dos veces por segundo.
        if !vols.isEmpty { volumes += vols }
        if let p, p.scanned != progress?.scanned || progress == nil { progress = p }
        badSectors = reader?.badSectors ?? 0
        var added: [Item] = []
        var addedJobs: [(Int, FoundFile)] = []
        var addedBytes: Int64 = 0
        added.reserveCapacity(files.count)
        addedJobs.reserveCapacity(files.count)
        // El conjunto de extensiones se arma una vez por lote, no una vez por archivo.
        let wanted = files.isEmpty ? [] : scanFilter.extensions
        let acceptsUnknown = wanted.contains("*")
        for f in files where (wanted.contains(f.ext) || (acceptsUnknown && !TypeCatalog.knownExtensions.contains(f.ext)))
            && f.size >= scanFilter.minSize && seenOffsets.insert(f.offset).inserted {
            let item = Item(id: items.count + added.count + 1, file: f)
            let automatic = analyzesItself(f)
            if !automatic { item.healthNote = "Archivo grande: se analiza al seleccionarlo." }
            added.append(item)
            addedBytes += f.size
            byId[item.id] = item
            if automatic { addedJobs.append((item.id, f)) }
        }
        if !added.isEmpty {
            items += added
            totalBytes += addedBytes
            dirty = true
            persistScan(finished: false)
        }
        if !addedJobs.isEmpty {
            let queue = self.queue
            Task { [weak self] in
                let deferred = await queue.push(contentsOf: addedJobs)
                guard !deferred.isEmpty, let self else { return }
                for id in deferred { self.byId[id]?.healthNote = "Análisis diferido: selecciónalo para revisarlo." }
                self.dirty = true
            }
        }
        if dirty {
            dirty = false
            revision += 1
        }
    }

    private func startWorker() {
        let queue = self.queue, sink = self.sink
        Task(priority: .utility) { [weak self] in
            while let (id, _) = await queue.next(), !sink.isCancelled {
                guard let item = self?.byId[id] else { continue }
                await self?.analyze(item)
            }
        }
    }

    /// Vision, ImageIO, Quick Look y PDFKit pueden usar bastante memoria. En equipos con
    /// 8–12 GB, un único analizador mantiene la app usable; en equipos grandes permitimos dos.
    private func startAnalysisWorkers() {
        for _ in 0..<analysisWorkerCount { startWorker() }
    }

    /// Copia el archivo del disco a la carpeta temporal (una sola vez, aunque lo pidan a la vez
    /// la miniatura, la vista previa y el análisis) y devuelve dónde quedó.
    func extract(_ item: Item) async -> URL? {
        if let url = item.localURL { return url }
        if let running = extractions[item.id] { return await running.value }
        guard let reader = workReader, byId[item.id] === item else { return nil }
        let file = item.file, total = file.size
        let url = session.appendingPathComponent("\(item.id).\(file.ext)")
        let task = Task.detached(priority: .userInitiated) { () -> URL? in
            var reported = 0.0
            do {
                try Extractor.write(file, from: reader, to: url) { done in
                    guard total > 32 << 20 else { return }
                    let fraction = Double(done) / Double(total)
                    guard fraction - reported >= 0.02 else { return }
                    reported = fraction
                    Task { @MainActor in if item.localURL == nil { item.progress = fraction } }
                }
                return url
            } catch {
                try? FileManager.default.removeItem(at: url)
                return nil
            }
        }
        extractions[item.id] = task
        item.loading = true
        item.failed = false
        let result = await task.value
        guard byId[item.id] === item else { return nil }
        extractions[item.id] = nil
        item.loading = false
        item.progress = nil
        item.failed = result == nil
        if item.localURL == nil { item.localURL = result }
        return item.localURL
    }

    /// ¿Se puede leer directo del disco, sin copiarlo antes? (videos que AVFoundation entiende).
    func canStream(_ file: FoundFile) -> Bool {
        file.category == .video && DiskAsset.playable.contains(file.ext)
    }

    /// Lo que se analiza solo, sin esperar a que se seleccione. Los videos entran aunque pesen
    /// varios GB: se analizan leyendo solo la cabecera y un par de fotogramas.
    private func analyzesItself(_ file: FoundFile) -> Bool {
        file.size <= eagerLimit || canStream(file)
    }

    /// Un video servido directo desde el disco, para reproducirlo o analizarlo sin copiarlo.
    func streamingAsset(for item: Item) -> DiskAsset? {
        guard let reader = workReader, byId[item.id] === item, canStream(item.file) else { return nil }
        return DiskAsset(file: item.file, reader: reader)
    }

    /// Abre el archivo con la app que macOS tenga asignada (copiándolo antes si hace falta).
    func openExternally(_ item: Item) {
        Task {
            if let url = await extract(item) { NSWorkspace.shared.open(url) }
        }
    }

    /// Extrae (si hace falta) y analiza el contenido: metadatos, etiquetas y recuperabilidad.
    func analyze(_ item: Item) async {
        guard !item.analyzed, !item.preparing else { return }
        item.preparing = true
        let file = item.file
        let analysis: Analysis
        if item.localURL == nil, let reader = workReader, let source = streamingAsset(for: item) {
            // Video: se analiza directo del disco. Copiarlo entero solo para leer su duración y
            // dos fotogramas era lo más lento (y lo que más disco temporal ocupaba).
            let header = await DiskWork.run { Extractor.read(file, from: reader, at: 0, count: 32) }
            analysis = await Analyzer.analyze(streaming: source.asset, file: file, header: header)
            source.close()
        } else {
            let url = await extract(item)
            guard byId[item.id] === item else { return }
            guard let url else {
                item.preparing = false
                item.healthNote = "No se pudo preparar el archivo."
                return
            }
            analysis = await Analyzer.analyze(url: url, file: file)
        }
        item.preparing = false
        guard byId[item.id] === item else { return }
        item.analyzed = true
        applyAnalysis(analysis, to: item)
    }

    /// Vista previa y análisis bajo demanda al seleccionar un archivo. Primero la copia (es lo que
    /// necesita la vista previa) y después el análisis, que es lo caro.
    func prepare(_ item: Item) {
        Task {
            // Los videos se reproducen y analizan directo del disco: no hay nada que copiar.
            if !canStream(item.file) {
                guard await extract(item) != nil else {
                    if byId[item.id] === item { item.healthNote = "No se pudo preparar el archivo." }
                    return
                }
            }
            await onDemand.acquire()
            // Si mientras esperaba turno ya se pasó a otro archivo, no vale la pena analizarlo:
            // se hará cuando se vuelva a seleccionar.
            if byId[item.id] === item, selection.contains(item.id) { await analyze(item) }
            await onDemand.release()
        }
    }

    // MARK: Filtros

    var smart: SmartQuery { SmartQuery.parse(search) }

    private func applyAnalysis(_ analysis: Analysis, to item: Item) {
        guard byId[item.id] === item else { return }
        let before = (date: item.date, name: item.name, health: item.health)
        item.apply(analysis)
        let query = smart
        if selection.contains(item.id), !matchesFilters(item, query: query) {
            selection.remove(item.id)
        }
        // La tarjeta se actualiza sola (observa su archivo). La lista entera solo se recalcula si
        // cambió algo que mueve su orden, sus filtros o los contadores de la barra lateral.
        var affectsList = item.date != before.date || scanFilter.hasDateRange || !query.isEmpty
        if item.name != before.name, sort == .name { affectsList = true }
        if item.health != before.health, sort == .health || onlyRecoverable { affectsList = true }
        if affectsList { dirty = true }
    }

    /// ¿Entra en el rango de años elegido antes de escanear? Los archivos sin fecha aún se están
    /// analizando (la fecha sale del EXIF o del video), así que esperan ocultos hasta saberla.
    private func inScanRange(_ item: Item) -> Bool {
        guard scanFilter.hasDateRange else { return true }
        if let year = item.year { return scanFilter.allows(year: year) }
        let analyzed = item.analyzed || !analyzesItself(item.file)
        return analyzed && scanFilter.includeUndated
    }

    /// Archivos encontrados que todavía esperan su análisis para saber si entran en el rango de fechas.
    var pendingCount: Int {
        guard scanFilter.hasDateRange else { return 0 }
        if let c = pendingCache, c.revision == revision, c.generation == filterGeneration { return c.count }
        let count = items.filter { $0.year == nil && !$0.analyzed && analyzesItself($0.file) }.count
        pendingCache = (revision, filterGeneration, count)
        return count
    }

    var filtered: [Item] {
        if let c = filteredCache, c.revision == revision, c.generation == filterGeneration { return c.items }
        let result = computeFiltered()
        let bytes = result.reduce(Int64(0)) { $0 + $1.file.size }
        filteredCache = (revision, filterGeneration, result, bytes)
        return result
    }

    var filteredBytes: Int64 {
        if let c = filteredCache, c.revision == revision, c.generation == filterGeneration { return c.bytes }
        _ = filtered
        return filteredCache?.bytes ?? 0
    }

    private func computeFiltered() -> [Item] {
        let query = smart
        let list = items.filter { matchesFilters($0, query: query) }
        let order: SortOrder
        var ascendingDate = false
        switch query.order {
        case .oldest: order = .date; ascendingDate = true
        case .newest: order = .date
        case .largest, .smallest: order = .size
        case nil: order = sort
        }
        switch order {
        case .date:
            // Las fechas se leen una vez: comparar propiedades publicadas dentro del sort es caro.
            let missing: Date = ascendingDate ? .distantFuture : .distantPast
            let keyed = list.map { (item: $0, date: $0.date ?? missing) }
            return keyed.sorted { ascendingDate ? $0.date < $1.date : $0.date > $1.date }.map(\.item)
        case .name: return list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .size:
            return query.order == .smallest ? list.sorted { $0.file.size < $1.file.size } : list.sorted { $0.file.size > $1.file.size }
        case .health:
            let keyed = list.map { (item: $0, health: $0.health ?? -1) }
            return keyed.sorted { $0.health > $1.health }.map(\.item)
        }
    }

    private func matchesFilters(_ item: Item, query: SmartQuery) -> Bool {
        switch filter {
        case .all: break
        case let .category(c): if item.category != c { return false }
        case .named: if !item.hasOriginalName { return false }
        }
        if onlyRecoverable, (item.health ?? 0) < 70 { return false }
        if hideEmbedded, item.file.embedded { return false }
        if hideOverwritten, item.file.likelyOverwritten { return false }
        if hideSystemFiles, item.isSystemFile { return false }
        if let year, item.year != year { return false }
        return inScanRange(item) && query.matches(item)
    }

    var hasVisibleResults: Bool {
        !filtered.isEmpty
    }

    var sidebarSummary: (counts: [SidebarFilter: Int], bytes: [SidebarFilter: Int64],
                         years: [(year: Int, count: Int)], hasEmbedded: Bool) {
        if let c = summaryCache, c.revision == revision, c.generation == filterGeneration { return c.value }
        let value = computeSummary()
        summaryCache = (revision, filterGeneration, value)
        return value
    }

    private func computeSummary() -> (counts: [SidebarFilter: Int], bytes: [SidebarFilter: Int64],
                                      years: [(year: Int, count: Int)], hasEmbedded: Bool) {
        var counts: [SidebarFilter: Int] = [:]
        var bytes: [SidebarFilter: Int64] = [:]
        var years: [Int: Int] = [:]
        var hasEmbedded = false
        for item in items {
            hasEmbedded = hasEmbedded || item.file.embedded
            guard inScanRange(item) else { continue }
            let size = item.file.size
            counts[.all, default: 0] += 1
            bytes[.all, default: 0] += size
            counts[.category(item.category), default: 0] += 1
            bytes[.category(item.category), default: 0] += size
            if item.hasOriginalName {
                counts[.named, default: 0] += 1
                bytes[.named, default: 0] += size
            }
            if let year = item.year { years[year, default: 0] += 1 }
        }
        return (counts, bytes, years.sorted { $0.key > $1.key }.map { ($0.key, $0.value) }, hasEmbedded)
    }

    private func passesScopeSwitches(_ item: Item, scope: EverythingScope) -> Bool {
        if !scope.includeEmbedded, item.file.embedded { return false }
        if !scope.includeOverwritten, item.file.likelyOverwritten { return false }
        if scope.excludeSystemFiles, item.isSystemFile { return false }
        if scope.onlyHealthy, (item.health ?? 0) < 70 { return false }
        return true
    }

    /// Mide todo lo escaneado y calcula el peso exacto en bytes/GB para cada modalidad de recuperación.
    func everythingSummary(for scope: EverythingScope = EverythingScope()) -> EverythingSummary {
        let selCount = selection.count
        let selBytes = focus.selectedBytes
        if let c = everythingCache,
           c.revision == revision,
           c.filterGen == filterGeneration,
           c.selCount == selCount,
           c.selBytes == selBytes,
           c.scope == scope {
            return c.value
        }
        var s = EverythingSummary()
        let batchLimitBytes = max(1, Int64(scope.batchSizeGB)) * 1_000_000_000
        var baseCount = 0
        var curBatchStart = 0
        var curBatchCount = 0
        var curBatchBytes: Int64 = 0
        var curBatchLargest: Int64 = 0
        var batchLargests: [Int64] = []

        var largestAll: Int64 = 0
        var largestCats: Int64 = 0
        var largestNamed: Int64 = 0

        for item in items {
            let f = item.file
            let size = f.size
            s.everything.add(size)
            if f.embedded { s.embedded.add(size) }
            if f.likelyOverwritten { s.overwritten.add(size) }
            if item.isSystemFile { s.systemFiles.add(size) }
            if (item.health ?? 0) >= 70 { s.healthy.add(size) }

            guard passesScopeSwitches(item, scope: scope) else { continue }
            s.allMatchingToggles.add(size)
            if size > largestAll { largestAll = size }

            s.byCategory[item.category, default: Tally()].add(size)
            if scope.categories.contains(item.category), size > largestCats {
                largestCats = size
            }
            if item.hasOriginalName {
                s.named.add(size)
                if size > largestNamed { largestNamed = size }
            }

            if curBatchCount > 0, curBatchBytes + size > batchLimitBytes {
                s.batches.append(RecoveryBatch(
                    index: s.batches.count, count: curBatchCount, bytes: curBatchBytes,
                    startOffset: curBatchStart, endOffset: baseCount
                ))
                batchLargests.append(curBatchLargest)
                curBatchStart = baseCount
                curBatchCount = 0
                curBatchBytes = 0
                curBatchLargest = 0
            }
            curBatchCount += 1
            curBatchBytes += size
            if size > curBatchLargest { curBatchLargest = size }
            baseCount += 1
        }
        if curBatchCount > 0 {
            s.batches.append(RecoveryBatch(
                index: s.batches.count, count: curBatchCount, bytes: curBatchBytes,
                startOffset: curBatchStart, endOffset: baseCount
            ))
            batchLargests.append(curBatchLargest)
        }

        s.currentSelection = Tally(count: selCount, bytes: selBytes)
        let filt = filtered
        s.currentFiltered = Tally(count: filt.count, bytes: filteredBytes)

        switch scope.mode {
        case .all:
            s.selected = s.allMatchingToggles
            s.largest = largestAll
        case .categories:
            var t = Tally()
            for cat in scope.categories {
                if let catTally = s.byCategory[cat] { t += catTally }
            }
            s.selected = t
            s.largest = largestCats
        case .named:
            s.selected = s.named
            s.largest = largestNamed
        case .current:
            if !selection.isEmpty && !scope.useFilteredInsteadOfSelection {
                s.selected = s.currentSelection
                s.largest = selectedItems.reduce(Int64(0)) { max($0, $1.file.size) }
            } else {
                s.selected = s.currentFiltered
                s.largest = filt.reduce(Int64(0)) { max($0, $1.file.size) }
            }
        case .batches:
            let idx = min(max(0, scope.batchIndex), max(0, s.batches.count - 1))
            if idx < s.batches.count {
                let b = s.batches[idx]
                s.selected = Tally(count: b.count, bytes: b.bytes)
                s.largest = batchLargests[idx]
            }
        }

        everythingCache = (revision, filterGeneration, selCount, selBytes, scope, s)
        return s
    }

    func itemsForEverything(_ scope: EverythingScope) -> [Item] {
        switch scope.mode {
        case .all:
            return items.filter { passesScopeSwitches($0, scope: scope) }
        case .categories:
            return items.filter { scope.categories.contains($0.category) && passesScopeSwitches($0, scope: scope) }
        case .named:
            return items.filter { $0.hasOriginalName && passesScopeSwitches($0, scope: scope) }
        case .current:
            if !selection.isEmpty && !scope.useFilteredInsteadOfSelection {
                return selectedItems
            }
            return filtered
        case .batches:
            let base = items.filter { passesScopeSwitches($0, scope: scope) }
            let summary = everythingSummary(for: scope)
            let idx = min(max(0, scope.batchIndex), max(0, summary.batches.count - 1))
            guard idx < summary.batches.count else { return [] }
            let batch = summary.batches[idx]
            let lo = max(0, min(base.count, batch.startOffset))
            let hi = max(lo, min(base.count, batch.endOffset))
            return Array(base[lo..<hi])
        }
    }

    func select(_ ids: Set<Int>) {
        let visible = Set(items(ids: ids).map(\.id))
        if selection != visible { selection = visible }
    }

    private func pruneSelection() {
        if !selection.isEmpty { select(selection) }
    }

    /// Para "el video más antiguo": seleccionar el resultado directamente.
    func applySmartSelection() {
        guard smart.pickFirst, let first = filtered.first else { return }
        selection = [first.id]
    }

    /// Mueve la selección `delta` posiciones dentro de lo visible (flechas del teclado).
    @discardableResult
    func step(_ delta: Int) -> Item? {
        let results = filtered
        guard !results.isEmpty else { return nil }
        let current = selection.count == 1 ? results.firstIndex { $0.id == selection.first! } : nil
        let target = current.map { min(results.count - 1, max(0, $0 + delta)) } ?? (delta >= 0 ? 0 : results.count - 1)
        selection = [results[target].id]
        return results[target]
    }

    func selectAll() { selection = Set(filtered.map(\.id)) }

    var focused: Item? {
        selection.count == 1 ? byId[selection.first!] : nil
    }

    var selectedItems: [Item] { selection.compactMap { byId[$0] } }

    func item(_ id: Int) -> Item? { byId[id] }

    func items(ids: Set<Int>) -> [Item] {
        guard !ids.isEmpty else { return [] }
        let query = smart
        return ids.compactMap { id in
            guard let item = byId[id], matchesFilters(item, query: query) else { return nil }
            return item
        }
    }

    func tap(_ item: Item) {
        guard matchesFilters(item, query: smart) else { return }
        // Las teclas que acompañaban a ese clic, no las que están apretadas ahora.
        let flags = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
        if flags.contains(.command) {
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
        } else if flags.contains(.shift), let anchor = selection.first {
            let results = filtered
            if let a = results.firstIndex(where: { $0.id == anchor }),
               let b = results.firstIndex(where: { $0.id == item.id }) {
                selection = Set(results[min(a, b)...max(a, b)].map(\.id))
            } else {
                selection = [item.id]
            }
        } else {
            selection = [item.id]
        }
    }

    // MARK: Recuperar

    var isRecovering: Bool { live.recover != nil && live.recover?.finished == false }

    func openRecoverAll(mode: RecoveryMode = .all) {
        guard !items.isEmpty else { return }
        initialRecoverMode = mode
        showRecoverAll = true
    }

    func stopRecovery() {
        recoverState?.cancel(reason: "Detenido por el usuario")
    }

    func recoverResults() {
        recover(selection.isEmpty ? filtered : selectedItems)
    }

    /// Verifica que el destino no esté en el mismo disco físico que el origen.
    func isSameSourceDisk(_ destination: URL) -> Bool {
        guard let disk = sourceDisk else { return false }
        return DiskSafety.isSameDisk(source: disk.devicePath, output: destination)
    }

    func chooseDestination(for count: Int, bytes: Int64, startingAt directory: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if let directory { panel.directoryURL = directory }
        panel.prompt = "Recuperar aquí"
        let label = count == 1 ? "1 archivo" : "\(count.formatted()) archivos"
        panel.message = "Elige dónde guardar \(label) (\(Bytes.gigabytesDetailed(bytes))). Usa un disco distinto al que estás escaneando."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url
    }

    func recover(_ list: [Item], to chosenDestination: URL? = nil, folderSuffix: String? = nil, batchKey: String? = nil) {
        guard !list.isEmpty, let reader = workReader else { return }
        guard !isRecovering else {
            alert = "Ya hay una recuperación en curso. Espera a que termine o detenla antes de iniciar otra."
            return
        }
        let bytesTotal = list.reduce(Int64(0)) { $0 + $1.file.size }
        let destination: URL
        if let chosenDestination {
            destination = chosenDestination
        } else {
            guard let picked = chooseDestination(for: list.count, bytes: bytesTotal) else { return }
            destination = picked
        }
        if isSameSourceDisk(destination) {
            alert = "Esa carpeta está en el mismo disco que estás escaneando. Guardar ahí puede sobrescribir justamente lo que quieres recuperar. Elige otro disco."
            return
        }
        // Si vino del diálogo directo (no de la hoja que ya mostró el espacio), avisar si no alcanza.
        if chosenDestination == nil, let free = DestinationInfo.read(destination).free, bytesTotal > free {
            let confirm = NSAlert()
            confirm.alertStyle = .warning
            confirm.messageText = "Puede faltar espacio en el disco de destino"
            confirm.informativeText = "Lo seleccionado mide \(Bytes.gigabytesDetailed(bytesTotal)) y en «\(destination.lastPathComponent)» quedan \(Bytes.gigabytesDetailed(free)) disponibles. Si se llena, la copia se detendrá conservando lo recuperado hasta ese momento."
            confirm.addButton(withTitle: "Elegir otra carpeta")
            confirm.addButton(withTitle: "Continuar igual")
            if confirm.runModal() == .alertFirstButtonReturn { return }
        }

        let stamp = Analyzer.nameDate(Date())
        let folderName = folderSuffix.map { "Recuperados \(stamp) — \($0)" } ?? "Recuperados \(stamp)"
        let root = destination.appendingPathComponent(folderName, isDirectory: true)
        // En el orden en que están en el disco: la lectura avanza casi secuencial en vez de
        // saltar de un lado a otro (en un disco mecánico es la diferencia entre minutos y horas).
        let jobs = list.sorted { $0.file.offset < $1.file.offset }
            .map { RecoverJob(file: $0.file, name: $0.name, local: $0.localURL, category: $0.category, date: $0.date) }
        let total = jobs.count
        let state = RecoverState()
        recoverState = state
        live.recover = RecoverStatus(total: total, folder: root, bytesTotal: bytesTotal, started: Date())
        let sourceTitle = sourceName

        Task.detached(priority: .userInitiated) {
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "Recuperando \(total) archivos"
            )
            defer { ProcessInfo.processInfo.endActivity(activity) }

            let fm = FileManager.default
            let rootExisted = fm.fileExists(atPath: root.path)
            try? fm.createDirectory(at: root, withIntermediateDirectories: true)

            // En exFAT o Finder, cientos de miles de archivos sueltos en una sola carpeta ("Fotos/")
            // vuelven lentísima la creación y la apertura. Si una categoría supera 2.000 archivos
            // sin carpeta original, se reparten en subcarpetas "Lote 001", "Lote 002", etc.
            let batchSize = 2_000
            var flatCounts: [FileCategory: Int] = [:]
            for job in jobs where job.file.folder == nil || job.file.folder == "/" {
                flatCounts[job.category, default: 0] += 1
            }
            var flatPlaced: [FileCategory: Int] = [:]

            // Las carpetas y los nombres finales se deciden antes, en serie, para que los
            // trabajadores en paralelo no choquen por el mismo nombre.
            var folders = Set<String>(), taken = Set<String>()
            var targets: [URL] = []
            targets.reserveCapacity(total)
            for job in jobs {
                var folder = root.appendingPathComponent(job.category.rawValue, isDirectory: true)
                if let original = job.file.folder, original != "/" {
                    folder = folder.appendingPathComponent(String(original.drop { $0 == "/" }), isDirectory: true)
                } else if (flatCounts[job.category] ?? 0) > batchSize {
                    let index = flatPlaced[job.category, default: 0]
                    flatPlaced[job.category] = index + 1
                    let batchName = String(format: "Lote %03d", index / batchSize + 1)
                    folder = folder.appendingPathComponent(batchName, isDirectory: true)
                }
                if folders.insert(folder.path).inserted {
                    try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
                }
                var url = folder.appendingPathComponent(job.name)
                var n = 2
                while !taken.insert(url.path.lowercased()).inserted || (rootExisted && fm.fileExists(atPath: url.path)) {
                    url = folder.appendingPathComponent("\((job.name as NSString).deletingPathExtension) (\(n)).\(job.file.ext)")
                    n += 1
                }
                targets.append(url)
            }

            let pageSize = Int64(reader.pageSize)
            // En discos mecánicos grandes conviene pocos lectores secuenciales con prefetch;
            // los 4 trabajadores siguen aprovechando la caché de páginas de 1 MB cuando hay
            // muchos archivos chicos contiguos.
            let workers = min(4, total)
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<workers {
                    group.addTask {
                        while let i = state.next(limit: total) {
                            let job = jobs[i], url = targets[i]
                            if job.local == nil, pageSize > 0 {
                                let startPage = job.file.offset / pageSize
                                reader.prefetch(startPage..<(startPage + 8))
                            }
                            var ok = true
                            do {
                                if let local = job.local, fm.fileExists(atPath: local.path) {
                                    try fm.copyItem(at: local, to: url)
                                } else {
                                    try Extractor.write(job.file, from: reader, to: url)
                                }
                                if let date = job.date {
                                    try? fm.setAttributes([.modificationDate: date, .creationDate: date], ofItemAtPath: url.path)
                                }
                            } catch let ExtractError.write(_, code) where code == ENOSPC {
                                try? fm.removeItem(at: url)
                                state.cancel(reason: "Se llenó el disco de destino")
                                ok = false
                            } catch let ExtractError.create(_, code) where code == ENOSPC {
                                state.cancel(reason: "Se llenó el disco de destino")
                                ok = false
                            } catch let err as NSError where err.domain == NSCocoaErrorDomain && err.code == NSFileWriteOutOfSpaceError {
                                try? fm.removeItem(at: url)
                                state.cancel(reason: "Se llenó el disco de destino")
                                ok = false
                            } catch {
                                ok = false
                            }
                            if let snap = state.finished(ok: ok, bytes: ok ? job.file.size : 0, total: total) {
                                await MainActor.run {
                                    self.live.recover?.done = snap.done
                                    self.live.recover?.failed = snap.failed
                                    self.live.recover?.bytesDone = snap.bytes
                                }
                            }
                        }
                    }
                }
            }

            let final = state.snapshot
            Self.writeRecoveryReport(at: root, source: sourceTitle, totalRequested: total,
                                     bytesRequested: bytesTotal, snapshot: final)

            await MainActor.run {
                if self.recoverState === state { self.recoverState = nil }
                if !final.cancelled, let batchKey {
                    self.completedBatches.insert(batchKey)
                }
                self.live.recover = RecoverStatus(
                    done: final.done,
                    total: total,
                    failed: final.failed,
                    finished: true,
                    folder: root,
                    bytesDone: final.bytes,
                    bytesTotal: bytesTotal,
                    stopped: final.cancelled,
                    stopReason: final.reason
                )
                Signals.recovered(ok: max(0, final.done - final.failed), failed: final.failed)
            }
            // En recuperaciones masivas el aviso queda fijo hasta que el usuario lo cierre o abra Finder.
            guard total < 100, !final.cancelled else { return }
            try? await Task.sleep(for: .seconds(8))
            await MainActor.run {
                if self.live.recover?.finished == true, self.live.recover?.folder == root { self.live.recover = nil }
            }
        }
    }

    nonisolated private static func writeRecoveryReport(
        at root: URL, source: String, totalRequested: Int, bytesRequested: Int64,
        snapshot: RecoverState.Snapshot
    ) {
        let ok = max(0, snapshot.done - snapshot.failed)
        var lines = [
            "Recuperador 3.2.1 — Resumen de recuperación",
            "Fecha: \(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .medium))",
            "Origen: \(source.isEmpty ? "Disco escaneado" : source)",
            "Solicitados: \(totalRequested.formatted()) archivos (\(Bytes.gigabytesDetailed(bytesRequested)))",
            "Recuperados: \(ok.formatted()) archivos (\(Bytes.gigabytesDetailed(snapshot.bytes)))",
        ]
        if snapshot.failed > 0 {
            lines.append("Con error de lectura/escritura: \(snapshot.failed.formatted())")
        }
        if let reason = snapshot.reason {
            lines.append("Estado: \(reason)")
        }
        let text = lines.joined(separator: "\n") + "\n"
        try? text.write(to: root.appendingPathComponent("Resumen.txt"), atomically: true, encoding: .utf8)
    }
}

private struct RecoverJob: Sendable {
    let file: FoundFile
    let name: String
    let local: URL?
    let category: FileCategory
    let date: Date?
}

/// Reparte el trabajo de recuperación entre varios hilos y lleva la cuenta de archivos y bytes.
private final class RecoverState: @unchecked Sendable {
    struct Snapshot: Sendable {
        let done: Int
        let failed: Int
        let bytes: Int64
        let cancelled: Bool
        let reason: String?
    }

    private let lock = NSLock()
    private var cursor = 0
    private var done = 0
    private var failed = 0
    private var bytes: Int64 = 0
    private var cancelled = false
    private var reason: String?
    private var lastReport = Date.distantPast

    var snapshot: Snapshot {
        lock.withLock { Snapshot(done: done, failed: failed, bytes: bytes, cancelled: cancelled, reason: reason) }
    }

    func cancel(reason: String) {
        lock.withLock {
            guard !cancelled else { return }
            cancelled = true
            self.reason = reason
        }
    }

    func next(limit: Int) -> Int? {
        lock.withLock {
            guard !cancelled, cursor < limit else { return nil }
            cursor += 1
            return cursor - 1
        }
    }

    /// Devuelve el avance cuando toca avisar a la interfaz (como mucho unas diez veces por segundo).
    func finished(ok: Bool, bytes written: Int64, total: Int) -> Snapshot? {
        lock.withLock {
            done += 1
            if !ok { failed += 1 }
            bytes += written
            let now = Date()
            guard done == total || cancelled || now.timeIntervalSince(lastReport) > 0.1 else { return nil }
            lastReport = now
            return Snapshot(done: done, failed: failed, bytes: bytes, cancelled: cancelled, reason: reason)
        }
    }
}
