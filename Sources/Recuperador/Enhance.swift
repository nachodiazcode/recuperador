import AppKit
import CoreImage
import ImageIO
import RecoveryCore
import SwiftUI
import UniformTypeIdentifiers
import VideoToolbox

/// Mejora de fotos en el propio Mac, sin subir nada a internet. Nunca toca el archivo recuperado:
/// muestra el resultado en el visor y, si se quiere, guarda una copia aparte.
///
/// - Mejora automática: los ajustes de Core Image (exposición, contraste, balance de color).
/// - Ampliar con IA: el modelo de superresolución de Apple (macOS 26), que hoy amplía ×4. Sirve
///   para fotos chicas, que es lo que suele quedar de un archivo recuperado (miniaturas, fotos viejas
///   de teléfono). Apple limita la entrada a 1920 × 1920 y baja el modelo la primera vez.
@MainActor
final class Enhancer: ObservableObject {
    enum Kind: String { case auto = "Mejorada", upscaled = "Ampliada con IA" }

    @Published private(set) var result: NSImage?
    @Published private(set) var kind: Kind?
    @Published private(set) var working: String?
    @Published private(set) var failure: String?
    @Published var comparing = false
    @Published private(set) var sourceSize: (width: Int, height: Int)?
    private var resultImage: CGImage?
    private var itemID: Int?
    private var job: Task<Void, Never>?

    nonisolated static let maxUpscaleSide = 1920

    var canUpscale: Bool {
        guard let size = sourceSize, Self.upscaleFactor != nil else { return false }
        return size.width <= Self.maxUpscaleSide && size.height <= Self.maxUpscaleSide
    }

    /// Cuánto amplía el modelo de Apple en este Mac (nil si no lo hay).
    nonisolated static var upscaleFactor: Int? {
        guard #available(macOS 26.0, *), VTSuperResolutionScalerConfiguration.isSupported else { return nil }
        return VTSuperResolutionScalerConfiguration.supportedScaleFactors.max()
    }

    /// ¿Ya está instalado el modelo? Si no, el primer uso lo baja de Apple.
    var upscaleModelReady: Bool {
        guard #available(macOS 26.0, *), let size = sourceSize, let factor = Self.upscaleFactor,
              let config = VTSuperResolutionScalerConfiguration(
                frameWidth: size.width, frameHeight: size.height, scaleFactor: factor, inputType: .image,
                usePrecomputedFlow: false, qualityPrioritization: .normal, revision: VTSuperResolutionScalerConfiguration.defaultRevision)
        else { return false }
        return config.configurationModelStatus == .ready
    }

    /// Lo que el visor debe mostrar en lugar de la foto original (nil: la original).
    func display(for id: Int) -> NSImage? {
        itemID == id && !comparing ? result : nil
    }

    func reset(for item: Item?) {
        job?.cancel()
        job = nil
        result = nil
        resultImage = nil
        kind = nil
        working = nil
        failure = nil
        comparing = false
        itemID = item?.id
        sourceSize = nil
    }

    /// Lee el tamaño de la foto (decide si se ofrece la ampliación con IA).
    func measure(_ item: Item) {
        guard itemID == item.id, sourceSize == nil, let url = item.localURL else { return }
        Task {
            let size = await DiskWork.run { ImageDecoder.pixelSize(url: url) }
            if itemID == item.id { sourceSize = size }
        }
    }

    func enhance(_ item: Item, model: AppModel, kind: Kind) {
        job?.cancel()
        failure = nil
        working = kind == .auto ? "Mejorando…" : "Ampliando con IA…"
        let id = item.id
        itemID = id
        job = Task {
            guard let url = await model.extract(item) else {
                finish(id, nil, kind, error: "No se pudo leer el archivo.")
                return
            }
            do {
                let image: CGImage
                switch kind {
                case .auto:
                    image = try await DiskWork.run { Self.autoEnhance(url) }.get()
                case .upscaled:
                    guard #available(macOS 26.0, *) else { throw EnhanceError.unsupported }
                    image = try await Self.upscale(url) { status in
                        Task { @MainActor in if self.itemID == id { self.working = status } }
                    }
                }
                finish(id, image, kind, error: nil)
            } catch {
                finish(id, nil, kind, error: (error as? EnhanceError)?.message ?? error.localizedDescription)
            }
        }
    }

    private func finish(_ id: Int, _ image: CGImage?, _ kind: Kind, error: String?) {
        guard itemID == id, !Task.isCancelled else { return }
        Crossfade.next(0.25)
        working = nil
        failure = error
        resultImage = image
        result = image.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        self.kind = image == nil ? nil : kind
    }

