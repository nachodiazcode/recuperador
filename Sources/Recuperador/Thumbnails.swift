import AVFoundation
import AppKit
import ImageIO
import PDFKit
import QuickLookThumbnailing
import RecoveryCore
import UniformTypeIdentifiers

/// Deja pasar pocas tareas a la vez. Atiende primero a la última que llegó: al desplazar la
/// galería, lo que se acaba de pedir es lo que está en pantalla.
actor Limiter {
    private var free: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ slots: Int) { free = slots }

    func acquire() async {
        if free > 0 { free -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if let next = waiters.popLast() { next.resume() } else { free += 1 }
    }
}

/// Las lecturas del disco bloquean el hilo; se hacen fuera del pool de Swift Concurrency.
enum DiskWork {
    private static let queue = DispatchQueue(label: "recuperador.lectura", qos: .userInitiated, attributes: .concurrent)

    static func run<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }
}

/// Decodificación de imágenes a un tamaño dado, sin cargar la foto entera en memoria.
enum ImageDecoder {
    private static func options(_ maxPixel: Int) -> CFDictionary {
        [kCGImageSourceCreateThumbnailFromImageAlways: true,
         kCGImageSourceCreateThumbnailWithTransform: true,
         kCGImageSourceShouldCacheImmediately: true,
         kCGImageSourceThumbnailMaxPixelSize: maxPixel] as CFDictionary
    }

    static func image(data: Data, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options(maxPixel))
    }

    static func image(url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options(maxPixel))
    }

    /// Tamaño real en píxeles, ya con la orientación aplicada.
    static func pixelSize(url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? (h, w) : (w, h)
    }

    static func firstPage(of document: PDFDocument?, maxPixel: Int) -> CGImage? {
        guard let page = document?.page(at: 0) else { return nil }
        let side = CGFloat(maxPixel)
        return page.thumbnail(of: NSSize(width: side, height: side), for: .cropBox)
            .cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

/// Sirve a AVFoundation los bytes de un video directamente desde el disco escaneado, sin
/// extraerlo antes. Así se puede sacar el fotograma de un video de varios GB (o reproducirlo)
/// leyendo solo lo necesario.
final class DiskAsset: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let playable: Set<String> = ["mp4", "mov", "m4v", "3gp"]

    let asset: AVURLAsset
    private let file: FoundFile
    private let reader: DiskReader
    private let requests = DispatchQueue(label: "recuperador.video.pedidos", qos: .userInitiated)
    private let reads = DispatchQueue(label: "recuperador.video.lectura", qos: .userInitiated, attributes: .concurrent)
    private let lock = NSLock()
    private var cancelled = Set<ObjectIdentifier>()
    private var closed = false

    init(file: FoundFile, reader: DiskReader) {
        self.file = file
        self.reader = reader
        asset = AVURLAsset(url: URL(string: "recuperador-disco://archivo/\(file.offset).\(file.ext)")!)
        super.init()
        asset.resourceLoader.setDelegate(self, queue: requests)
    }

    /// Deja de leer del disco: ya no hace falta nada más de este archivo.
    func close() {
        lock.withLock { closed = true }
        asset.cancelLoading()
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        // Se responde desde otra cola. Si se leyera aquí mismo, AVFoundation no podría avisar que
        // ya no quiere un tramo: con el índice del video al final, eso significaba leer el
        // archivo entero solo para llegar a él.
        reads.async { [self] in serve(request) }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        lock.withLock { _ = cancelled.insert(ObjectIdentifier(request)) }
    }

    private func stopped(_ request: AVAssetResourceLoadingRequest) -> Bool {
        request.isCancelled || lock.withLock { closed || cancelled.contains(ObjectIdentifier(request)) }
    }

    private func serve(_ request: AVAssetResourceLoadingRequest) {
        defer { lock.withLock { _ = cancelled.remove(ObjectIdentifier(request)) } }
        if let info = request.contentInformationRequest {
            info.contentType = (UTType(filenameExtension: file.ext) ?? .mpeg4Movie).identifier
            info.contentLength = file.size
            info.isByteRangeAccessSupported = true
        }
        guard let wanted = request.dataRequest else {
            request.finishLoading()
            return
        }
        var offset = wanted.currentOffset
        let end = wanted.requestsAllDataToEndOfResource
            ? file.size : min(file.size, wanted.requestedOffset + Int64(wanted.requestedLength))
        while offset < end {
            if stopped(request) { return }
            // Tramos cortos: entre uno y otro se comprueba si el pedido sigue vigente.
            let bytes = Extractor.read(file, from: reader, at: offset, count: Int(min(256 << 10, end - offset)))
            guard !bytes.isEmpty else { break }
            wanted.respond(with: Data(bytes))
            offset += Int64(bytes.count)
        }
        request.finishLoading()
    }

    /// Un fotograma cercano al inicio (el fotograma clave más próximo: es lo más rápido).
    static func poster(of asset: AVAsset, maxPixel: Int) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        return try? await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
    }
}

