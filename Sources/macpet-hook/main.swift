// Chamado pelos hooks do Claude Code. Lê o JSON do evento no stdin, anexa dados do terminal
// e repassa para o MacPet via Unix socket. Nunca falha nem imprime nada: o Claude Code não
// pode ficar esperando ou exibir erro por causa do MacPet.
import Darwin
import Foundation

func processName(_ pid: pid_t) -> String {
    var buffer = [CChar](repeating: 0, count: 256)
    proc_name(pid, &buffer, UInt32(buffer.count))
    return String(cString: buffer)
}

func parentPid(_ pid: pid_t) -> pid_t? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    return pid_t(info.pbi_ppid)
}

/// O hook roda via `sh -c`, então sobe pelos shells até achar o processo do Claude.
func claudePid() -> pid_t {
    let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish"]
    var pid = getppid()
    for _ in 0..<4 where shells.contains(processName(pid)) {
        guard let parent = parentPid(pid), parent > 1 else { break }
        pid = parent
    }
    return pid
}

let input = FileHandle.standardInput.readDataToEndOfFile()
var event = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] ?? [:]
// `macpet-hook statusline`: usado como statusLine do Claude Code. Recebe limites do plano,
// contexto e modelo; repassa ao app, guarda a última leitura e imprime a linha de status.
let isStatusLine = CommandLine.arguments.dropFirst().first == "statusline"
if isStatusLine {
    event["hook_event_name"] = "StatusLine"
} else if event["hook_event_name"] == nil, CommandLine.arguments.count > 1 {
    event["hook_event_name"] = CommandLine.arguments[1]
}

let env = ProcessInfo.processInfo.environment
var meta: [String: Any] = ["claude_pid": Int(claudePid())]
meta["term_program"] = env["TERM_PROGRAM"]
meta["bundle_id"] = env["__CFBundleIdentifier"]
meta["iterm_session_id"] = env["ITERM_SESSION_ID"]
meta["tmux"] = env["TMUX"]
event["_macpet"] = meta

func percent(_ value: Any?) -> Int? {
    (value as? Double).map { Int($0.rounded()) } ?? (value as? Int)
}

if isStatusLine {
    let limits = event["rate_limits"] as? [String: Any]
    if let limits {
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".macpet")
        let record: [String: Any] = ["updated_at": Date().timeIntervalSince1970, "rate_limits": limits]
        if let data = try? JSONSerialization.data(withJSONObject: record) {
            try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            try? data.write(to: support.appendingPathComponent("limits.json"), options: .atomic)
        }
    }
    var parts: [String] = []
    if let model = (event["model"] as? [String: Any])?["display_name"] as? String { parts.append(model) }
    if let context = percent((event["context_window"] as? [String: Any])?["used_percentage"]) { parts.append("ctx \(context)%") }
    if let five = percent((limits?["five_hour"] as? [String: Any])?["used_percentage"]) { parts.append("5h \(five)%") }
    if let week = percent((limits?["seven_day"] as? [String: Any])?["used_percentage"]) { parts.append("sem \(week)%") }
    print(parts.joined(separator: " · "))
}

guard let payload = try? JSONSerialization.data(withJSONObject: event) else { exit(0) }

let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".macpet/macpet.sock").path
let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { exit(0) }

var timeout = timeval(tv_sec: 1, tv_usec: 0)
setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
let capacity = MemoryLayout.size(ofValue: addr.sun_path)
_ = withUnsafeMutablePointer(to: &addr.sun_path) {
    $0.withMemoryRebound(to: CChar.self, capacity: capacity) { strlcpy($0, path, capacity) }
}
let connected = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
}
// App fechado: o socket não existe e simplesmente saímos.
if connected == 0 {
    payload.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
            if written <= 0 { break }
            offset += written
        }
    }
}
close(fd)
exit(0)
