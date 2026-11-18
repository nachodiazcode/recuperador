import AVKit
import PDFKit
import RecoveryCore
import SwiftUI

enum PreviewKind {
    case image, video, audio, pdf, text, other

    private static let textExtensions: Set<String> = ["txt", "log", "json", "xml", "html", "css", "js", "ts", "py",
                                                      "swift", "md", "sh", "csv", "plist", "yml", "yaml"]

    init(_ file: FoundFile) {
        switch file.category {
        case .photo: self = .image
        case .video: self = .video
        case .audio: self = .audio
        default:
            if file.ext == "pdf" { self = .pdf }
            else if Self.textExtensions.contains(file.ext) { self = .text }
            else { self = .other }
        }
    }
}

/// Vista previa de un archivo encontrado. Sirve igual para el panel de detalles (compacta) y
/// para el visor grande. Mientras el archivo se copia del disco muestra la miniatura que ya
/// está en memoria, así al seleccionar siempre se ve algo al instante.
struct FilePreview: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var item: Item
    var large = false
    var zoom: ZoomController?
    var enhancer: Enhancer?

    var body: some View {
        Group {
            if PreviewKind(item.file) == .video, item.localURL != nil || model.canStream(item.file) {
                // Los videos se reproducen directo del disco: no hay que esperar a copiarlos.
                PlayerPreview(item: item, large: large)
            } else if let url = item.localURL {
                loaded(url)
            } else {
                PendingPreview(item: item, large: large)
            }
        }
        .task(id: item.id) {
            guard item.file.size <= model.autoPreviewLimit || model.canStream(item.file) else { return }
            if model.isBrowsingFast {
                // Con la flecha mantenida solo se ven miniaturas; al detenerse se carga la nítida.
                try? await Task.sleep(for: .milliseconds(160))
                guard !Task.isCancelled else { return }
            }
            model.prepare(item)
        }
    }

    @ViewBuilder private func loaded(_ url: URL) -> some View {
        switch PreviewKind(item.file) {
        case .image:
            ImagePreview(url: url, item: item, large: large, zoom: zoom, enhancer: enhancer)
        case .video:
            PlayerPreview(item: item, large: large)
        case .audio:
            NativeAudioPreview(url: url, title: item.name, large: large)
                .frame(maxWidth: large ? 560 : .infinity)
                .padding(large ? 24 : 0)
        case .pdf:
            PDFKitRepresentable(url: url)
                .frame(height: large ? nil : 300)
                .modifier(PreviewFrame(large: large))
        case .text:
            NativeTextPreview(url: url, large: large)
        case .other:
            QuickLookPreview(url: url)
                .frame(height: large ? nil : 240)
                .modifier(PreviewFrame(large: large))
        }
    }
}

/// Borde redondeado del panel; en el visor grande el contenido ocupa todo.
private struct PreviewFrame: ViewModifier {
    let large: Bool

    func body(content: Content) -> some View {
        if large {
            content
        } else {
            content
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.08)))
        }
    }
}

