import AppKit
import SwiftUI

/// Um NSStatusItem por métrica, cada um com seu popover de detalhes.
@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let env: AppEnvironment
    private var items: [Metric: NSStatusItem] = [:]
    private var popovers: [Metric: NSPopover] = [:]

    init(env: AppEnvironment) {
        self.env = env
        super.init()
    }

    /// `modules` vem da esquerda para a direita; o macOS insere cada item novo à esquerda
    /// dos existentes, então criamos de trás para frente.
    func build(modules: [Metric]) {
        removeAll()
        for metric in modules.reversed() {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = "macpet.\(metric.rawValue)"
            item.button?.target = self
            item.button?.action = #selector(togglePopover(_:))
            item.button?.identifier = NSUserInterfaceItemIdentifier(metric.rawValue)
            item.button?.imagePosition = .imageOnly
            items[metric] = item
        }
        refresh()
    }

    func removeAll() {
        popovers.values.forEach { $0.close() }
        popovers = [:]
        items.values.forEach { NSStatusBar.system.removeStatusItem($0) }
        items = [:]
    }

    func refresh() {
        let snapshot = env.monitor.snapshot
        let breached = env.alerts.breached
        for (metric, item) in items {
            // O renderizador devolve a mesma imagem para o mesmo texto: sem mudança, a barra não é redesenhada.
            let image = MenuBarRenderer.image(for: metric, snapshot: snapshot, alert: breached.contains(metric))
            if item.button?.image !== image { item.button?.image = image }
        }
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        guard let raw = sender.identifier?.rawValue, let metric = Metric(rawValue: raw) else { return }
        if let open = popovers[metric], open.isShown {
            open.performClose(sender)
            return
        }
        popovers.values.filter(\.isShown).forEach { $0.performClose(nil) }

        let popover = popovers[metric] ?? makePopover(for: metric)
        popovers[metric] = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func makePopover(for metric: Metric) -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        let hosting = NSHostingController(rootView: env.inject(MetricDetailView(metric: metric).mpDesignSystem()))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        return popover
    }

    private func showsProcesses(_ popover: NSPopover) -> Bool {
        let metric = popovers.first { $0.value === popover }?.key
        return metric == .cpu || metric == .memory
    }

    func popoverWillShow(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover, showsProcesses(popover) else { return }
        env.monitor.watchProcesses(true)
    }

    func popoverDidClose(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover else { return }
        // Descarta o popover fechado (o gráfico dele não fica redesenhando escondido).
        if let metric = popovers.first(where: { $0.value === popover })?.key { popovers[metric] = nil }
        guard showsProcesses(popover) else { return }
        env.monitor.watchProcesses(false)
    }
}
