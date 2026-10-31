import AppKit
import Darwin

struct ProcessUsage: Identifiable, Equatable {
    let pid: pid_t
    let name: String
    let cpu: Double        // fração de um núcleo (1.0 = 100% de um núcleo)
    let memory: UInt64     // bytes residentes

    var id: pid_t { pid }
}

/// Amostra todos os processos e calcula o uso de CPU pela diferença de tempo entre leituras.
/// Só roda enquanto algum painel que mostra processos está aberto.
final class ProcessSampler {
    private var previousTimes: [pid_t: UInt64] = [:]
    private var previousDate: Date?
    private var names: [pid_t: String] = [:]
    private let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(info.denom))
    }()

    func reset() {
        previousTimes = [:]
        previousDate = nil
    }

    func sample() -> [ProcessUsage] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        guard count > 0 else { return [] }

        let now = Date()
        let elapsedNs = previousDate.map { UInt64(now.timeIntervalSince($0) * 1_000_000_000) } ?? 0
        var times: [pid_t: UInt64] = [:]
        var result: [ProcessUsage] = []
        result.reserveCapacity(count)

        for pid in pids.prefix(count) where pid > 0 {
            var info = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { continue }

            // No Apple Silicon esses tempos vêm em ticks de mach_absolute_time, não em nanossegundos.
            let ticks = info.pti_total_user + info.pti_total_system
            let cpuNs = ticks * timebase.numer / timebase.denom
            times[pid] = cpuNs

            var cpu = 0.0
            if elapsedNs > 0, let previous = previousTimes[pid], cpuNs >= previous {
                cpu = Double(cpuNs - previous) / Double(elapsedNs)
            }
            result.append(ProcessUsage(pid: pid, name: name(for: pid), cpu: cpu, memory: info.pti_resident_size))
        }

        previousTimes = times
        previousDate = now
        names = names.filter { times[$0.key] != nil }
        return result
    }

    private func name(for pid: pid_t) -> String {
        if let cached = names[pid] { return cached }
        var resolved = NSRunningApplication(processIdentifier: pid)?.localizedName
        if resolved == nil {
            var buffer = [CChar](repeating: 0, count: 256)
            proc_name(pid, &buffer, UInt32(buffer.count))
            resolved = String(cString: buffer)
        }
        let name = (resolved?.isEmpty == false ? resolved! : "pid \(pid)")
        names[pid] = name
        return name
    }

    static func terminate(_ pid: pid_t, force: Bool) -> Bool {
        if let app = NSRunningApplication(processIdentifier: pid) {
            return force ? app.forceTerminate() : app.terminate()
        }
        return kill(pid, force ? SIGKILL : SIGTERM) == 0
    }
}
