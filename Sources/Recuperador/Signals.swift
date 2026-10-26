import AppKit
import AVFoundation
import UserNotifications

/// Tonos de sintetizador y avisos locales. No hay servidor: el aviso lo publica la propia app
/// cuando termina un trabajo largo, para que se vea aunque la ventana no esté delante.
/// El banner va en silencio: el tono lo toca la app, también si la ventana quedó detrás.
@MainActor
enum Signals {
    private static let soundsKey = "sonidos"
    private static let noticesKey = "avisos"

    static var soundsEnabled: Bool {
        UserDefaults.standard.object(forKey: soundsKey) as? Bool ?? true
    }

    static var noticesEnabled: Bool {
        UserDefaults.standard.object(forKey: noticesKey) as? Bool ?? true
    }

    static func prepare() {
        let center = UNUserNotificationCenter.current()
        center.delegate = NoticeDelegate.shared
        if noticesEnabled { requestAccess() }
    }

    static func requestAccess() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func started() {
        play(.rise)
    }

    static func finished(count: Int, source: String) {
        let body = count == 0 ? "No apareció nada en \(source)." : "\(count) archivos en \(source)."
        deliver(id: "scan", title: "Escaneo listo", body: body, tone: count == 0 ? .air : .chord)
    }

    static func stopped(count: Int, source: String) {
        // El usuario acaba de pulsar Detener: el banner solo aporta si ya se fue a otra app.
        deliver(id: "scan", title: "Escaneo detenido", body: "Quedaron \(count) archivos de \(source).", tone: .tap, onlyWhenInactive: true)
    }

    static func failed(_ message: String) {
        deliver(id: "scan", title: "No se pudo leer el disco", body: message, tone: .low, onlyWhenInactive: true)
    }

    static func recovered(ok: Int, failed: Int) {
        let body = failed == 0 ? "\(ok) archivo(s) listos." : "\(ok) recuperados, \(failed) fallaron."
        deliver(id: "recover", title: "Archivos recuperados", body: body, tone: failed == 0 ? .chord : .mixed)
    }

    static func cleaned(bytes: Int64) {
        let body = bytes == 0
            ? "No había caché que borrar."
            : "Se liberaron \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))."
        deliver(id: "clean", title: "Limpieza lista", body: body, tone: bytes == 0 ? .air : .chord)
    }

    private static var players: [AVAudioPlayer] = []

    static func play(_ tone: Synth.Tone) {
        guard soundsEnabled else { return }
        guard let player = try? AVAudioPlayer(data: Synth.wav(for: tone)) else { return }
        player.volume = 0.9
        players.removeAll { !$0.isPlaying }
        players.append(player)
        player.play()
    }

    private static func deliver(id: String, title: String, body: String, tone: Synth.Tone, onlyWhenInactive: Bool = false) {
        let show = noticesEnabled && (!onlyWhenInactive || !NSApp.isActive)
        play(tone)
        guard show else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

final class NoticeDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NoticeDelegate()

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // El tono ya lo tocó el sinte. El banner entra en silencio para no duplicarlo.
        [.banner, .list]
    }
}
