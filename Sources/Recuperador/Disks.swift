import Darwin
import Foundation
import RecoveryCore

struct DiskInfo: Identifiable, Hashable {
    let id: String // "disk4"
    let name: String
    let size: Int64
    let isInternal: Bool
    let isSolidState: Bool
    let bus: String
    let volumes: [String]
    /// FAT32, NTFS, APFS… según lo que declara la tabla de particiones.
    let formats: [String]
    /// Tiene particiones con datos pero ninguna montada (dañado o con formato que macOS no lee).
    let unmounted: Bool

    var devicePath: String { "/dev/r\(id)" }
    var isImage: Bool { bus == "Disk Image" }
    /// Un SSD interno de Mac: TRIM + cifrado por hardware hacen que casi nada sea recuperable.
    var isUnrecoverableSSD: Bool { isInternal && isSolidState && !isImage }

    var symbol: String {
        if isImage { return "opticaldiscdrive.fill" }
        // Ojo: "SSD" también contiene "SD", por eso se buscan palabras completas.
        let words = "\(bus) \(name)".uppercased().split { !$0.isLetter }
        if words.contains("SD") || words.contains("SDXC") || words.contains("SDHC") { return "sdcard.fill" }
        if isInternal { return "internaldrive.fill" }
        return "externaldrive.fill"
    }

    var kind: String {
        if isImage { return "Imagen de disco" }
        let media = isSolidState ? "SSD" : "Disco"
        return isInternal ? "\(media) interno" : "\(media) externo · \(bus)"
    }
}

enum DiskLister {
    static func list() -> [DiskInfo] {
        guard let root = plist(["list", "-plist"]), let whole = root["WholeDisks"] as? [String] else { return [] }
        let all = (root["AllDisksAndPartitions"] as? [[String: Any]]) ?? []
        return whole.compactMap { id in
            guard let info = plist(["info", "-plist", id]) else { return nil }
            // Los contenedores APFS sintetizados son vistas lógicas de otro disco físico.
            if info["APFSPhysicalStores"] != nil { return nil }
            let entry = all.first { $0["DeviceIdentifier"] as? String == id }
            let partitions = (entry?["Partitions"] as? [[String: Any]]) ?? []
            let dataPartitions = partitions.filter { ($0["Content"] as? String) != "EFI" && ($0["VolumeName"] as? String) != "EFI" }
            var volumes = dataPartitions.compactMap { $0["VolumeName"] as? String }.filter { !$0.isEmpty }
            if let name = entry?["VolumeName"] as? String { volumes.insert(name, at: 0) }
            // Los volúmenes APFS se montan desde su contenedor sintetizado, no desde la partición física.
            let ids = Set(dataPartitions.compactMap { $0["DeviceIdentifier"] as? String })
            let apfsMounted = all.contains { container in
                let stores = (container["APFSPhysicalStores"] as? [[String: Any]])?.compactMap { $0["DeviceIdentifier"] as? String } ?? []
                let vols = container["APFSVolumes"] as? [[String: Any]] ?? []
                return !ids.isDisjoint(with: stores) && vols.contains { $0["MountPoint"] != nil }
            }
            let mounted = dataPartitions.contains { $0["MountPoint"] != nil } || entry?["MountPoint"] != nil || apfsMounted
            let bus = info["BusProtocol"] as? String ?? ""
            let media = (info["MediaName"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            var formats: [String] = []
            for part in dataPartitions {
                guard let content = part["Content"] as? String, let name = friendly(content), !formats.contains(name) else { continue }
                formats.append(name)
            }
            return DiskInfo(id: id,
                            name: volumes.first ?? (media.isEmpty ? id : media),
                            size: (info["Size"] as? NSNumber)?.int64Value ?? 0,
                            isInternal: info["Internal"] as? Bool ?? false,
                            isSolidState: info["SolidState"] as? Bool ?? false,
                            bus: bus,
                            volumes: volumes,
                            formats: formats,
                            unmounted: !dataPartitions.isEmpty && !mounted)
        }
    }

    private static func friendly(_ content: String) -> String? {
        switch content {
        case "Apple_APFS": return "APFS"
        case "Apple_HFS", "Apple_HFSX": return "HFS+"
        case "DOS_FAT_32", "Windows_FAT_32": return "FAT32"
        case "DOS_FAT_16", "Windows_FAT_16": return "FAT16"
        case "Windows_NTFS": return "NTFS"
        case "Microsoft Basic Data": return "NTFS/exFAT"
        case "Linux", "Linux_RAID": return "Linux"
        default:
            if content.localizedCaseInsensitiveContains("exfat") { return "exFAT" }
            return nil
        }
    }

    private static func plist(_ args: [String]) -> [String: Any]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }
}

import DiskArbitration

/// Avisa cuando se conecta o desconecta un disco, para refrescar la lista sin pulsar "Actualizar".
final class DiskWatcher {
    private let session: DASession
    private let onChange: () -> Void

    init?(onChange: @escaping () -> Void) {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return nil }
        self.session = session
        self.onChange = onChange
        DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: DADiskAppearedCallback = { _, context in
            guard let context else { return }
            Unmanaged<DiskWatcher>.fromOpaque(context).takeUnretainedValue().onChange()
        }
        DARegisterDiskAppearedCallback(session, nil, callback, context)
        DARegisterDiskDisappearedCallback(session, nil, callback, context)
    }

    deinit { DASessionUnscheduleFromRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) }
}