/// Miniaturas de la galería. Se generan leyendo el archivo directamente del disco escaneado,
/// solo para lo que está en pantalla, así que no hace falta haber extraído nada antes.
@MainActor
final class ThumbnailStore {
    static let shared = ThumbnailStore()

    /// Lado mayor de la miniatura en píxeles (las tarjetas miden 178 pt a 2x).
    nonisolated static let side = 384
    private nonisolated static let photoLimit: Int64 = 96 << 20
    private nonisolated static let documentLimit: Int64 = 48 << 20

    private let cache = NSCache<NSNumber, NSImage>()
    private var failed = Set<String>()
    private var generation = 0
    private var reader: DiskReader?
    private weak var model: AppModel?
    private let limiter = Limiter(4)

    private init() {
        // ~400 KB por miniatura: unas 400 en memoria bastan para volver atrás sin regenerar.
        cache.countLimit = 400
        cache.totalCostLimit = 160 << 20
    }

    func reset(reader: DiskReader?, model: AppModel) {
        generation += 1
        self.reader = reader
        self.model = model
        cache.removeAllObjects()
        failed = []
    }

    func cached(_ id: Int) -> NSImage? { cache.object(forKey: id as NSNumber) }

    func thumbnail(for item: Item) async -> NSImage? {
        if let hit = cached(item.id) { return hit }
        let local = item.localURL
        let key = "\(item.id)|\(local != nil)"
        guard !failed.contains(key), let reader else { return nil }
        let started = generation, file = item.file

        await limiter.acquire()
        var image: CGImage?
        if !Task.isCancelled, started == generation {
            if let local {
                image = await Self.render(local: local, file: file)
            } else if file.category == .document, file.ext != "pdf", file.size <= Self.documentLimit {
                // Word, Excel, Keynote...: Quick Look necesita un archivo de verdad.
                if let url = await model?.extract(item) { image = await Self.render(local: url, file: file) }
            } else {
                image = await Self.render(file: file, reader: reader)
            }
        }
        await limiter.release()

        guard started == generation, !Task.isCancelled else { return nil }
        guard let image else {
            failed.insert(key)
            return nil
        }
        let result = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        cache.setObject(result, forKey: item.id as NSNumber, cost: image.width * image.height * 4)
        return result
    }

    /// Directo del disco, sin escribir nada.
    private nonisolated static func render(file: FoundFile, reader: DiskReader) async -> CGImage? {
        switch file.category {
        case .photo:
            return await DiskWork.run {
                Extractor.data(file, from: reader, limit: photoLimit).flatMap { ImageDecoder.image(data: $0, maxPixel: side) }
            }
        case .video where DiskAsset.playable.contains(file.ext):
            let source = DiskAsset(file: file, reader: reader)
            // AVFoundation no retiene al delegado: `source` tiene que vivir hasta el final.
            let image = await DiskAsset.poster(of: source.asset, maxPixel: side)
            source.close()
            return image
        case .document where file.ext == "pdf":
            return await DiskWork.run {
                Extractor.data(file, from: reader, limit: documentLimit)
                    .flatMap { ImageDecoder.firstPage(of: PDFDocument(data: $0), maxPixel: side) }
            }
        default:
            return nil
        }
    }

    /// De un archivo ya extraído a la carpeta temporal.
    private nonisolated static func render(local url: URL, file: FoundFile) async -> CGImage? {
        switch file.category {
        case .photo:
            return await DiskWork.run { ImageDecoder.image(url: url, maxPixel: side) }
        case .video where DiskAsset.playable.contains(file.ext):
            return await DiskAsset.poster(of: AVURLAsset(url: url), maxPixel: side)
        case .document where file.ext == "pdf":
            return await DiskWork.run { ImageDecoder.firstPage(of: PDFDocument(url: url), maxPixel: side) }
        case .audio, .archive, .other:
            return nil
        default:
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side / 2, height: side / 2),
                                                       scale: 2, representationTypes: .thumbnail)
            return (try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request))?.cgImage
        }
    }
}
