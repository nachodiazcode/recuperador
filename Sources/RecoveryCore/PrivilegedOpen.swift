import Darwin
import Foundation

public enum PrivilegedOpenError: LocalizedError {
    case spawn(Int32)
    case cancelled
    case protectedBySystem
    case busy
    case other(String)

    public var errorDescription: String? {
        switch self {
        case let .spawn(code):
            return "No se pudo mostrar el diálogo de autorización de macOS (código \(code)). Cierra y vuelve a abrir Recuperador."
        case .cancelled:
            return "Cancelaste el diálogo de contraseña. Sin tu autorización, macOS no deja leer el disco directamente. Vuelve a intentarlo cuando quieras."
        case .protectedBySystem:
            return "macOS protege este disco: es el SSD interno de tu Mac, y la Protección de Integridad del Sistema impide leerlo en crudo, incluso con tu contraseña de administrador. Recuperador está pensado para discos externos, pendrives y tarjetas SD."
        case .busy:
            return "Otro programa está usando el disco en este momento (quizás una revisión o reparación de macOS). Espera a que termine y vuelve a intentarlo."
        case let .other(detail):
            return "macOS no permitió abrir el disco: \(detail)"
        }
    }
}

/// Abre un disco crudo con permisos de administrador usando `authopen`, la herramienta del
/// sistema pensada para esto: muestra el diálogo de contraseña estándar de macOS y nos pasa el
/// descriptor de archivo por un socket. Así la app no necesita ejecutarse como root.
public enum PrivilegedOpen {
    public static func open(_ path: String) throws -> Int32 {
        var sockets: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else { throw PrivilegedOpenError.spawn(errno) }
        defer { close(sockets[0]) }

        // authopen explica en stderr por qué no pudo abrir el disco; lo capturamos para decírselo al usuario.
        let errorPipe = Pipe()
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, sockets[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, errorPipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
        let args = ["/usr/libexec/authopen", "-stdoutpipe", "-o", String(O_RDONLY), path]
        var cArgs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, args[0], &actions, nil, &cArgs, environ)
        posix_spawn_file_actions_destroy(&actions)
        cArgs.forEach { free($0) }
        close(sockets[1])
        try? errorPipe.fileHandleForWriting.close()
        guard rc == 0 else { throw PrivilegedOpenError.spawn(rc) }

        var fd: Int32 = -1
        var byte: UInt8 = 0
        var control = [UInt8](repeating: 0, count: 64)
        withUnsafeMutablePointer(to: &byte) { bytePointer in
            var iov = iovec(iov_base: bytePointer, iov_len: 1)
            withUnsafeMutablePointer(to: &iov) { iovPointer in
                control.withUnsafeMutableBytes { buffer in
                    var message = msghdr(msg_name: nil, msg_namelen: 0, msg_iov: iovPointer, msg_iovlen: 1,
                                         msg_control: buffer.baseAddress, msg_controllen: socklen_t(buffer.count), msg_flags: 0)
                    // cmsghdr en Darwin: longitud (4), nivel (4), tipo (4) y luego el descriptor.
                    guard recvmsg(sockets[0], &message, 0) >= 0, message.msg_controllen >= 16,
                          buffer.load(fromByteOffset: 4, as: Int32.self) == SOL_SOCKET,
                          buffer.load(fromByteOffset: 8, as: Int32.self) == SCM_RIGHTS else { return }
                    fd = buffer.load(fromByteOffset: 12, as: Int32.self)
                }
            }
        }
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        guard fd < 0 else { return fd }
        let message = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").first { !$0.contains("send_fd") }.map(String.init) ?? ""
        if message.contains("Operation not permitted") { throw PrivilegedOpenError.protectedBySystem }
        if message.contains("busy") { throw PrivilegedOpenError.busy }
        if message.isEmpty || message.localizedCaseInsensitiveContains("cancel") || message.contains("authoriz") {
            throw PrivilegedOpenError.cancelled
        }
        throw PrivilegedOpenError.other(message.replacingOccurrences(of: "authopen: ", with: ""))
    }
}
