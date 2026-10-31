import Foundation

enum Format {
    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    static func temperature(_ celsius: Double?) -> String {
        guard let celsius else { return "--" }
        return "\(Int(celsius.rounded()))°C"
    }

    static func bytes<T: BinaryInteger>(_ value: T) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }

    /// Mesmo formato curto do Stats: "9 KB/s", "1.2 MB/s".
    static func rate(_ bytesPerSecond: Double) -> String {
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var value = bytesPerSecond
        var index = 0
        while value >= 1000 && index < units.count - 1 {
            value /= 1024
            index += 1
        }
        let number = value < 10 && index > 0 ? String(format: "%.1f", value) : String(Int(value.rounded()))
        return "\(number) \(units[index])"
    }

    /// "45 mil", "12,3 mi", "1,98 bi".
    static func tokens(_ value: Int) -> String {
        let number = Double(value)
        func short(_ n: Double, _ unit: String) -> String {
            let text = n < 10 ? String(format: "%.2f", n) : n < 100 ? String(format: "%.1f", n) : String(Int(n.rounded()))
            return text.replacingOccurrences(of: ".", with: ",") + " " + unit
        }
        if number >= 1e9 { return short(number / 1e9, "bi") }
        if number >= 1e6 { return short(number / 1e6, "mi") }
        if number >= 1e3 { return "\(Int((number / 1e3).rounded())) mil" }
        return "\(value)"
    }

    private static let usdFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.locale = Locale(identifier: "pt_BR")
        return formatter
    }()

    static func usd(_ value: Double) -> String {
        usdFormatter.string(from: NSNumber(value: value)) ?? String(format: "US$ %.2f", value)
    }

    /// "2h13", "45 min".
    static func until(_ date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSinceNow))
        if seconds >= 86_400 { return "\(seconds / 86_400)d \((seconds % 86_400) / 3600)h" }
        if seconds >= 3600 { return "\(seconds / 3600)h\(String(format: "%02d", (seconds % 3600) / 60))" }
        return "\(seconds / 60) min"
    }

    static func relative(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "agora" }
        if seconds < 3600 { return "há \(seconds / 60) min" }
        if seconds < 86_400 { return "há \(seconds / 3600) h" }
        return "há \(seconds / 86_400) d"
    }
}