/// Todavía no hay archivo local: miniatura al fondo y el estado de la carga encima.
private struct PendingPreview: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var item: Item
    let large: Bool
    @State private var thumbnail: NSImage?

    var body: some View {
        let shown = thumbnail ?? ThumbnailStore.shared.cached(item.id)
        ZStack {
            if !large { Color.primary.opacity(0.05) }
            if let shown {
                Image(nsImage: shown).resizable().interpolation(.high).scaledToFit()
            } else {
                ResultFileIcon(category: item.category, size: large ? 96 : 56)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: large ? .infinity : nil)
        .frame(height: large ? nil : 240)
        .overlay(alignment: .bottom) { status.padding(12) }
        .modifier(PreviewFrame(large: large))
        .task(id: item.id) { thumbnail = await ThumbnailStore.shared.thumbnail(for: item) }
    }

    @ViewBuilder private var status: some View {
        if item.failed {
            pill {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("No se pudo leer del disco")
                Button("Reintentar") { model.prepare(item) }.buttonStyle(.link)
            }
        } else if item.loading {
            pill {
                if let progress = item.progress {
                    ProgressView(value: progress).frame(width: 90)
                    Text("\(Int(progress * 100)) %").monospacedDigit()
                } else {
                    ProgressView().controlSize(.small)
                    Text("Cargando…")
                }
            }
        } else if item.file.size > model.autoPreviewLimit {
            Button {
                model.prepare(item)
            } label: {
                Label("Cargar vista previa (\(ByteCountFormatter.string(fromByteCount: item.file.size, countStyle: .file)))",
                      systemImage: "eye")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func pill<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) { content() }
            .font(.callout.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
    }
}

// MARK: - Imágenes

struct ImagePreview: View {
    @EnvironmentObject var model: AppModel
    let url: URL
    @ObservedObject var item: Item
    let large: Bool
    var zoom: ZoomController?
    var enhancer: Enhancer?
    @State private var image: NSImage?
    @State private var failed = false
    @State private var pixels: String?

    var body: some View {
        // La miniatura ya está en memoria: se muestra de inmediato y se reemplaza por la nítida.
        let shown = image ?? ThumbnailStore.shared.cached(item.id)
        ZStack {
            if let shown {
                if large, let zoom {
                    if let enhancer {
                        EnhancedZoomableImage(enhancer: enhancer, itemID: item.id, base: shown, zoom: zoom)
                    } else {
                        ZoomableImage(image: shown, controller: zoom)
                    }
                } else {
                    Image(nsImage: shown).resizable().interpolation(.high).scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 340)
                        .background(Color.primary.opacity(0.05))
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { model.viewerOpen = true }
                }
            } else if failed {
                // ImageIO no pudo; Quick Look a veces sí (formatos raros, RAW de cámara).
                QuickLookPreview(url: url).frame(height: large ? nil : 240)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        .overlay(alignment: .topLeading) {
            if let pixels, !large {
                Text(pixels)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(8)
            }
        }
        .modifier(PreviewFrame(large: large))
        .task(id: url) {
            // Se decodifica fuera del hilo principal y ya reducida al tamaño que se va a mostrar.
            let side = large ? 4096 : 1400
            let source = url
            let (decoded, size) = await DiskWork.run {
                (ImageDecoder.image(url: source, maxPixel: side), ImageDecoder.pixelSize(url: source))
            }
            guard !Task.isCancelled else { return }
            if let decoded {
                image = NSImage(cgImage: decoded, size: NSSize(width: decoded.width, height: decoded.height))
            } else {
                failed = true
            }
            if let size {
                let mp = Double(size.width * size.height) / 1_000_000
                pixels = mp >= 1 ? "\(size.width) × \(size.height) · \(String(format: "%.1f", mp)) MP" : "\(size.width) × \(size.height)"
            }
        }
    }
}

/// Controla el zoom del visor desde los botones de la barra.
@MainActor
final class ZoomController: ObservableObject {
    @Published var magnification: CGFloat = 1
    private var observer: NSObjectProtocol?
    weak var scroll: NSScrollView? {
        didSet {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            guard let scroll else { return }
            observer = NotificationCenter.default.addObserver(forName: NSScrollView.didEndLiveMagnifyNotification,
                                                              object: scroll, queue: .main) { [weak self] note in
                let value = (note.object as? NSScrollView)?.magnification ?? 1
                Task { @MainActor in self?.magnification = value }
            }
            // Se asigna mientras SwiftUI construye la vista: publicar el cambio ahí mismo no está permitido.
            Task { @MainActor [weak self] in self?.magnification = 1 }
        }
    }

    func zoom(by factor: CGFloat) { set((scroll?.magnification ?? 1) * factor) }
    func reset() { set(1) }

    func set(_ value: CGFloat, at point: NSPoint? = nil) {
        guard let scroll else { return }
        let target = min(scroll.maxMagnification, max(scroll.minMagnification, value))
        let bounds = scroll.contentView.bounds
        let center = point ?? NSPoint(x: bounds.midX, y: bounds.midY)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            scroll.animator().setMagnification(target, centeredAt: center)
        }
        magnification = target
    }
}

/// Imagen con zoom nativo: pellizco en el trackpad, desplazamiento y doble clic.
struct ZoomableImage: NSViewRepresentable {
    let image: NSImage
    let controller: ZoomController

    func makeCoordinator() -> Coordinator { Coordinator(controller) }

    func makeNSView(context: Context) -> FittingScrollView {
        let scroll = FittingScrollView()
        scroll.allowsMagnification = true
        scroll.minMagnification = 1
        scroll.maxMagnification = 12
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.image = image
        scroll.documentView = view
        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleClick(_:)))
        click.numberOfClicksRequired = 2
        view.addGestureRecognizer(click)
        controller.scroll = scroll
        return scroll
    }

    func updateNSView(_ scroll: FittingScrollView, context: Context) {
        guard let view = scroll.documentView as? NSImageView, view.image !== image else { return }
        view.image = image
    }

    @MainActor
    final class Coordinator: NSObject {
        let controller: ZoomController
        init(_ controller: ZoomController) { self.controller = controller }

        @objc func doubleClick(_ gesture: NSClickGestureRecognizer) {
            guard let scroll = controller.scroll, let view = gesture.view else { return }
            let point = gesture.location(in: view)
            controller.set(scroll.magnification > 1.01 ? 1 : 3, at: point)
        }
    }

    /// El documento mide siempre lo mismo que el área visible: con zoom 1 la imagen cabe entera.
    final class FittingScrollView: NSScrollView {
        override func tile() {
            super.tile()
            if let documentView, documentView.frame.size != frame.size {
                documentView.setFrameSize(frame.size)
            }
        }
    }
}

