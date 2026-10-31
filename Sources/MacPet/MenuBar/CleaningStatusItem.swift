import AppKit

/// Botão ✨ na barra de menu que abre a janelinha do modo limpeza.
@MainActor
final class CleaningStatusItem: NSObject {
    private let cleaning: CleaningMode
    private var item: NSStatusItem?

    init(cleaning: CleaningMode) {
        self.cleaning = cleaning
        super.init()
    }

    func install() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "macpet.cleaning"
        let image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Modo limpeza")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "Modo limpeza"
        item.button?.target = self
        item.button?.action = #selector(open)
        self.item = item
    }

    func remove() {
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }

    @objc private func open() {
        cleaning.showPanel()
    }
}
