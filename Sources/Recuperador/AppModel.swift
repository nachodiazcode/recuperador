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
    @Published var name: String
    @Published var date: Date?
    @Published var rows: [MetaRow] = []
    @Published var labels: [String] = []
    @Published var health: Int?
    @Published var healthNote = "Analizando…"
    @Published var localURL: URL?
    @Published var preparing = false

    init(id: Int, file: FoundFile) {
        self.id = id
        self.file = file
        category = file.category
        name = file.name ?? "Archivo \(id).\(file.ext)"
        date = file.modified
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
        health = a.health
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
    private var volumes: [VolumeInfo] = []
    private var progress: CarveProgress?
    private var cancelled = false

    func add(_ f: FoundFile) { lock.withLock { files.append(f) } }
    func add(_ v: VolumeInfo) { lock.withLock { volumes.append(v) } }
    func set(_ p: CarveProgress) { lock.withLock { progress = p } }
    func cancel() { lock.withLock { cancelled = true } }
    var isCancelled: Bool { lock.withLock { cancelled } }

    func drain() -> ([FoundFile], [VolumeInfo], CarveProgress?) {
        lock.withLock {
            defer { files = []; volumes = [] }
            return (files, volumes, progress)
        }
    }
}

/// Cola de trabajo para extraer y analizar archivos con varios hilos.
actor WorkQueue {
    private var jobs: [(Int, FoundFile)] = []
    private var closed = false

    func push(_ job: (Int, FoundFile)) { jobs.append(job) }
    func close() { closed = true }

    func next() async -> (Int, FoundFile)? {
        while true {
            if !jobs.isEmpty { return jobs.removeFirst() }
            if closed { return nil }
            try? await Task.sleep(for: .milliseconds(150))
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var disks: [DiskInfo] = []
    @Published var phase: Phase = .idle
    @Published var sourceName = ""
    @Published var sourceSymbol = "externaldrive.fill"
    @Published var sourceDisk: DiskInfo?
    @Published var progress: CarveProgress?
    @Published var quickElapsed: TimeInterval?
    @Published var volumes: [VolumeInfo] = []
    @Published private(set) var items: [Item] = []
    @Published private(set) var revision = 0

    /// Qué buscar, elegido antes de escanear (tipos, años, tamaño mínimo).
    @Published var scanFilter = ScanFilter()
    @Published var filter: SidebarFilter = .all
    @Published var year: Int?
    @Published var search = ""
    @Published var onlyRecoverable = false
    @Published var hideEmbedded = true
    @Published var hideOverwritten = false
    @Published var sort: SortOrder = .date
    @Published var badSectors = 0
    @Published var selection = Set<Int>()
    @Published var recoverMessage: String?
    @Published var alert: String?

    private var byId: [Int: Item] = [:]
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
    private let eagerLimit: Int64 = 150 * 1024 * 1024

    init() {
        try? FileManager.default.removeItem(at: cacheRoot)
        session = cacheRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
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
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        for _ in 0..<3 { startWorker() }

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
                                                             progress: sink.set, onFound: sink.add)
            }
            await MainActor.run {
                self.tick()
                let cancelled = sink.isCancelled
                self.phase = cancelled ? .cancelled : .finished
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

    func stop() { sink.cancel() }

    func newScan() {
        reset(keepPhase: false)
        refreshDisks()
    }

    private func reset(keepPhase: Bool) {
        sink.cancel()
        Task { [queue] in await queue.close() }
        timer?.invalidate()
        sink = ScanSink()
        queue = WorkQueue()
        items = []
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
        try? FileManager.default.removeItem(at: session)
        session = cacheRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        if !keepPhase { phase = .idle }
    }

    private func tick() {
        let (files, vols, p) = sink.drain()
        volumes += vols
        if let p { progress = p }
        badSectors = reader?.badSectors ?? 0
        var added: [Item] = []
        for f in files where scanFilter.allows(ext: f.ext) && f.size >= scanFilter.minSize
            && seenOffsets.insert(f.offset).inserted {
            let item = Item(id: items.count + added.count + 1, file: f)
            added.append(item)
            byId[item.id] = item
            let job = (item.id, f)
            Task { [queue] in await queue.push(job) }
        }
        if !added.isEmpty {
            items += added
            dirty = true
        }
        if dirty {
            dirty = false
            revision += 1
        }
    }

    private func startWorker() {
        let queue = self.queue, session = self.session, limit = eagerLimit
        guard let reader = workReader else { return }
        Task.detached(priority: .utility) {
            while let (id, file) = await queue.next() {
                guard file.size <= limit else {
                    await MainActor.run { self.byId[id]?.healthNote = "Archivo grande: se analiza al seleccionarlo." }
                    continue
                }
                let url = session.appendingPathComponent("\(id).\(file.ext)")
                guard (try? Extractor.write(file, from: reader, to: url)) != nil else { continue }
                let analysis = await Analyzer.analyze(url: url, file: file)
                await MainActor.run {
                    guard let item = self.byId[id] else { return }
                    item.localURL = url
                    item.apply(analysis)
                    self.dirty = true
                    self.revision += 1
                }
            }
        }
    }

    /// Extrae y analiza bajo demanda un archivo grande.
    func prepare(_ item: Item) {
        guard item.localURL == nil, !item.preparing, let reader = workReader else { return }
        item.preparing = true
        let file = item.file, url = session.appendingPathComponent("\(item.id).\(file.ext)")
        Task.detached(priority: .userInitiated) {
            let ok = (try? Extractor.write(file, from: reader, to: url)) != nil
            let analysis = ok ? await Analyzer.analyze(url: url, file: file) : nil
            await MainActor.run {
                item.preparing = false
                if let analysis {
                    item.localURL = url
                    item.apply(analysis)
                    self.dirty = true
                    self.revision += 1
                }
            }
        }
    }

    // MARK: Filtros

    var smart: SmartQuery { SmartQuery.parse(search) }

    /// ¿Entra en el rango de años elegido antes de escanear? Los archivos sin fecha aún se están
    /// analizando (la fecha sale del EXIF o del video), así que esperan ocultos hasta saberla.
    private func inScanRange(_ item: Item) -> Bool {
        guard scanFilter.hasDateRange else { return true }
        if let year = item.year { return scanFilter.allows(year: year) }
        let analyzed = item.health != nil || item.file.size > eagerLimit
        return analyzed && scanFilter.includeUndated
    }

    private var visible: [Item] { items.filter(inScanRange) }

    /// Archivos encontrados que todavía esperan su análisis para saber si entran en el rango de fechas.
    var pendingCount: Int {
        _ = revision
        guard scanFilter.hasDateRange else { return 0 }
        return items.filter { $0.year == nil && $0.health == nil && $0.file.size <= eagerLimit }.count
    }

    var filtered: [Item] {
        _ = revision
        let query = smart
        let list = visible.filter { item in
            switch filter {
            case .all: break
            case let .category(c): if item.category != c { return false }
            case .named: if !item.hasOriginalName { return false }
            }
            if let year, item.year != year { return false }
            if onlyRecoverable, (item.health ?? 0) < 70 { return false }
            if hideEmbedded, item.file.embedded { return false }
            if hideOverwritten, item.file.likelyOverwritten { return false }
            return query.matches(item)
        }
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
            return list.sorted {
                let a = $0.date ?? (ascendingDate ? .distantFuture : .distantPast)
                let b = $1.date ?? (ascendingDate ? .distantFuture : .distantPast)
                return ascendingDate ? a < b : a > b
            }
        case .name: return list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .size:
            return query.order == .smallest ? list.sorted { $0.file.size < $1.file.size } : list.sorted { $0.file.size > $1.file.size }
        case .health: return list.sorted { ($0.health ?? -1) > ($1.health ?? -1) }
        }
    }

    func count(_ f: SidebarFilter) -> Int {
        _ = revision
        let base = visible
        switch f {
        case .all: return base.count
        case let .category(c): return base.filter { $0.category == c }.count
        case .named: return base.filter(\.hasOriginalName).count
        }
    }

    var years: [(year: Int, count: Int)] {
        _ = revision
        let counts = Dictionary(grouping: visible.compactMap(\.year), by: { $0 }).mapValues(\.count)
        return counts.sorted { $0.key > $1.key }.map { ($0.key, $0.value) }
    }

    /// Para "el video más antiguo": seleccionar el resultado directamente.
    func applySmartSelection() {
        guard smart.pickFirst, let first = filtered.first else { return }
        selection = [first.id]
    }

    var focused: Item? {
        selection.count == 1 ? byId[selection.first!] : nil
    }

    var selectedItems: [Item] { selection.compactMap { byId[$0] } }

    func items(ids: Set<Int>) -> [Item] { ids.compactMap { byId[$0] } }

    /// Conteos de lo que se está mostrando. `revision` obliga a recalcular cuando termina un análisis.
    var libraryCounts: (shown: Int, named: Int, recoverable: Int, review: Int) {
        _ = revision
        var named = 0, recoverable = 0, review = 0
        for item in visible {
            if item.hasOriginalName { named += 1 }
            if let health = item.health {
                if health >= 70 { recoverable += 1 } else { review += 1 }
            }
        }
        return (visible.count, named, recoverable, review)
    }

    var hasEmbeddedResults: Bool {
        _ = revision
        return items.contains { $0.file.embedded }
    }

    func tap(_ item: Item) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
        } else if flags.contains(.shift), let anchor = selection.first,
                  let a = filtered.firstIndex(where: { $0.id == anchor }), let b = filtered.firstIndex(where: { $0.id == item.id }) {
            selection = Set(filtered[min(a, b)...max(a, b)].map(\.id))
        } else {
            selection = [item.id]
        }
    }

    // MARK: Recuperar

    func recover(_ list: [Item]) {
        guard !list.isEmpty, let reader = workReader else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Recuperar aquí"
        panel.message = "Elige dónde guardar \(list.count == 1 ? "el archivo" : "los \(list.count) archivos"). Usa un disco distinto al que estás escaneando."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        if let disk = sourceDisk, DiskSafety.isSameDisk(source: disk.devicePath, output: destination) {
            alert = "Esa carpeta está en el mismo disco que estás escaneando. Guardar ahí puede sobrescribir justamente lo que quieres recuperar. Elige otro disco."
            return
        }
        let stamp = Analyzer.nameDate(Date())
        let root = destination.appendingPathComponent("Recuperados \(stamp)", isDirectory: true)
        let jobs = list.map { (file: $0.file, name: $0.name, local: $0.localURL, category: $0.category, date: $0.date) }
        recoverMessage = "Recuperando 0 de \(jobs.count)…"

        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var failures = 0
            for (i, job) in jobs.enumerated() {
                var folder = root.appendingPathComponent(job.category.rawValue, isDirectory: true)
                if let original = job.file.folder, original != "/" {
                    folder = folder.appendingPathComponent(String(original.drop { $0 == "/" }), isDirectory: true)
                }
                try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
                var url = folder.appendingPathComponent(job.name)
                var n = 2
                while fm.fileExists(atPath: url.path) {
                    url = folder.appendingPathComponent("\((job.name as NSString).deletingPathExtension) (\(n)).\(job.file.ext)")
                    n += 1
                }
                do {
                    if let local = job.local, fm.fileExists(atPath: local.path) {
                        try fm.copyItem(at: local, to: url)
                    } else {
                        try Extractor.write(job.file, from: reader, to: url)
                    }
                    if let date = job.date { try? fm.setAttributes([.modificationDate: date, .creationDate: date], ofItemAtPath: url.path) }
                } catch {
                    failures += 1
                }
                let done = i + 1
                await MainActor.run { self.recoverMessage = "Recuperando \(done) de \(jobs.count)…" }
            }
            let failed = failures
            await MainActor.run {
                self.recoverMessage = failed == 0 ? "✓ \(jobs.count) archivo(s) recuperado(s)" : "Recuperados \(jobs.count - failed); \(failed) fallaron"
                Signals.recovered(ok: jobs.count - failed, failed: failed)
                NSWorkspace.shared.activateFileViewerSelecting([root])
            }
            try? await Task.sleep(for: .seconds(4))
            await MainActor.run { self.recoverMessage = nil }
        }
    }
}
