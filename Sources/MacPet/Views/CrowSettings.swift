import SwiftUI

/// Aba "Corvo" das Preferências: o guarda-roupa (cabeça, rosto, pescoço) e o corvo na tela.
struct CrowSettings: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        HStack(spacing: 16) {
            AnimatedPet(mood: .idle, scale: 6)
                .id(settings.petOutfit)  // troca de roupa redesenha na hora
                .padding(12)
                .background(Theme.ink, in: RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous))
            VStack(alignment: .leading, spacing: 8) {
                Text("Guarda-roupa").font(Theme.display(18))
                Text("Escolha uma peça para cada lugar. Vale para o corvo da barra e o da tela.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Ver comemoração") { env.celebratePet() }
                        .buttonStyle(.mp(.secondary, size: .sm))
                        .disabled(!settings.desktopPetEnabled)
                        .help("O corvo da tela faz a animação de tarefa concluída")
                    Button("Tirar tudo") { settings.petOutfit = PetOutfit(head: .none) }
                        .buttonStyle(.mp(.ghost, size: .sm))
                }
            }
        }

        VStack(alignment: .leading, spacing: 8) {
            MPSectionLabel("Kits de anime").padding(.leading, 4)
            HStack(spacing: 8) {
                ForEach(Self.animeKits, id: \.name) { kit in
                    Button { settings.petOutfit = kit.outfit } label: {
                        VStack(spacing: 4) {
                            Image(nsImage: PetSprites.image(PetArt.standing(kit.outfit), scale: 3)).interpolation(.none)
                            Text(kit.name).font(.system(size: 11, weight: settings.petOutfit == kit.outfit ? .semibold : .regular))
                                .foregroundStyle(settings.petOutfit == kit.outfit ? AnyShapeStyle(Theme.sheen) : AnyShapeStyle(Theme.textMuted))
                        }
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(settings.petOutfit == kit.outfit ? AnyShapeStyle(Theme.sheenSoft) : AnyShapeStyle(Theme.plumage),
                                    in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                            .strokeBorder(settings.petOutfit == kit.outfit ? AnyShapeStyle(Theme.sheen) : AnyShapeStyle(Theme.quill)))
                        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("Vestir o kit do \(kit.name)")
                }
            }
        }

        WardrobeSection(title: "Cabeça", options: PetOutfit.Head.allCases, label: \.label, current: settings.petOutfit.head) {
            settings.petOutfit.head = $0
        } dressed: { var outfit = settings.petOutfit; outfit.head = $0; return outfit }
        WardrobeSection(title: "Rosto", options: PetOutfit.Face.allCases, label: \.label, current: settings.petOutfit.face) {
            settings.petOutfit.face = $0
        } dressed: { var outfit = settings.petOutfit; outfit.face = $0; return outfit }
        WardrobeSection(title: "Pescoço", options: PetOutfit.Neck.allCases, label: \.label, current: settings.petOutfit.neck) {
            settings.petOutfit.neck = $0
        } dressed: { var outfit = settings.petOutfit; outfit.neck = $0; return outfit }

        MPFormSection(title: "Corvo na tela",
                      footer: "Ele anda pelo chão da tela e por cima das janelas. Arraste para mudar de lugar, clique para fazer carinho e use o clique direito para petisco, brincar, dormir e ocultar.") {
            MPFormRow(label: "Mostrar o corvo na tela") { Toggle("", isOn: $settings.desktopPetEnabled).labelsHidden() }
            MPFormRow(label: "Andar pela tela", detail: "Desligado, ele fica onde você deixar") {
                Toggle("", isOn: $settings.desktopPetRoams).labelsHidden()
            }
            .disabled(!settings.desktopPetEnabled)
            MPFormRow(label: "Tamanho") {
                MPSelect(icon: "arrow.up.left.and.arrow.down.right",
                         title: [3: "Pequeno", 4: "Médio", 5: "Grande"][settings.desktopPetScale] ?? "Médio",
                         options: [.init(value: 3, label: "Pequeno"), .init(value: 4, label: "Médio"), .init(value: 5, label: "Grande")],
                         selection: $settings.desktopPetScale)
            }
            .disabled(!settings.desktopPetEnabled)
        }
    }
}

extension CrowSettings {
    /// Combinações prontas de cabeça, rosto e pescoço; cada peça também fica avulsa nas seções abaixo.
    static let animeKits: [(name: String, outfit: PetOutfit)] = [
        ("Naruto", PetOutfit(head: .narutoBand, face: .whiskers, neck: .narutoJacket)),
        ("Goku", PetOutfit(head: .gokuHair, face: .none, neck: .gokuGi)),
        ("Luffy", PetOutfit(head: .luffyHat, face: .luffyScar, neck: .luffyVest)),
        ("Gon", PetOutfit(head: .gonHair, face: .none, neck: .gonJacket)),
    ]
}

/// Uma fileira de peças: cada cartão mostra o corvo vestindo aquela peça com o resto da roupa atual.
private struct WardrobeSection<Option: Hashable>: View {
    let title: String
    let options: [Option]
    let label: KeyPath<Option, String>
    let current: Option
    let choose: (Option) -> Void
    let dressed: (Option) -> PetOutfit

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MPSectionLabel(title).padding(.leading, 4)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                ForEach(options, id: \.self) { option in
                    WardrobeCard(frame: PetArt.standing(dressed(option)), label: option[keyPath: label],
                                 selected: option == current) { choose(option) }
                }
            }
        }
    }
}

private struct WardrobeCard: View {
    let frame: [String]
    let label: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(nsImage: PetSprites.image(frame, scale: 3))
                    .interpolation(.none)
                Text(label)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? AnyShapeStyle(Theme.sheen) : AnyShapeStyle(Theme.textMuted))
                    .lineLimit(1)
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(selected ? AnyShapeStyle(Theme.sheenSoft) : hovering ? AnyShapeStyle(Theme.plumageRaised) : AnyShapeStyle(Theme.plumage),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .strokeBorder(selected ? AnyShapeStyle(Theme.sheen) : AnyShapeStyle(Theme.quill)))
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension PetOutfit.Head {
    var label: String {
        switch self {
        case .witch: "Bruxa"
        case .none: "Nada"
        case .santa: "Gorro de Natal"
        case .topHat: "Cartola"
        case .crown: "Coroa"
        case .cap: "Boné"
        case .bow: "Laço"
        case .propeller: "Hélice"
        case .narutoBand: "Bandana do Naruto"
        case .gokuHair: "Cabelo do Goku"
        case .luffyHat: "Chapéu do Luffy"
        case .gonHair: "Cabelo do Gon"
        }
    }
}

extension PetOutfit.Face {
    var label: String {
        switch self {
        case .none: "Nada"
        case .sunglasses: "Óculos escuros"
        case .glasses: "Óculos de grau"
        case .monocle: "Monóculo"
        case .whiskers: "Riscos do Naruto"
        case .luffyScar: "Cicatriz do Luffy"
        }
    }
}

extension PetOutfit.Neck {
    var label: String {
        switch self {
        case .none: "Nada"
        case .bowTie: "Gravata"
        case .scarf: "Cachecol"
        case .medal: "Medalha"
        case .narutoJacket: "Gola do Naruto"
        case .gokuGi: "Gi do Goku"
        case .luffyVest: "Colete do Luffy"
        case .gonJacket: "Jaqueta do Gon"
        }
    }
}