// MARK: - Video

@MainActor
final class PlayerBox: ObservableObject {
    let player = AVPlayer()
    @Published var failed = false
    private var observation: NSKeyValueObservation?

    /// Mientras se reproduce directo del disco, quien entrega los bytes.
    private var source: DiskAsset?

    /// Reproduce el archivo ya copiado o, si todavía no existe, directo del disco escaneado.
    func load(url: URL?, source: DiskAsset?) {
        stop()
        failed = false
        let item: AVPlayerItem
        if let url {
            item = AVPlayerItem(url: url)
        } else if let source {
            self.source = source
            item = AVPlayerItem(asset: source.asset)
        } else {
            failed = true
            return
        }
        observation = item.observe(\.status) { [weak self] item, _ in
            let broken = item.status == .failed
            Task { @MainActor in if broken { self?.failed = true } }
        }
        player.replaceCurrentItem(with: item)
    }

    func stop() {
        player.pause()
        observation = nil
        player.replaceCurrentItem(with: nil)
        source?.close()
        source = nil
    }

    func toggle() {
        if player.timeControlStatus == .paused { player.play() } else { player.pause() }
    }
}

struct PlayerPreview: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var focus: Focus
    @ObservedObject var item: Item
    let large: Bool
    @StateObject private var box = PlayerBox()

    /// Con el visor grande abierto, el reproductor del panel se apaga: así no hay dos videos
    /// decodificándose (ni sonando) a la vez.
    private var active: Bool { large || !focus.viewerOpen }

    var body: some View {
        ZStack {
            Color.black
            if !active {
                if let poster = ThumbnailStore.shared.cached(item.id) {
                    Image(nsImage: poster).resizable().scaledToFit().opacity(0.5)
                }
            } else if box.failed {
                VStack(spacing: 10) {
                    if let poster = ThumbnailStore.shared.cached(item.id) {
                        Image(nsImage: poster).resizable().scaledToFit().frame(maxHeight: 120).opacity(0.6)
                    }
                    Label("No se puede reproducir aquí", systemImage: "play.slash")
                        .font(.callout.weight(.medium))
                    Text("El video puede estar incompleto o usar un formato que macOS no reproduce.")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Button("Abrir con otra app…") { model.openExternally(item) }
                }
                .foregroundStyle(.white)
                .padding(16)
            } else {
                PlayerSurface(player: box.player, floating: large)
            }
        }
        .frame(height: large ? nil : 240)
        .modifier(PreviewFrame(large: large))
        .onReceive(NotificationCenter.default.publisher(for: .viewerPlayPause)) { _ in
            if large { box.toggle() }
        }
        .task(id: active) {
            if active {
                box.load(url: item.localURL, source: item.localURL == nil ? model.streamingAsset(for: item) : nil)
            } else {
                box.stop()
            }
        }
        .onChange(of: focus.viewerOpen) { _, open in
            // La hoja del visor tarda en desaparecer: el video se corta apenas se pide cerrarla.
            if large, !open { box.stop() }
        }
        .onDisappear { box.stop() }
    }
}

private struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    let floating: Bool

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = floating ? .floating : .inline
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player = nil
    }
}

// MARK: - Audio, PDF y texto

