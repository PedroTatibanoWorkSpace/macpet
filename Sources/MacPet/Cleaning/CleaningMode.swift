import AppKit
import ApplicationServices
import SwiftUI

/// Modo limpeza: cobre todas as telas de preto e engole todos os eventos de teclado
/// (inclusive teclas de mídia/brilho). O touchpad continua ativo para clicar em "Sair".
@MainActor
final class CleaningMode: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var hasPermission = AXIsProcessTrusted()
    @Published var autoExitMinutes = 5
    @Published private(set) var exitDeadline: Date?
    @Published private(set) var errorMessage: String?

    private var panel: NSWindow?
    private var overlays: [NSWindow] = []
    private var permissionTimer: Timer?
    private var autoExitTimer: Timer?
    private var previousPresentation: NSApplication.PresentationOptions = []
    private var env: AppEnvironment?

    func attach(_ env: AppEnvironment) {
        self.env = env
    }

    // MARK: Janelinha de ativação

    func showPanel() {
        if panel == nil, let env {
            let hosting = NSHostingController(rootView: env.inject(CleaningPanelView().mpDesignSystem()))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Modo limpeza"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            panel = window
        }
        refreshPermission()
        permissionTimer?.invalidate()
        // Enquanto a janelinha está aberta, acompanha se a permissão foi concedida nos Ajustes.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshPermission()
                if self.panel?.isVisible != true { self.permissionTimer?.invalidate() }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
    }

    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        hasPermission = AXIsProcessTrustedWithOptions(options)
        if !hasPermission, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func refreshPermission() {
        let trusted = AXIsProcessTrusted()
        if trusted != hasPermission { hasPermission = trusted }
    }

    // MARK: Ativar / desativar

    func activate() {
        guard !isActive else { return }
        guard KeyboardBlocker.start() else {
            refreshPermission()
            errorMessage = "O macOS não liberou o bloqueio do teclado. Remova o MacPet da lista de Acessibilidade (botão −) e conceda a permissão de novo."
            return
        }
        errorMessage = nil
        isActive = true
        panel?.orderOut(nil)

        guard let env else { return }
        for screen in NSScreen.screens {
            let window = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.setFrame(screen.frame, display: true)
            window.level = .screenSaver
            window.backgroundColor = .black
            window.isOpaque = true
            window.hasShadow = false
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            window.isReleasedWhenClosed = false
            let isMain = screen == NSScreen.main
            window.contentView = NSHostingView(rootView: env.inject(CleaningOverlayView(showsControls: isMain)))
            window.orderFrontRegardless()
            overlays.append(window)
        }

        previousPresentation = NSApp.presentationOptions
        NSApp.activate(ignoringOtherApps: true)
        NSApp.presentationOptions = [.hideDock, .hideMenuBar, .disableProcessSwitching]
        overlays.first { $0.screen == NSScreen.main }?.makeKey()

        // Válvula de segurança: sai sozinho depois do tempo escolhido.
        exitDeadline = Date().addingTimeInterval(TimeInterval(autoExitMinutes * 60))
        autoExitTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(autoExitMinutes * 60), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.deactivate() }
        }
    }

    func deactivate() {
        guard isActive else { return }
        KeyboardBlocker.stop()
        autoExitTimer?.invalidate()
        autoExitTimer = nil
        exitDeadline = nil
        overlays.forEach { $0.orderOut(nil) }
        overlays = []
        NSApp.presentationOptions = previousPresentation
        isActive = false
    }
}

/// Janela sem borda que aceita foco, para o botão de sair responder ao primeiro clique.
private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Event tap no nível do HID que descarta todos os eventos de teclado.
enum KeyboardBlocker {
    private static var tap: CFMachPort?
    private static var source: CFRunLoopSource?

    /// NX_SYSDEFINED: teclas de mídia, brilho, volume, Mission Control etc.
    private static let systemDefined: UInt64 = 1 << 14

    static func start() -> Bool {
        guard tap == nil else { return true }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | systemDefined
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, _ in
                // O sistema desliga o tap se ele demorar; religamos e continuamos bloqueando.
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = KeyboardBlocker.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                return nil
            },
            userInfo: nil
        ) else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    static func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        source = nil
    }
}