    func discard() {
        Crossfade.next(0.2)
        result = nil
        resultImage = nil
        kind = nil
    }

    /// Guarda una copia al lado de donde el usuario elija, conservando los metadatos (fecha, GPS).
    func saveCopy(of item: Item, model: AppModel) {
        guard let image = resultImage, let kind else { return }
        let panel = NSSavePanel()
        let base = (item.name as NSString).deletingPathExtension
        let type: UTType = item.file.ext == "png" ? .png : item.file.ext == "heic" ? .heic : .jpeg
        panel.nameFieldStringValue = "\(base) (\(kind == .auto ? "mejorada" : "ampliada con IA")).\(type.preferredFilenameExtension ?? "jpg")"
        panel.allowedContentTypes = [type]
        panel.message = "Se guarda una copia nueva. La foto recuperada no se modifica."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let disk = model.sourceDisk, DiskSafety.isSameDisk(source: disk.devicePath, output: url) {
            model.alert = "Esa carpeta está en el mismo disco que estás escaneando. Guardar ahí puede sobrescribir lo que todavía quieres recuperar. Elige otro disco."
            return
        }
        let original = item.localURL
        Task {
            let ok = await DiskWork.run { Self.write(image, to: url, type: type, metadataFrom: original) }
            if ok {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                model.alert = "No se pudo guardar la copia mejorada."
            }
        }
    }

    // MARK: Procesamiento

    enum EnhanceError: Error {
        case unreadable, unsupported, tooLarge, failed(String)
        var message: String {
            switch self {
            case .unreadable: return "La imagen no se puede leer: puede estar dañada."
            case .unsupported: return "Este Mac no tiene el modelo de ampliación de Apple (necesita macOS 26)."
            case .tooLarge: return "Esta foto ya es grande: la ampliación con IA es para fotos de hasta 1920 px de lado."
            case let .failed(why): return why
            }
        }
    }

    private nonisolated static let context = CIContext(options: [.cacheIntermediates: false])

    private nonisolated static func autoEnhance(_ url: URL) -> Result<CGImage, Error> {
        guard var image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            return .failure(EnhanceError.unreadable)
        }
        for filter in image.autoAdjustmentFilters(options: [.redEye: false]) {
            filter.setValue(image, forKey: kCIInputImageKey)
            if let output = filter.outputImage { image = output }
        }
        guard let result = context.createCGImage(image, from: image.extent) else { return .failure(EnhanceError.unreadable) }
        return .success(result)
    }

    @available(macOS 26.0, *)
    private nonisolated static func upscale(_ url: URL, status: @escaping @Sendable (String) -> Void) async throws -> CGImage {
        guard VTSuperResolutionScalerConfiguration.isSupported else { throw EnhanceError.unsupported }
        guard let source = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            throw EnhanceError.unreadable
        }
        let width = Int(source.extent.width), height = Int(source.extent.height)
        guard width <= maxUpscaleSide, height <= maxUpscaleSide else { throw EnhanceError.tooLarge }
        guard let factor = upscaleFactor else { throw EnhanceError.unsupported }
        guard let config = VTSuperResolutionScalerConfiguration(
            frameWidth: width, frameHeight: height, scaleFactor: factor, inputType: .image, usePrecomputedFlow: false,
            qualityPrioritization: .normal, revision: VTSuperResolutionScalerConfiguration.defaultRevision)
        else { throw EnhanceError.failed("El modelo de Apple no acepta una imagen de \(width) × \(height).") }

        // El modelo lo instala macOS la primera vez (se baja de Apple; la foto no sale del Mac).
        if config.configurationModelStatus != .ready {
            status("Descargando el modelo de Apple…")
            let download = Task {
                while !Task.isCancelled {
                    status("Descargando el modelo de Apple… \(Int(config.configurationModelPercentageAvailable * 100)) %")
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
            defer { download.cancel() }
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                config.downloadConfigurationModel { error in
                    if let error { done.resume(throwing: error) } else { done.resume() }
                }
            }
            status("Ampliando con IA…")
        }

        let input = try pixelBuffer(width: width, height: height, attributes: config.sourcePixelBufferAttributes)
        context.render(source.transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY)), to: input)
        let output = try pixelBuffer(width: width * factor, height: height * factor, attributes: config.destinationPixelBufferAttributes)
        guard let sourceFrame = VTFrameProcessorFrame(buffer: input, presentationTimeStamp: .zero),
              let destinationFrame = VTFrameProcessorFrame(buffer: output, presentationTimeStamp: .zero),
              let parameters = VTSuperResolutionScalerParameters(
                sourceFrame: sourceFrame, previousFrame: nil, previousOutputFrame: nil, opticalFlow: nil,
                submissionMode: .random, destinationFrame: destinationFrame)
        else { throw EnhanceError.failed("No se pudo preparar la imagen para el modelo.") }

        let processor = VTFrameProcessor()
        try processor.startSession(configuration: config)
        defer { processor.endSession() }
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            processor.process(parameters: parameters) { _, error in
                if let error { done.resume(throwing: error) } else { done.resume() }
            }
        }
        let result = CIImage(cvPixelBuffer: output)
        guard let image = context.createCGImage(result, from: result.extent) else { throw EnhanceError.unreadable }
        return image
    }

    private nonisolated static func pixelBuffer(width: Int, height: Int, attributes: [String: Any]) throws -> CVPixelBuffer {
        let raw = attributes[kCVPixelBufferPixelFormatTypeKey as String]
        let format = (raw as? NSNumber)?.uint32Value ?? (raw as? [NSNumber])?.first?.uint32Value ?? kCVPixelFormatType_32BGRA
        var options = attributes
        options[kCVPixelBufferPixelFormatTypeKey as String] = format
        options[kCVPixelBufferWidthKey as String] = width
        options[kCVPixelBufferHeightKey as String] = height
        if options[kCVPixelBufferIOSurfacePropertiesKey as String] == nil {
            options[kCVPixelBufferIOSurfacePropertiesKey as String] = [String: Any]()
        }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, width, height, format, options as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            throw EnhanceError.failed("No se pudo reservar memoria para la imagen (\(status)).")
        }
        return buffer
    }

    private nonisolated static func write(_ image: CGImage, to url: URL, type: UTType, metadataFrom original: URL?) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { return false }
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.95]
        if let original, let source = CGImageSourceCreateWithURL(original as CFURL, nil),
           let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary] {
                if let value = metadata[key] { properties[key] = value }
            }
            if var tiff = metadata[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFOrientation] = 1
                properties[kCGImagePropertyTIFFDictionary] = tiff
            }
        }
        // La orientación ya quedó aplicada en los píxeles.
        properties[kCGImagePropertyOrientation] = 1
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }
}