struct NativeAudioPreview: View {
    @EnvironmentObject var focus: Focus
    let url: URL
    let title: String
    var large = false
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var timeObserver: Any?
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var scrubbing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: isPlaying ? "waveform" : "music.note")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                    .frame(width: 44, height: 44)
                    .background(Palette.accent.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).lineLimit(1).truncationMode(.middle)
                    Text("\(formatTime(currentTime)) / \(formatTime(duration))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { togglePlay() } label: {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(Palette.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPlaying ? "Pausar" : "Reproducir")
            }
            if duration > 0 {
                Slider(value: Binding(get: { min(currentTime, duration) }, set: { currentTime = $0 }), in: 0...duration) { editing in
                    scrubbing = editing
                    if !editing { player?.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600)) }
                }
                .controlSize(.small)
                .tint(Palette.accent)
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .task(id: url) { setup() }
        .onDisappear { teardown() }
        .onReceive(NotificationCenter.default.publisher(for: .viewerPlayPause)) { _ in
            if large { togglePlay() }
        }
        .onChange(of: focus.viewerOpen) { _, open in
            // El visor grande trae su propio reproductor: el del panel se calla.
            if open, !large, isPlaying { togglePlay() }
        }
    }

    private func setup() {
        teardown()
        let p = AVPlayer(url: url)
        player = p
        currentTime = 0
        duration = 0
        Task {
            if let seconds = try? await p.currentItem?.asset.load(.duration).seconds, seconds.isFinite, seconds > 0 {
                duration = seconds
            }
        }
        timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { time in
            let seconds = time.seconds
            if seconds.isFinite, !scrubbing { currentTime = seconds }
            if duration > 0, seconds >= duration - 0.05 {
                isPlaying = false
                p.pause()
                p.seek(to: .zero)
                currentTime = 0
            }
        }
    }

    private func teardown() {
        player?.pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player = nil
        isPlaying = false
    }

    private func togglePlay() {
        guard let player else { return }
        if isPlaying { player.pause() } else { player.play() }
        isPlaying.toggle()
    }

    private func formatTime(_ s: Double) -> String {
        let t = max(0, Int(s.rounded()))
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

struct PDFKitRepresentable: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.document = PDFDocument(url: url)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url { view.document = PDFDocument(url: url) }
    }
}

struct NativeTextPreview: View {
    let url: URL
    let large: Bool
    @State private var text = ""

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(size: large ? 13 : 11, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(large ? 20 : 10)
                .textSelection(.enabled)
        }
        .frame(height: large ? nil : 220)
        .background(Color(nsColor: .textBackgroundColor))
        .modifier(PreviewFrame(large: large))
        .task(id: url) {
            let source = url
            text = await DiskWork.run {
                guard let data = try? Data(contentsOf: source, options: .mappedIfSafe) else { return "" }
                let sample = data.prefix(256 * 1024)
                return String(data: sample, encoding: .utf8) ?? String(data: sample, encoding: .isoLatin1)
                    ?? "Contenido binario: no se puede mostrar como texto."
            }
        }
    }
}

// MARK: - Visor grande

extension Notification.Name {
    /// La barra espaciadora en el visor sobre un audio o un video.
    static let viewerPlayPause = Notification.Name("recuperador.visor.reproducir")
}

