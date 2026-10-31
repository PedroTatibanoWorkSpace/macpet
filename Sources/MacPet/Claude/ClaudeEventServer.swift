import Darwin
import Foundation

enum MacPetPaths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let support = home.appendingPathComponent(".macpet", isDirectory: true)
    static let socket = support.appendingPathComponent("macpet.sock")
    static let hookLink = support.appendingPathComponent("bin/macpet-hook")
}

/// Servidor Unix socket que recebe os eventos enviados pelo `macpet-hook`.
/// Cada conexão carrega um único JSON e é fechada pelo cliente.
final class ClaudeEventServer {
    private let path: String
    private let queue = DispatchQueue(label: "macpet.events")
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let onEvent: ([String: Any]) -> Void

    init(path: String = MacPetPaths.socket.path, onEvent: @escaping ([String: Any]) -> Void) {
        self.path = path
        self.onEvent = onEvent
    }

    func start() {
        try? FileManager.default.createDirectory(at: MacPetPaths.support, withIntermediateDirectories: true)
        unlink(path)

        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return NSLog("MacPet: socket() falhou") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) { strlcpy($0, path, capacity) }
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 32) == 0 else {
            NSLog("MacPet: bind/listen falhou em \(path): \(String(cString: strerror(errno)))")
            close(fd)
            return
        }
        chmod(path, 0o600)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptAll() }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        if fd >= 0 { close(fd) }
        unlink(path)
    }

    private func acceptAll() {
        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            // No BSD o socket aceito herda O_NONBLOCK; voltamos para bloqueante com timeout.
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            var timeout = timeval(tv_sec: 1, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            handle(client)
        }
    }

    private func handle(_ client: Int32) {
        defer { close(client) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while data.count < 4 * 1024 * 1024 {
            let count = read(client, &buffer, buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        DispatchQueue.main.async { self.onEvent(event) }
    }
}