/// Botones de mejora en la barra del visor (solo fotos).
struct EnhanceControls: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var enhancer: Enhancer
    @ObservedObject var item: Item

    var body: some View {
        HStack(spacing: 8) {
            content
        }
        .task(id: item.localURL) { enhancer.measure(item) }
    }

    @ViewBuilder private var content: some View {
        Group {
            if let working = enhancer.working {
                ProgressView().controlSize(.small)
                Text(working).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            } else if let kind = enhancer.kind {
                Label(kind.rawValue, systemImage: "sparkles")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Palette.accent)
                Text("Mantén apretado para comparar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(enhancer.comparing ? Palette.accent.opacity(0.2) : Color.primary.opacity(0.07), in: Capsule())
                    .onLongPressGesture(minimumDuration: 0.0, maximumDistance: 40) {
                    } onPressingChanged: { pressing in
                        enhancer.comparing = pressing
                    }
                    .help("Mientras lo mantienes apretado se ve la foto original")
                Button { enhancer.saveCopy(of: item, model: model) } label: {
                    Label("Guardar copia…", systemImage: "square.and.arrow.down")
                }
                Button { enhancer.discard() } label: { Image(systemName: "arrow.uturn.backward") }
                    .help("Volver a la original")
            } else {
                Menu {
                    Button { enhancer.enhance(item, model: model, kind: .auto) } label: {
                        Label("Mejorar automáticamente", systemImage: "wand.and.stars")
                    }
                    if enhancer.canUpscale, let factor = Enhancer.upscaleFactor {
                        Button { enhancer.enhance(item, model: model, kind: .upscaled) } label: {
                            Label(enhancer.upscaleModelReady ? "Ampliar ×\(factor) con IA de Apple"
                                  : "Ampliar ×\(factor) con IA de Apple (baja el modelo la primera vez)",
                                  systemImage: "arrow.up.left.and.arrow.down.right")
                        }
                    }
                    Divider()
                    Text("Se procesa en este Mac. La foto recuperada no se modifica.")
                } label: {
                    Label("Mejorar", systemImage: "wand.and.stars")
                }
                .fixedSize()
                .help("Mejorar la foto con el procesamiento de Apple, sin internet")
                if let failure = enhancer.failure {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(failure)
                }
            }
        }
    }
}

/// La imagen del visor con la versión mejorada encima cuando la hay.
struct EnhancedZoomableImage: View {
    @ObservedObject var enhancer: Enhancer
    let itemID: Int
    let base: NSImage
    let zoom: ZoomController

    var body: some View {
        ZoomableImage(image: enhancer.display(for: itemID) ?? base, controller: zoom)
    }
}
