import CSensors
import Darwin
import Foundation
import SystemConfiguration

/// Uso agregado da CPU calculado pela diferença de ticks entre duas leituras.
final class CPUReader {
    private var previous: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?

    func read() -> Double {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }

        let ticks = load.cpu_ticks
        let current = (user: UInt64(ticks.0), system: UInt64(ticks.1), idle: UInt64(ticks.2), nice: UInt64(ticks.3))
        defer { previous = current }
        guard let previous else { return 0 }

        let user = current.user &- previous.user
        let system = current.system &- previous.system
        let idle = current.idle &- previous.idle
        let nice = current.nice &- previous.nice
        let total = user + system + idle + nice
        guard total > 0 else { return 0 }
        return Double(user + system + nice) / Double(total)
    }
}

struct MemoryInfo {
    var total: UInt64 = 0
    var used: UInt64 = 0
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var cached: UInt64 = 0
    var swapUsed: UInt64 = 0

    var fraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

/// Mesmo cálculo do "Memória Usada" do Monitor de Atividade: app + wired + comprimida.
enum MemoryReader {
    static func read() -> MemoryInfo {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        var info = MemoryInfo(total: ProcessInfo.processInfo.physicalMemory)
        guard result == KERN_SUCCESS else { return info }

        let page = UInt64(vm_kernel_page_size)
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        info.app = (internalPages > purgeable ? internalPages - purgeable : 0) * page
        info.wired = UInt64(stats.wire_count) * page
        info.compressed = UInt64(stats.compressor_page_count) * page
        info.cached = (UInt64(stats.external_page_count) + purgeable) * page
        info.used = min(info.app + info.wired + info.compressed, info.total)

        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            info.swapUsed = swap.xsu_used
        }
        return info
    }
}

struct DiskInfo {
    var total: Int64 = 0
    var available: Int64 = 0

    var used: Int64 { max(total - available, 0) }
    var fraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

enum DiskReader {
    static func read() -> DiskInfo {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys) else { return DiskInfo() }
        return DiskInfo(
            total: Int64(values.volumeTotalCapacity ?? 0),
            available: values.volumeAvailableCapacityForImportantUsage ?? 0
        )
    }
}

/// Taxa de download/upload da interface principal (Wi-Fi ou cabo).
final class NetworkReader {
    private var previous: (date: Date, input: UInt64, output: UInt64)?
    private var primaryInterface: String?
    private var lastInterfaceLookup = Date.distantPast
    private(set) var totalIn: UInt64 = 0
    private(set) var totalOut: UInt64 = 0

    var interfaceName: String? { primaryInterface }

    func read() -> (input: Double, output: Double) {
        if Date().timeIntervalSince(lastInterfaceLookup) > 10 {
            primaryInterface = Self.lookupPrimaryInterface()
            lastInterfaceLookup = Date()
        }

        let (input, output) = Self.counters(interface: primaryInterface)
        let now = Date()
        defer { previous = (now, input, output) }
        guard let previous else { return (0, 0) }

        let elapsed = now.timeIntervalSince(previous.date)
        guard elapsed > 0 else { return (0, 0) }
        let deltaIn = Self.delta(input, previous.input)
        let deltaOut = Self.delta(output, previous.output)
        totalIn &+= deltaIn
        totalOut &+= deltaOut
        return (Double(deltaIn) / elapsed, Double(deltaOut) / elapsed)
    }

    /// Os contadores de `if_data` são de 32 bits e dão a volta em 4 GB.
    private static func delta(_ current: UInt64, _ previous: UInt64) -> UInt64 {
        current >= previous ? current - previous : current + (UInt64(UInt32.max) + 1) - previous
    }

    private static func lookupPrimaryInterface() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "MacPet" as CFString, nil, nil),
              let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        else { return nil }
        return value["PrimaryInterface"] as? String
    }

    private static func counters(interface: String?) -> (UInt64, UInt64) {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return (0, 0) }
        defer { freeifaddrs(addrs) }

        var input: UInt64 = 0
        var output: UInt64 = 0
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            guard let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  let data = ifa.pointee.ifa_data else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            let matches = interface.map { name == $0 } ?? name.hasPrefix("en")
            guard matches else { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            input += UInt64(stats.ifi_ibytes)
            output += UInt64(stats.ifi_obytes)
        }
        return (input, output)
    }
}

enum TemperatureReader {
    static func cpu() -> Double? {
        let value = csensors_cpu_temperature()
        return value > 0 ? value : nil
    }

    static func battery() -> Double? {
        let value = csensors_battery_temperature()
        return value > 0 ? value : nil
    }
}
