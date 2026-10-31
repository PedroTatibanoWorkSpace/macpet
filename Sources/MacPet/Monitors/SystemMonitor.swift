import Foundation

/// Itens que podem aparecer na barra de menu.
enum Metric: String, CaseIterable, Codable, Identifiable {
    case temperature, network, thermal, disk, memory, cpu

    var id: String { rawValue }

    /// THR fica de fora por padrão: o TEM já fica vermelho quando o Mac está limitando desempenho.
    static let defaultModules: [Metric] = [.temperature, .network, .disk, .memory, .cpu]

    var shortLabel: String {
        switch self {
        case .temperature: "TEM"
        case .network: "NET"
        case .thermal: "THR"
        case .disk: "SSD"
        case .memory: "MEM"
        case .cpu: "CPU"
        }
    }

    var title: String {
        switch self {
        case .temperature: "Temperatura"
        case .network: "Rede"
        case .thermal: "Pressão térmica"
        case .disk: "Disco"
        case .memory: "Memória"
        case .cpu: "CPU"
        }
    }
}

struct SystemSnapshot {
    var date = Date()
    var cpu: Double = 0
    var memory = MemoryInfo()
    var disk = DiskInfo()
    var temperature: Double?
    var batteryTemperature: Double?
    var thermal: ProcessInfo.ThermalState = .nominal
    var netIn: Double = 0
    var netOut: Double = 0
}

extension ProcessInfo.ThermalState {
    var label: String {
        switch self {
        case .nominal: "Normal"
        case .fair: "Moderada"
        case .serious: "Alta"
        case .critical: "Crítica"
        @unknown default: "?"
        }
    }

    var shortLabel: String {
        switch self {
        case .nominal: "OK"
        case .fair: "MOD"
        case .serious: "ALTA"
        case .critical: "CRIT"
        @unknown default: "?"
        }
    }
}

/// Coleta as métricas periodicamente e distribui para a barra, histórico, alertas e pet.
@MainActor
final class SystemMonitor: ObservableObject {
    @Published private(set) var snapshot = SystemSnapshot()
    @Published private(set) var processes: [ProcessUsage] = []

    let history: HistoryStore
    let networkReader = NetworkReader()
    private let cpuReader = CPUReader()
    private let processSampler = ProcessSampler()
    private var timer: Timer?
    private var processWatchers = 0
    private var lastDiskRead = Date.distantPast
    private var lastTemperatureRead = Date.distantPast
    private var observers: [(SystemSnapshot) -> Void] = []

    init(history: HistoryStore) {
        self.history = history
    }

    func onSample(_ observer: @escaping (SystemSnapshot) -> Void) {
        observers.append(observer)
    }

    func start(interval: TimeInterval) {
        timer?.invalidate()
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        timer?.tolerance = interval * 0.1
    }

    /// Painéis que mostram processos se registram aqui; a amostragem só roda enquanto houver alguém olhando.
    func watchProcesses(_ watching: Bool) {
        processWatchers = max(0, processWatchers + (watching ? 1 : -1))
        if watching && processWatchers == 1 {
            processSampler.reset()
            _ = processSampler.sample()
        } else if processWatchers == 0 {
            processes = []
        }
    }

    func terminate(_ process: ProcessUsage, force: Bool) {
        _ = ProcessSampler.terminate(process.pid, force: force)
        processes.removeAll { $0.pid == process.pid }
    }

    private func sample() {
        var next = snapshot
        next.date = Date()
        next.cpu = cpuReader.read()
        next.memory = MemoryReader.read()
        if next.date.timeIntervalSince(lastDiskRead) > 15 {
            next.disk = DiskReader.read()
            lastDiskRead = next.date
        }
        // Os sensores de temperatura são a leitura mais cara e a temperatura muda devagar: a cada 6 s basta.
        if next.date.timeIntervalSince(lastTemperatureRead) >= 6 {
            next.temperature = TemperatureReader.cpu()
            next.batteryTemperature = TemperatureReader.battery()
            lastTemperatureRead = next.date
        }
        next.thermal = ProcessInfo.processInfo.thermalState
        let network = networkReader.read()
        next.netIn = network.input
        next.netOut = network.output
        snapshot = next

        if processWatchers > 0 {
            processes = processSampler.sample()
        }

        history.record(next)
        observers.forEach { $0(next) }
    }
}
