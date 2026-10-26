import Darwin
import Foundation
import SwiftUI

struct MemoryStats: Equatable {
    var total: Double = 0
    var appMemory: Double = 0
    var fileCache: Double = 0
    var compressed: Double = 0
    var free: Double = 0

    var usedFraction: Double { total > 0 ? (appMemory + compressed) / total : 0 }
    var cacheFraction: Double { total > 0 ? fileCache / total : 0 }

    static func read() -> MemoryStats {
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return MemoryStats() }
        let page = Double(vm_kernel_page_size)
        var s = MemoryStats()
        s.total = Double(ProcessInfo.processInfo.physicalMemory)
        s.appMemory = (Double(vm.internal_page_count) - Double(vm.purgeable_count) + Double(vm.wire_count)) * page
        s.compressed = Double(vm.compressor_page_count) * page
        s.fileCache = (Double(vm.external_page_count) + Double(vm.purgeable_count)) * page
        s.free = Double(vm.free_count) * page
        return s
    }
}

/// Una carpeta de caché que se puede vaciar sin riesgo: las apps la regeneran cuando la necesitan.
struct CleanTarget: Identifiable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let folder: URL
    var children: [(url: URL, size: Int64)] = []
    var measured = false
    var size: Int64 { children.reduce(0) { $0 + $1.size } }
}

@MainActor
final class CleanerModel: ObservableObject {
    enum State: Equatable { case idle, measuring, ready, cleaning, done }

    @Published var memory = MemoryStats()
    @Published var memoryBefore: MemoryStats?
    @Published var purging = false
    @Published var purgeMessage: String?

    @Published var targets: [CleanTarget] = []
    @Published var selected = Set<String>()
    @Published var state: State = .idle
    @Published var progress = 0.0
    @Published var current = ""
    @Published var freed: Int64 = 0

    private var timer: Timer?

    init() {
        memory = MemoryStats.read()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.memory = MemoryStats.read() }
        }
    }

    var selectedSize: Int64 { targets.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.size } }

    // MARK: RAM

    /// `purge` vacía la caché de archivos en RAM y necesita permisos de administrador.
    /// La primera vez se instala una regla en /etc/sudoers.d que permite SOLO ese comando sin
    /// contraseña (macOS la pide una única vez); desde entonces el botón es instantáneo.
    func purgeMemory() {
        guard !purging else { return }
        purging = true
        purgeMessage = nil
        memoryBefore = MemoryStats.read()
        Task.detached {
            var ok = Self.run("/usr/bin/sudo", ["-n", "/usr/sbin/purge"]) == 0
            if !ok {
                let rule = "\(NSUserName()) ALL=(root) NOPASSWD: /usr/sbin/purge"
                let shell = "t=$(mktemp) && printf '%s\\n' '\(rule)' > $t && /usr/sbin/visudo -cf $t && "
                    + "/usr/bin/install -m 0440 -o root -g wheel $t /etc/sudoers.d/recuperador-purge && rm -f $t && /usr/sbin/purge"
                let script = "do shell script \"\(shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
                ok = Self.run("/usr/bin/osascript", ["-e", script]) == 0
            }
            try? await Task.sleep(for: .milliseconds(600))
            let success = ok
            await MainActor.run {
                let after = MemoryStats.read()
                self.memory = after
                self.purging = false
                if success, let before = self.memoryBefore {
                    let gained = max(0, before.fileCache - after.fileCache)
                    self.purgeMessage = "Listo: liberaste \(ByteCountFormatter.string(fromByteCount: Int64(gained), countStyle: .memory)) de RAM"
                    Signals.play(.tap)
                } else {
                    self.purgeMessage = "No se liberó memoria: se canceló la autorización"
                    Signals.play(.low)
                }
            }
        }
    }

    nonisolated private static func run(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    // MARK: Disco

    func measure(excludingRecuperador: Bool) {
        state = .measuring
        freed = 0
        let home = FileManager.default.homeDirectoryForCurrentUser
        var list = [
            CleanTarget(id: "caches", title: "Cachés de apps", detail: "Navegadores, Spotify, Homebrew, pip, Slack…",
                        symbol: "square.stack.3d.down.forward.fill", folder: home.appendingPathComponent("Library/Caches")),
            CleanTarget(id: "logs", title: "Registros", detail: "Archivos .log que las apps acumulan",
                        symbol: "list.bullet.rectangle.fill", folder: home.appendingPathComponent("Library/Logs")),
            CleanTarget(id: "derived", title: "Xcode DerivedData", detail: "Compilaciones intermedias; Xcode las rehace",
                        symbol: "hammer.fill", folder: home.appendingPathComponent("Library/Developer/Xcode/DerivedData")),
            CleanTarget(id: "npm", title: "Caché de npm", detail: "Paquetes descargados de Node.js",
                        symbol: "shippingbox.fill", folder: home.appendingPathComponent(".npm/_cacache")),
            CleanTarget(id: "gradle", title: "Caché de Gradle", detail: "Dependencias de Java/Android",
                        symbol: "cup.and.saucer.fill", folder: home.appendingPathComponent(".gradle/caches")),
        ]
        list = list.filter { FileManager.default.fileExists(atPath: $0.folder.path) }
        targets = list
        // Cada carpeta se mide en paralelo y su tamaño se actualiza en vivo a medida que se cuenta.
        Task.detached(priority: .userInitiated) {
            await withTaskGroup(of: Void.self) { group in
                for (i, target) in list.enumerated() {
                    group.addTask {
                        let kids = (try? FileManager.default.contentsOfDirectory(at: target.folder, includingPropertiesForKeys: nil)) ?? []
                        _ = await MainActor.run { self.selected.insert(target.id) }
                        for kid in kids where !(excludingRecuperador && kid.lastPathComponent == "Recuperador") {
                            let entry = (kid, Self.allocatedSize(kid))
                            await MainActor.run {
                                self.targets[i].children.append(entry)
                            }
                        }
                        await MainActor.run {
                            self.targets[i].children.sort { $0.size > $1.size }
                            self.targets[i].measured = true
                        }
                    }
                }
            }
            await MainActor.run { self.state = .ready }
        }
    }

    func clean() {
        let chosen = targets.filter { selected.contains($0.id) }
        let total = max(1, chosen.reduce(0) { $0 + $1.size })
        state = .cleaning
        progress = 0
        freed = 0
        Task.detached(priority: .userInitiated) {
            var done: Int64 = 0
            for target in chosen {
                for (url, size) in target.children {
                    let ok = (try? FileManager.default.removeItem(at: url)) != nil
                    done += size
                    let freedNow = ok ? size : 0, progress = Double(done) / Double(total), name = "\(target.title) · \(url.lastPathComponent)"
                    await MainActor.run {
                        self.freed += freedNow
                        self.progress = progress
                        self.current = name
                    }
                }
            }
            try? await Task.sleep(for: .milliseconds(300))
            await MainActor.run {
                self.progress = 1
                self.state = .done
                self.current = ""
                Signals.cleaned(bytes: self.freed)
            }
        }
    }

    nonisolated static func allocatedSize(_ url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        if let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true {
            return Int64(v.totalFileAllocatedSize ?? 0)
        }
        var total: Int64 = 0
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })
        while let f = e?.nextObject() as? URL {
            total += Int64((try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