/// Visor grande sobre la ventana, para el archivo seleccionado.
/// ← → (o la tira de abajo): anterior / siguiente. Espacio o Esc: cerrar (en audio y video, el
/// espacio reproduce). + − 0, pellizco o doble clic: zoom.
struct ViewerOverlay: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var focus: Focus
    @StateObject private var zoom = ZoomController()
    @StateObject private var enhancer = Enhancer()
    @FocusState private var keys: Bool

    var body: some View {
        let item = model.focused
        let currentID: Int? = item?.id
        VStack(spacing: 0) {
            ZStack {
                if let item {
                    FilePreview(item: item, large: true, zoom: zoom, enhancer: enhancer).id(item.id)
                } else {
                    ContentUnavailableView("Selecciona un archivo", systemImage: "eye")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .leading) { arrow("chevron.left", -1, help: "Anterior (←)") }
            .overlay(alignment: .trailing) { arrow("chevron.right", 1, help: "Siguiente (→)") }
            Filmstrip(current: currentID) { go(to: $0) }
            Divider()
            bar(item)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .focusable(true)
        .focusEffectDisabled()
        .focused($keys)
        .onAppear {
            keys = true
            enhancer.reset(for: model.focused)
        }
        .onKeyPress(phases: [.down, .repeat], action: key)
        .onChange(of: currentID) {
            zoom.magnification = 1
            enhancer.reset(for: model.focused)
        }
        .accessibilityAddTraits(.isModal)
    }

    private var kind: PreviewKind? { model.focused.map { PreviewKind($0.file) } }

    private func key(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .leftArrow, .upArrow: go(-1)
        case .rightArrow, .downArrow: go(1)
        case .escape: close()
        case .space:
            if kind == .video || kind == .audio {
                NotificationCenter.default.post(name: .viewerPlayPause, object: nil)
            } else {
                close()
            }
        default:
            guard kind == .image else { return .ignored }
            switch press.characters {
            case "+", "=": zoom.zoom(by: 1.5)
            case "-": zoom.zoom(by: 1 / 1.5)
            case "0": zoom.reset()
            default: return .ignored
            }
        }
        return .handled
    }

    /// Paso al archivo vecino, con un fundido corto para que el cambio no sea brusco.
    private func go(_ delta: Int) {
        Crossfade.next(0.14)
        model.step(delta)
    }

    private func go(to id: Int) {
        guard id != model.focused?.id else { return }
        Crossfade.next(0.14)
        model.select([id])
    }

    private func close() { model.viewerOpen = false }

    private func arrow(_ symbol: String, _ delta: Int, help: String) -> some View {
        Button { go(delta) } label: {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 38, height: 38)
                .background(.regularMaterial, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .help(help)
        .padding(14)
    }

    @ViewBuilder private func bar(_ item: Item?) -> some View {
        HStack(spacing: 14) {
            if let item {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.headline).lineLimit(1).truncationMode(.middle)
                    Text(subtitle(item)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                .layoutPriority(1)
                HealthBadge(health: item.health)
            }
            Spacer(minLength: 8)
            if let item, PreviewKind(item.file) == .image {
                EnhanceControls(enhancer: enhancer, item: item)
                ControlGroup {
                    Button { zoom.zoom(by: 1 / 1.5) } label: { Image(systemName: "minus.magnifyingglass") }
                        .help("Alejar (−)")
                    Button("\(Int((zoom.magnification * 100).rounded())) %") { zoom.reset() }
                        .help("Ajustar a la ventana (0)")
                    Button { zoom.zoom(by: 1.5) } label: { Image(systemName: "plus.magnifyingglass") }
                        .help("Acercar (+)")
                }
                .fixedSize()
            }
            if let item {
                if item.loading, let progress = item.progress {
                    ProgressView(value: progress).frame(width: 70).controlSize(.small)
                }
                Button { model.openExternally(item) } label: { Label("Abrir con macOS", systemImage: "arrow.up.forward.app") }
                    .disabled(item.loading)
                Button { close(); model.recover([item]) } label: { Label("Recuperar", systemImage: "arrow.down.doc.fill") }
                    .buttonStyle(.borderedProminent)
            }
            Button("Cerrar") { close() }
                .help("Cerrar (Esc)")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func subtitle(_ item: Item) -> String {
        let results = model.filtered
        let size = ByteCountFormatter.string(fromByteCount: item.file.size, countStyle: .file)
        var parts = [item.file.ext.uppercased(), size]
        if let index = results.firstIndex(where: { $0.id == item.id }) {
            parts.insert("\(index + 1) de \(results.count.formatted())", at: 0)
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// Tira de miniaturas de los archivos vecinos: un clic salta a ese archivo.
private struct Filmstrip: View {
    @EnvironmentObject var model: AppModel
    let current: Int?
    let go: (Int) -> Void

    var body: some View {
        let results = model.filtered
        let index = current.flatMap { id in results.firstIndex { $0.id == id } } ?? 0
        let window = results.isEmpty ? [] : Array(results[max(0, index - 12)...min(results.count - 1, index + 12)])
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(window) { item in
                        FilmThumb(item: item, current: item.id == current)
                            .id(item.id)
                            .onTapGesture { go(item.id) }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .frame(height: 64)
            .onAppear { if let current { proxy.scrollTo(current, anchor: .center) } }
            .onChange(of: current) { _, id in
                guard let id else { return }
                withAnimation(.snappy(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .background(.bar)
    }
}

private struct FilmThumb: View {
    @ObservedObject var item: Item
    let current: Bool
    @State private var image: NSImage?
    @State private var hovering = false

    var body: some View {
        ZStack {
            if let shown = image ?? ThumbnailStore.shared.cached(item.id) {
                Image(nsImage: shown).resizable().scaledToFill()
            } else {
                ResultFileIcon(category: item.category, size: 30)
            }
        }
        .frame(width: 64, height: 48)
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(current ? Palette.accent : .primary.opacity(hovering ? 0.35 : 0.1), lineWidth: current ? 2.5 : 1))
        .opacity(current || hovering ? 1 : 0.7)
        .scaleEffect(hovering && !current ? 1.06 : 1)
        .animation(.snappy(duration: 0.15), value: hovering)
        .onHover { hovering = $0 }
        .help(item.name)
        .task {
            guard image == nil, ThumbnailStore.shared.cached(item.id) == nil else { return }
            image = await ThumbnailStore.shared.thumbnail(for: item)
        }
    }
}

/// Botón que se hunde un poco al apretarlo.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
    }
}
