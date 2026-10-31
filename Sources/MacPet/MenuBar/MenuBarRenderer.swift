import AppKit

/// Desenha os itens da barra como imagens (template, para seguir o tema claro/escuro da barra).
enum MenuBarRenderer {
    static let height: CGFloat = 22

    /// Valor em cima, rótulo pequeno embaixo: "76°C / TEM".
    /// Imagens já desenhadas, pelo texto que mostram (a cada amostra quase nada muda na barra).
    private static var cache: [String: NSImage] = [:]

    private static func cached(_ key: String, _ draw: () -> NSImage) -> NSImage {
        if let image = cache[key] { return image }
        if cache.count > 300 { cache.removeAll() }
        let image = draw()
        cache[key] = image
        return image
    }

    static func metric(value: String, label: String, placeholder: String, alert: Bool) -> NSImage {
        cached("\(label)|\(value)|\(alert)") { drawMetric(value: value, label: label, placeholder: placeholder, alert: alert) }
    }

    private static func drawMetric(value: String, label: String, placeholder: String, alert: Bool) -> NSImage {
        let color: NSColor = alert ? .systemRed : .black
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: color,
        ]
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 7.5, weight: .semibold),
            .foregroundColor: color,
        ]
        let valueSize = (value as NSString).size(withAttributes: valueAttrs)
        let labelSize = (label as NSString).size(withAttributes: labelAttrs)
        let placeholderWidth = (placeholder as NSString).size(withAttributes: valueAttrs).width
        let width = ceil(max(valueSize.width, labelSize.width, placeholderWidth)) + 2

        let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { rect in
            (value as NSString).draw(at: NSPoint(x: (rect.width - valueSize.width) / 2, y: 0), withAttributes: valueAttrs)
            (label as NSString).draw(at: NSPoint(x: (rect.width - labelSize.width) / 2, y: 13), withAttributes: labelAttrs)
            return true
        }
        image.isTemplate = !alert
        return image
    }

    /// Duas linhas com setas, alinhadas à direita: "↑ 9 KB/s / ↓ 13 KB/s".
    static func network(up: String, down: String) -> NSImage {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: NSColor.black,
        ]
        let arrowAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8, weight: .bold),
            .foregroundColor: NSColor.black,
        ]
        let valueWidth = ceil(("999 KB/s" as NSString).size(withAttributes: attrs).width)
        let arrowWidth: CGFloat = 9
        let width = arrowWidth + valueWidth + 2

        let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            for (index, pair) in [("↑", up), ("↓", down)].enumerated() {
                let y: CGFloat = index == 0 ? 0 : 10.5
                (pair.0 as NSString).draw(at: NSPoint(x: 0, y: y + 0.5), withAttributes: arrowAttrs)
                let size = (pair.1 as NSString).size(withAttributes: attrs)
                (pair.1 as NSString).draw(at: NSPoint(x: width - size.width, y: y), withAttributes: attrs)
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    static func image(for metric: Metric, snapshot: SystemSnapshot, alert: Bool) -> NSImage {
        switch metric {
        case .temperature:
            let throttling = snapshot.thermal == .serious || snapshot.thermal == .critical
            return self.metric(value: Format.temperature(snapshot.temperature), label: "TEM", placeholder: "100°C", alert: alert || throttling)
        case .network:
            let up = Format.rate(snapshot.netOut), down = Format.rate(snapshot.netIn)
            return cached("net|\(up)|\(down)") { network(up: up, down: down) }
        case .thermal:
            let hot = snapshot.thermal == .serious || snapshot.thermal == .critical
            return self.metric(value: snapshot.thermal.shortLabel, label: "THR", placeholder: "CRIT", alert: hot)
        case .disk:
            return self.metric(value: Format.percent(snapshot.disk.fraction), label: "SSD", placeholder: "100%", alert: alert)
        case .memory:
            return self.metric(value: Format.percent(snapshot.memory.fraction), label: "MEM", placeholder: "100%", alert: alert)
        case .cpu:
            return self.metric(value: Format.percent(snapshot.cpu), label: "CPU", placeholder: "100%", alert: alert)
        }
    }
}
