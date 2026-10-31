import AppKit
import Foundation
import UserNotifications

/// Wrapper do UNUserNotificationCenter. Cliques em notificações de sessão do Claude chamam `onOpenSession`.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    var onOpenSession: ((String) -> Void)?
    var onOpenProject: ((String) -> Void)?
    /// Som escolhido para o projeto da pasta (nil: padrão; "": sem som).
    var soundForPath: ((String) -> String?)?
    /// Modo foco: true = segura esta notificação até a pausa (ver FocusTimer.shouldHold).
    var hold: ((_ id: String, _ title: String, _ body: String) -> Bool)?
    private let settings: AppSettings
    private var center: UNUserNotificationCenter { .current() }

    init(settings: AppSettings) {
        self.settings = settings
        super.init()
    }

    func setUp() {
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if !granted {
                NSLog("MacPet: notificações não autorizadas \(error.map { "\($0)" } ?? "")")
            }
        }
    }

    /// `cwd`: pasta da sessão, usada para achar o som do projeto. `mood`: o corvo que aparece na miniatura.
    func post(id: String, title: String, subtitle: String? = nil, body: String, sessionId: String? = nil,
              projectPath: String? = nil, cwd: String? = nil, mood: PetMood? = nil) {
        if hold?(id, title, body) == true { return }
        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle { content.subtitle = subtitle }
        content.body = body
        if let mood, let image = Self.crowImage(mood),
           let attachment = try? UNNotificationAttachment(identifier: "crow", url: image,
                                                          options: [UNNotificationAttachmentOptionsTypeHintKey: "public.png"]) {
            content.attachments = [attachment]
        }
        if settings.notificationSound {
            // Som do projeto: tocamos nós mesmos (a notificação sai muda) para valer qualquer som do sistema.
            switch (cwd ?? projectPath).flatMap({ soundForPath?($0) }) {
            case .some(""): break
            case .some(let name): NotificationSounds.play(name)
            case .none: content.sound = .default
            }
        }
        if let sessionId { content.userInfo = ["sessionId": sessionId] }
        if let projectPath { content.userInfo = ["projectPath": projectPath] }
        // Agrupa por projeto na Central de Notificações.
        content.threadIdentifier = cwd ?? projectPath ?? "claude"
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    /// PNG do corvo no humor da notificação, sobre o fundo azul-tinta do ícone.
    /// O sistema move o arquivo anexado, então cada notificação ganha uma cópia nova.
    private static func crowImage(_ mood: PetMood) -> URL? {
        guard let frame = mood.frames.first else { return nil }
        let crow = PetSprites.image(frame, scale: 10)
        let side: CGFloat = 300
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor(srgbRed: 0x12 / 255, green: 0x13 / 255, blue: 0x19 / 255, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 60, yRadius: 60).fill()
            crow.draw(in: NSRect(x: (side - crow.size.width) / 2, y: (side - crow.size.height) / 2,
                                 width: crow.size.width, height: crow.size.height))
            return true
        }
        guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("macpet-notify", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(mood.rawValue)-\(UUID().uuidString).png")
        return (try? png.write(to: url)) != nil ? url : nil
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let sessionId = info["sessionId"] as? String
        let projectPath = info["projectPath"] as? String
        Task { @MainActor in
            if let sessionId { self.onOpenSession?(sessionId) }
            if let projectPath { self.onOpenProject?(projectPath) }
            completionHandler()
        }
    }
}
