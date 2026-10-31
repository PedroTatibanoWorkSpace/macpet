import Charts
import SwiftUI

struct MetricDetailView: View {
    let metric: Metric
    @EnvironmentObject private var monitor: SystemMonitor
    @EnvironmentObject private var env: AppEnvironment
    @State private var range: HistoryRange = .hour

    private var snapshot: SystemSnapshot { monitor.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(metric.title).font(.headline)
                Spacer()
                Text(headline).font(.system(.title2, design: .rounded).weight(.semibold)).monospacedDigit()
            }

            if !series.isEmpty {
                MPTabs(items: HistoryRange.allCases.map { .init(value: $0, label: $0.rawValue) }, selection: $range)
                    .fixedSize()

                HistoryChart(series: series, range: range, unit: chartUnit)
                    .frame(height: 110)
            }

            details

            MPDivider()
            HStack(spacing: 4) {
                Button("Preferências…") { env.openSettings() }
                Button("Modo limpeza…") { env.cleaning.showPanel() }
                Spacer()
                Button("Sair do MacPet") { NSApp.terminate(nil) }
            }
            .buttonStyle(.mp(.ghost, size: .sm))
            .font(.callout)
        }
        .padding(14)
        .frame(width: 340)
    }

    private var headline: String {
        switch metric {
        case .temperature: Format.temperature(snapshot.temperature)
        case .network: "↓ \(Format.rate(snapshot.netIn))"
        case .thermal: snapshot.thermal.label
        case .disk: Format.percent(snapshot.disk.fraction)
        case .memory: Format.percent(snapshot.memory.fraction)
        case .cpu: Format.percent(snapshot.cpu)
        }
    }

    private var series: [Series] {
        switch metric {
        case .temperature, .thermal: [.temperature]
        case .network: [.netIn, .netOut]
        case .disk: [.disk]
        case .memory: [.memory]
        case .cpu: [.cpu]
        }
    }

    private var chartUnit: ChartUnit {
        switch metric {
        case .temperature, .thermal: .celsius
        case .network: .rate
        default: .percent
        }
    }

    @ViewBuilder
    private var details: some View {
        switch metric {
        case .cpu:
            ProcessList(sortBy: .cpu)
        case .memory:
            let memory = snapshot.memory
            InfoGrid(rows: [
                ("Apps", Format.bytes(memory.app)),
                ("Wired", Format.bytes(memory.wired)),
                ("Comprimida", Format.bytes(memory.compressed)),
                ("Cache", Format.bytes(memory.cached)),
                ("Swap", Format.bytes(memory.swapUsed)),
                ("Total", Format.bytes(memory.total)),
            ])
            ProcessList(sortBy: .memory)
        case .disk:
            InfoGrid(rows: [
                ("Usado", Format.bytes(snapshot.disk.used)),
                ("Disponível", Format.bytes(snapshot.disk.available)),
                ("Total", Format.bytes(snapshot.disk.total)),
            ])
        case .temperature, .thermal:
            InfoGrid(rows: [
                ("CPU (núcleo mais quente)", Format.temperature(snapshot.temperature)),
                ("Bateria", Format.temperature(snapshot.batteryTemperature)),
                ("Pressão térmica", snapshot.thermal.label),
            ])
            Text(thermalHint).font(.caption).foregroundStyle(Theme.textMuted)
        case .network:
            InfoGrid(rows: [
                ("Interface", monitor.networkReader.interfaceName ?? "—"),
                ("Download", Format.rate(snapshot.netIn)),
                ("Upload", Format.rate(snapshot.netOut)),
                ("Baixado desde a abertura", Format.bytes(monitor.networkReader.totalIn)),
                ("Enviado desde a abertura", Format.bytes(monitor.networkReader.totalOut)),
            ])
        }
    }

    private var thermalHint: String {
        switch snapshot.thermal {
        case .nominal: "Sem limitação de desempenho. Este MacBook Air não tem ventoinha: em calor alto o macOS reduz a velocidade da CPU."
        case .fair: "Começando a esquentar; o macOS pode reduzir um pouco o desempenho."
        case .serious: "O macOS está reduzindo o desempenho para resfriar o Mac."
        case .critical: "Limitação forte de desempenho. Feche processos pesados."
        @unknown default: ""
        }
    }
}

struct InfoGrid: View {
    let rows: [(String, String)]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            ForEach(rows, id: \.0) { row in
                GridRow {
                    Text(row.0).foregroundStyle(Theme.textMuted)
                    Text(row.1).monospacedDigit().gridColumnAlignment(.trailing)
                }
            }
        }
        .font(.callout)
    }
}

enum ChartUnit {
    case percent, celsius, rate

    func format(_ value: Double) -> String {
        switch self {
        case .percent: "\(Int(value))%"
        case .celsius: "\(Int(value))°"
        case .rate: Format.rate(value)
        }
    }
}

struct HistoryChart: View {
    let series: [Series]
    let range: HistoryRange
    let unit: ChartUnit
    @EnvironmentObject private var monitor: SystemMonitor

    var body: some View {
        // Lê `monitor.snapshot` para redesenhar a cada amostra.
        let _ = monitor.snapshot.date
        Chart {
            ForEach(series, id: \.self) { item in
                ForEach(monitor.history.points(item, range: range)) { point in
                    LineMark(x: .value("Hora", point.date), y: .value("Valor", point.value))
                        .foregroundStyle(by: .value("Série", label(item)))
                        .interpolationMethod(.monotone)
                }
            }
        }
        .chartForegroundStyleScale(range: [Theme.sheen, Theme.ember])
        .chartLegend(series.count > 1 ? .visible : .hidden)
        .chartYScale(domain: .automatic(includesZero: true))
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                AxisValueLabel { Text(value.as(Double.self).map(unit.format) ?? "") }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine()
                AxisValueLabel(format: range == .week ? .dateTime.weekday(.abbreviated) : .dateTime.hour().minute())
            }
        }
    }

    private func label(_ series: Series) -> String {
        switch series {
        case .netIn: "Download"
        case .netOut: "Upload"
        default: series.rawValue
        }
    }
}

struct ProcessList: View {
    enum Sort { case cpu, memory }

    let sortBy: Sort
    @EnvironmentObject private var monitor: SystemMonitor

    private var top: [ProcessUsage] {
        let sorted = monitor.processes.sorted {
            sortBy == .cpu ? $0.cpu > $1.cpu : $0.memory > $1.memory
        }
        return Array(sorted.prefix(8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Processos").font(.subheadline.weight(.semibold))
            if top.isEmpty {
                Text("Coletando…").font(.callout).foregroundStyle(Theme.textMuted)
            }
            ForEach(top) { process in
                HStack(spacing: 6) {
                    Text(process.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(sortBy == .cpu ? String(format: "%.0f%%", process.cpu * 100) : Format.bytes(process.memory))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textMuted)
                    MPMenuButton(entries: {[
                        .header(process.name),
                        .item("Encerrar", icon: "xmark.circle") { monitor.terminate(process, force: false) },
                        .item("Forçar encerramento", icon: "bolt.slash", danger: true) { monitor.terminate(process, force: true) },
                    ]}) {
                        Image(systemName: "xmark.circle").foregroundStyle(Theme.textMuted).frame(width: 20, height: 20).contentShape(Rectangle())
                    }
                    .fixedSize()
                    .help("Encerrar \(process.name)")
                }
                .font(.callout)
            }
        }
    }
}
