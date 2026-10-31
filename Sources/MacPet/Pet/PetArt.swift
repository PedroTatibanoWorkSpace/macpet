import Foundation

/// Roupa do corvo: um item por lugar (cabeça, rosto, pescoço). Vale para a barra e para o corvo na tela.
struct PetOutfit: Codable, Hashable {
    enum Head: String, Codable, CaseIterable { case witch, none, santa, topHat, crown, cap, bow, propeller,
        narutoBand, gokuHair, luffyHat, gonHair }
    enum Face: String, Codable, CaseIterable { case none, sunglasses, glasses, monocle, whiskers, luffyScar }
    enum Neck: String, Codable, CaseIterable { case none, bowTie, scarf, medal,
        narutoJacket, gokuGi, luffyVest, gonJacket }

    var head: Head = .witch
    var face: Face = .none
    var neck: Neck = .none

    init(head: Head = .witch, face: Face = .none, neck: Neck = .none) {
        self.head = head
        self.face = face
        self.neck = neck
    }

    /// Peça que não existe mais (ex.: uma roupa que saiu do app) volta para "nada", sem perder o resto da roupa.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        head = (try? container.decode(Head.self, forKey: .head)) ?? .witch
        face = (try? container.decode(Face.self, forKey: .face)) ?? .none
        neck = (try? container.decode(Neck.self, forKey: .neck)) ?? .none
    }
}

/// Arte do pet: um corvo gordinho de perfil com chapéu de bruxa (edição de Halloween).
/// Cada quadro é composto empilhando camadas ASCII numa grade 24×18; cada caractere é uma cor
/// da `palette` e "." é transparente. Só Foundation, para poder ser pré-visualizado fora do app.
enum PetArt {
    static let width = 24
    /// 18 linhas do corvo + 2 de folga no topo para chapéus e acessórios altos.
    static let height = 20
    private static let headroom = 2

    /// Cor de cada caractere (0xRRGGBB). "z" é a cor do texto do sistema (Zzz) e é resolvida no app.
    /// As penas são azul-arroxeadas com brilho nas bordas para o corvo não sumir na barra preta.
    static let palette: [Character: UInt32] = [
        "K": 0x3B4166, // penas
        "H": 0x7D8BC7, // brilho/contorno das penas
        "A": 0x262A45, // asa
        "a": 0x5A6699, // borda das penas da asa
        "Y": 0xF7B538, // bico
        "y": 0xC98A1E, // bico (parte de baixo)
        "F": 0xE0A030, // pés
        "W": 0xFFFFFF, // olho
        "k": 0x0E0F18, // pupila
        "q": 0xE9897A, // bochecha
        "T": 0x7B4BC4, // chapéu
        "t": 0x55308F, // sombra do chapéu
        "p": 0xFF8A1F, // faixa do chapéu
        "b": 0xFFD23F, // fivela
        "L": 0xC4CAD2, // laptop
        "l": 0x8C929B, // base do laptop
        "s": 0x8FE3FF, // tela
        "o": 0xFFD23F, // doce amarelo
        "r": 0xFF4F81, // doce rosa
        "c": 0x55B4FF, // suor
        "v": 0x9B7BD4, // morcego
        "B": 0xFFFFFF, // balão
        "e": 0xE53935, // exclamação
        "n": 0xFFFFFF, // nota musical (grasnando)
        "R": 0xE23B3B, // vermelho (gorro, gravata, cachecol)
        "G": 0xF5C542, // ouro (coroa, monóculo, medalha)
        "g": 0x4ADE80, // verde do ✓
        "D": 0x1A1B26, // cartola
        "d": 0x585E7A, // borda da cartola
        "C": 0x3FAE6A, // boné
        "j": 0x2B7A4B, // aba do boné
        "O": 0xF5841F, // laranja (Naruto, gi do Goku)
        "N": 0x2B4C9B, // azul (bandana do Naruto, faixa do gi)
        "S": 0xFFE14D, // cabelo Super Saiyajin
        "U": 0xE0A41A, // sombra do cabelo dourado
        "P": 0xF2CD6B, // palha do chapéu do Luffy
        "Q": 0xC9973A, // sombra da palha
        "J": 0x14151C, // cabelo do Gon
        "E": 0x3BAA5C, // verde do Gon
    ]

    struct Stamp {
        var art: [String]
        var x: Int
        var y: Int
    }

    // MARK: Camadas (coordenadas relativas ao corpo do corvo)

    /// Corpo redondo olhando para a direita, sem asa, olho e bico (19×13).
    static let body = [
        "......HHHHHH.......",
        "....HHKKKKKKHH.....",
        "...HKKKKKKKKKKH....",
        "..HKKKKKKKKKKKKH...",
        "..HKKKKKKKKKKKKKH..",
        ".HKKKKKKKKKKKKKKH..",
        "HHKKKKKKKKKKKKKKH..",
        "HKKKKKKKKKKKKKKH...",
        "HKKKKKKKKKKKKKKH...",
        "HHKKKKKKKKKKKKH....",
        ".HHHKKKKKKKKHH.....",
        "....HHHHHHHH.......",
        "......F...F........",
    ]

    /// Penas da cauda saindo para a esquerda.
    static let tail = [
        "HH...",
        "HKH..",
        ".HKK.",
    ]

    static let wingFolded = [
        "....aaaa.",
        "..aaAAAAa",
        ".aAAAAAAa",
        "aAAAAAAa.",
        "a.a.aa...",
    ]

    /// Asa levantada (comemorando / chamando atenção).
    static let wingUp = [
        "aa......",
        "aAa.....",
        "aAAa....",
        ".aAAa...",
        "..aAAa..",
        "...aAAa.",
    ]

    static let beakClosed = [
        "YY..",
        "YYYY",
        "yyy.",
    ]

    static let beakOpen = [
        "YYYY",
        "....",
        "yyy.",
    ]

    /// Chapéu de bruxa levemente torto (9×6).
    static let hat = [
        "......tT.",
        ".....TT..",
        "....TTT..",
        "...TTTTt.",
        "..pppbpp.",
        "TTTTTTTTt",
    ]

    // MARK: Roupa (posições relativas ao corpo; o chapéu apoia a última linha no topo da cabeça)

    static func headArt(_ head: PetOutfit.Head) -> (art: [String], dx: Int, height: Int) {
        switch head {
        case .none: ([], 0, 0)
        case .witch: (hat, 5, 6)
        case .santa: (["W........", ".RRR.....", "..RRRRR..", "...RRRRR.", "..WWWWWWW", "..WWWWWWW"], 4, 6)
        case .topHat: (["..ddddd..", "..dDDDd..", "..dDDDd..", "..dRRRd..", "..ddddd..", "ddDDDDDdd"], 5, 6)
        case .crown: (["G..G..G", "GG.G.GG", "GGGGGGG", "GrGsGrG"], 6, 4)
        case .cap: (["..CCCC.....", ".CCCCCC....", "CCCCCCCC...", "CCCCCCCjjjj"], 5, 4)
        case .bow: (["rr.rr", "rrRrr", "rr.rr"], 8, 3)
        case .propeller: (["eee.sss.", "...b....", "..eesss.", ".eeessss"], 5, 4)
        // Naruto: bandana da Folha na testa (placa de metal na frente, pontas soltas atrás). Altura 0: começa
        // na linha 1 da cabeça, não em cima dela.
        case .narutoBand: (["...NNNNLLLLLN.", "NN.NNNNLLkLLNN", ".NN..........."], 1, 0)
        // Goku: cabelo de Super Saiyajin, espetado para cima.
        case .gokuHair: ([".......S......", "..S...SS......", "..SS..SSS..S..", "S.SSS.SSSSSS..", "SSSSSUSSSSSSS.", ".SSSUUSSSUSSS.", "..SSSSSSSSSS..", "...S.S..S....."], 2, 6)
        // Luffy: chapéu de palha com a faixa vermelha e aba larga.
        case .luffyHat: (["....PPPPPPP.....", "...PPPPPPPPP....", "...RRRRRRRRR....", "QPPPPPPPPPPPPPPQ"], 1, 4)
        // Gon: cabelo preto espetado para cima, com pontas verdes.
        case .gonHair: (["J....J....J...", "JJ...JJ...JJ..", "JHJ..JHJ..JHJ.", ".JHJJJJHJJJJJ.", "..JJJJJJJJJJJ.", ".JJJJJJJJJJJJ.", "..JJJJJJJJJJ.."], 2, 7)
        }
    }

    static func faceArt(_ face: PetOutfit.Face) -> (art: [String], dx: Int, dy: Int) {
        switch face {
        case .none: ([], 0, 0)
        case .sunglasses: (["kkkkkWkkk", "....kkkk."], 6, 3)
        case .glasses: ([".....LLL.", "LLLLL...L", "....L...L", ".....LLL."], 6, 2)
        case .monocle: ([".GGG.", "G...G", "G...G", ".GGG.", "....G", "...G."], 10, 2)
        // Naruto: três riscos na bochecha.
        case .whiskers: (["kk", "..", "kk"], 11, 5)
        // Luffy: cicatriz com pontos embaixo do olho.
        case .luffyScar: (["k.k", "qqq"], 11, 5)
        }
    }

    static func neckArt(_ neck: PetOutfit.Neck) -> (art: [String], dx: Int, dy: Int) {
        switch neck {
        case .none: ([], 0, 0)
        case .bowTie: (["RR.RR", "RRDRR", "RR.RR"], 11, 7)
        case .scarf: (["RRWRRWRR", ".RRWRRW.", "..R.....", "..W.....", "..R....."], 8, 7)
        case .medal: (["s.s", ".s.", "GGG", "GoG", "GGG"], 12, 7)
        // Naruto: gola alta laranja com o zíper preto.
        case .narutoJacket: (["kOOOOOOk", "OOOOOOOO", ".OOkOOO.", "..OkOO.."], 7, 8)
        // Goku: gi laranja com a camiseta azul aparecendo no decote.
        case .gokuGi: (["OOONNOOO", ".OOONOO.", "..OOOO.."], 7, 8)
        // Luffy: colete vermelho aberto com botões amarelos.
        case .luffyVest: (["RR....RR", "RRb..bRR", ".RR..RR.", "..R..R.."], 7, 8)
        // Gon: jaqueta verde de gola alta.
        case .gonJacket: (["EEEEEEEE", "EEEEEEEE", ".EEJEEE.", "..EJEE.."], 7, 8)
        }
    }

    /// Roupa em uso (o app muda; a arte é montada de novo para cada roupa e guardada).
    static var outfit = PetOutfit()
    /// Roupa dos quadros sendo montados agora (ver `animations(for:)`).
    private static var dressing = PetOutfit()

    /// Camadas da roupa: pescoço antes dos olhos, rosto depois, cabeça por cima de tudo.
    private static func wear(x: Int, y: Int, hatLift: Int) -> (neck: [Stamp], face: [Stamp], head: [Stamp]) {
        let neck = neckArt(dressing.neck), face = faceArt(dressing.face), head = headArt(dressing.head)
        return ([Stamp(art: neck.art, x: x + neck.dx, y: y + neck.dy)],
                [Stamp(art: face.art, x: x + face.dx, y: y + face.dy)],
                [Stamp(art: head.art, x: x + head.dx, y: y - head.height + 1 - hatLift)])
    }

    enum Eyes { case open, blink, down, happy, closed, dizzy, tired }

    static func eye(_ style: Eyes) -> [String] {
        switch style {
        case .open:   ["WW.", "Wk."]
        case .blink:  ["...", "kk."]
        case .down:   ["WW.", "kW."]
        case .happy:  [".k.", "k.k"]
        case .closed: ["...", "kkk"]
        case .dizzy:  ["k.k", ".k.", "k.k"]
        case .tired:  ["kk.", "Wk."]
        }
    }

    /// Laptop de perfil, com a tela virada para o corvo.
    static let laptop = [
        "....LL",
        "....sL",
        "....sL",
        "llllll",
    ]

    static let bubble = [
        ".BBB.",
        "BBeBB",
        "BBeBB",
        "BBBBB",
        "BBeBB",
        ".BBB.",
        "...B.",
    ]

    static let batUp = ["v...v", "vv.vv", ".vvv."]
    static let batDown = [".vvv.", "vv.vv", "v...v"]
    static let zSmall = ["zzz", ".z.", "z..", "zzz"]
    static let zBig = ["zzz", "..z", ".z.", "z..", "zzz"]
    static let drop = ["c", "c"]
    static let batteryLow = ["LLLL.", "Le.LL", "LLLL."]
    static let batteryEmpty = ["LLLL.", "L..LL", "LLLL."]
    static let note = [".nn", ".n.", "nn."]

    // MARK: Mascote de tela (anda, voa, é arrastado)

    /// Asa batendo para baixo (voo), complementa `wingUp`.
    static let wingDown = [
        "aAAAAAAAa",
        ".aAAAAAAa",
        "..aAAAAa.",
        "...aAAa..",
        "....aa...",
    ]
    static let heart = [".r.r.", "rrrrr", ".rrr.", "..r.."]
    static let heartSmall = ["r.r", ".r."]
    /// Milho doce de Halloween (o petisco).
    static let candyCorn = [".W", "pp", "oo"]
    static let crumbs = ["o.p"]

    enum Feet { case standing, spread, together, dangling, tucked }

    /// Corpo sem a fileira dos pés, para os pés variarem (andando, pendurado, voando).
    static let bodyNoFeet = Array(body.dropLast())

    static func feet(_ style: Feet) -> (art: [String], dx: Int) {
        switch style {
        case .standing: (["F...F"], 6)
        case .spread:   (["F.....F"], 5)
        case .together: (["F.F"], 7)
        case .dangling: (["F...F", "F...F"], 6)
        case .tucked:   ([], 0)
        }
    }

    enum Wing { case folded, up, down }

    /// Quadro do mascote de tela: como `frame`, mas com pés e asa à escolha.
    static func desktopFrame(
        eyes style: Eyes,
        dy: Int = 0,
        feet: Feet = .standing,
        wing: Wing = .folded,
        beakOpen: Bool = false,
        cheek: Bool = true,
        laptopOn: Bool = false,
        hatLift: Int = 0,
        extras: [Stamp] = []
    ) -> [String] {
        let x = 2, y = 5 + dy
        let outfit = wear(x: x, y: y, hatLift: hatLift)
        let (feetArt, feetX) = self.feet(feet)
        var stamps: [Stamp] = [
            Stamp(art: tail, x: x - 2, y: y + 6),
            Stamp(art: bodyNoFeet, x: x, y: y),
            Stamp(art: feetArt, x: x + feetX, y: y + 12),
        ]
        switch wing {
        case .folded: stamps.append(Stamp(art: wingFolded, x: x + 3, y: y + 5))
        case .up: stamps.append(Stamp(art: wingUp, x: x, y: y - 1))
        case .down: stamps.append(Stamp(art: wingDown, x: x + 2, y: y + 9))  // passa da barriga: lê como batida
        }
        stamps += outfit.neck + [
            Stamp(art: eye(style), x: x + 11, y: y + 3),
            Stamp(art: beakOpen ? self.beakOpen : beakClosed, x: x + 16, y: y + 4),
        ]
        if cheek { stamps.append(Stamp(art: ["q"], x: x + 13, y: y + 6)) }
        stamps += outfit.face + outfit.head
        if laptopOn { stamps.append(Stamp(art: laptop, x: 18, y: 13)) }
        stamps += extras
        return render(stamps)
    }

    static let checkBubble = [
        ".BBBBB.",
        "BBBBBgB",
        "BBBBgBB",
        "BgBgBBB",
        "BBgBBBB",
        ".BBBBB.",
        "..B....",
    ]
    static let sparkle = [".b.", "bWb", ".b."]

    static func confetti(_ shift: Int) -> [Stamp] {
        [Stamp(art: ["o"], x: 1, y: 2 + shift), Stamp(art: ["s"], x: 6, y: 0 + shift), Stamp(art: ["r"], x: 20, y: 1 + shift),
         Stamp(art: ["g"], x: 23, y: 5 + shift), Stamp(art: ["T"], x: 0, y: 7 + shift), Stamp(art: ["b"], x: 15, y: 0 + shift),
         Stamp(art: ["r"], x: 3, y: 11 + shift), Stamp(art: ["s"], x: 22, y: 10 + shift)]
    }

    static func mirrored(_ frame: [String]) -> [String] { frame.map { String($0.reversed()) } }

    /// Quadros (da barra e da tela) da roupa em uso.
    static var frames: [String: [[String]]] { animations(for: outfit).bar }
    static var desktopFrames: [String: [[String]]] { animations(for: outfit).desktop }

    private static var built: [PetOutfit: (bar: [String: [[String]]], desktop: [String: [[String]]])] = [:]

    static func animations(for outfit: PetOutfit) -> (bar: [String: [[String]]], desktop: [String: [[String]]]) {
        if let cached = built[outfit] { return cached }
        let previous = dressing
        dressing = outfit
        defer { dressing = previous }
        let result = (bar: makeFrames(), desktop: makeDesktopFrames())
        built[outfit] = result
        return result
    }

    /// Quadro parado com uma roupa qualquer (miniaturas do guarda-roupa).
    static func standing(_ outfit: PetOutfit) -> [String] { animations(for: outfit).bar["idle"]?[2] ?? [] }

    /// Animações do mascote de tela que não existem no da barra (olhando para a direita; o app espelha).
    private static func makeDesktopFrames() -> [String: [[String]]] { [
        // Terminou uma tarefa: agacha, pula girando no meio do confete, pousa, tira o chapéu e mostra o ✓.
        "finish": [
            desktopFrame(eyes: .happy, dy: 1, feet: .tucked),
            desktopFrame(eyes: .happy, dy: -1, feet: .dangling, wing: .up, beakOpen: true, extras: confetti(0)),
            mirrored(desktopFrame(eyes: .happy, dy: -1, feet: .tucked, wing: .down, extras: confetti(1))),
            desktopFrame(eyes: .happy, dy: -1, feet: .tucked, wing: .up, extras: confetti(2)),
            mirrored(desktopFrame(eyes: .happy, dy: -1, feet: .tucked, wing: .down, extras: confetti(3))),
            desktopFrame(eyes: .blink, dy: 1, feet: .tucked, extras: confetti(4)),
            desktopFrame(eyes: .happy, wing: .up, hatLift: 1, extras: [Stamp(art: checkBubble, x: 17, y: 0)]),
            desktopFrame(eyes: .happy, wing: .up, beakOpen: true, hatLift: 1,
                         extras: [Stamp(art: checkBubble, x: 17, y: 0), Stamp(art: sparkle, x: 0, y: 2)]),
            desktopFrame(eyes: .happy, extras: [Stamp(art: checkBubble, x: 17, y: 0)]),
        ],
        "walk": [
            desktopFrame(eyes: .open, feet: .spread),
            desktopFrame(eyes: .open, dy: -1, feet: .dangling),
            desktopFrame(eyes: .open, feet: .together),
            desktopFrame(eyes: .open, dy: -1, feet: .dangling),
        ],
        "fly": [
            desktopFrame(eyes: .open, dy: -1, feet: .tucked, wing: .up),
            desktopFrame(eyes: .open, feet: .tucked, wing: .folded),
            desktopFrame(eyes: .open, dy: 1, feet: .tucked, wing: .down),
            desktopFrame(eyes: .open, feet: .tucked, wing: .folded),
        ],
        // Segurado pelo mouse: pés pendurados, batendo as asas, grasnando.
        "held": [
            desktopFrame(eyes: .open, dy: -1, feet: .dangling, wing: .up, beakOpen: true),
            desktopFrame(eyes: .open, dy: -1, feet: .dangling, wing: .down),
        ],
        "fall": [
            desktopFrame(eyes: .dizzy, dy: -1, feet: .dangling, wing: .up, beakOpen: true),
        ],
        // Pousou: agacha e levanta.
        "land": [
            desktopFrame(eyes: .blink, dy: 1, feet: .tucked),
            desktopFrame(eyes: .open),
        ],
        "hop": [
            desktopFrame(eyes: .happy, dy: -2, feet: .dangling, wing: .up),
            desktopFrame(eyes: .open),
        ],
        // Petisco: o milho doce está no chão, ele bica e mastiga.
        "peck": [
            desktopFrame(eyes: .open, extras: [Stamp(art: candyCorn, x: 21, y: 15)]),
            desktopFrame(eyes: .down, dy: 1, feet: .tucked, beakOpen: true, extras: [Stamp(art: candyCorn, x: 21, y: 15)]),
            desktopFrame(eyes: .down, dy: 1, feet: .tucked, extras: [Stamp(art: crumbs, x: 20, y: 17)]),
            desktopFrame(eyes: .happy, beakOpen: true),
            desktopFrame(eyes: .happy),
            desktopFrame(eyes: .happy, beakOpen: true, extras: [Stamp(art: note, x: 21, y: 3)]),
        ],
        // Falando (o balão está escrevendo): bico abre e fecha.
        "talk": [
            desktopFrame(eyes: .open, beakOpen: true),
            desktopFrame(eyes: .open),
            desktopFrame(eyes: .open, beakOpen: true),
            desktopFrame(eyes: .blink),
        ],
        // Carinho: olhos felizes e corações subindo.
        "petted": [
            desktopFrame(eyes: .happy, extras: [Stamp(art: heartSmall, x: 20, y: 6)]),
            desktopFrame(eyes: .happy, dy: -1, feet: .dangling, extras: [Stamp(art: heart, x: 19, y: 2)]),
            desktopFrame(eyes: .happy, extras: [Stamp(art: heart, x: 19, y: 0), Stamp(art: heartSmall, x: 0, y: 3)]),
            desktopFrame(eyes: .happy, extras: [Stamp(art: heartSmall, x: 1, y: 0)]),
        ],
    ] }

    // MARK: Composição

    static func frame(
        eyes style: Eyes,
        dy: Int = 0,
        wingRaised: Bool = false,
        beakOpen: Bool = false,
        cheek: Bool = true,
        laptopOn: Bool = false,
        extras: [Stamp] = []
    ) -> [String] {
        let x = 2, y = 5 + dy
        let outfit = wear(x: x, y: y, hatLift: 0)
        var stamps: [Stamp] = [
            Stamp(art: tail, x: x - 2, y: y + 6),
            Stamp(art: body, x: x, y: y),
            Stamp(art: wingRaised ? wingUp : wingFolded, x: x + (wingRaised ? 0 : 3), y: y + (wingRaised ? -1 : 5)),
        ] + outfit.neck + [
            Stamp(art: eye(style), x: x + 11, y: y + 3),
            Stamp(art: beakOpen ? self.beakOpen : beakClosed, x: x + 16, y: y + 4),
        ]
        if cheek { stamps.append(Stamp(art: ["q"], x: x + 13, y: y + 6)) }
        stamps += outfit.face + outfit.head
        if laptopOn { stamps.append(Stamp(art: laptop, x: 18, y: 13)) }
        stamps += extras
        return render(stamps)
    }

    static func render(_ stamps: [Stamp]) -> [String] {
        var grid = Array(repeating: Array(repeating: Character("."), count: width), count: height)
        for stamp in stamps {
            for (row, line) in stamp.art.enumerated() {
                for (col, char) in line.enumerated() where char != "." {
                    let x = stamp.x + col, y = stamp.y + row + headroom
                    guard (0..<width).contains(x), (0..<height).contains(y) else { continue }
                    grid[y][x] = char
                }
            }
        }
        return grid.map { String($0) }
    }

    // MARK: Animações por humor (chave = PetMood.rawValue)

    private static func makeFrames() -> [String: [[String]]] { [
        // Parado: pisca, grasna uma vez e um morcego passa voando.
        "idle": [
            frame(eyes: .open, extras: [Stamp(art: batUp, x: 0, y: 0)]),
            frame(eyes: .open, extras: [Stamp(art: batDown, x: 1, y: 1)]),
            frame(eyes: .open),
            frame(eyes: .blink),
            frame(eyes: .open),
            frame(eyes: .open, beakOpen: true, extras: [Stamp(art: note, x: 21, y: 4)]),
            frame(eyes: .open),
            frame(eyes: .open),
        ],
        // Trabalhando: olhando para o laptop e bicando o teclado.
        "working": [
            frame(eyes: .down, laptopOn: true),
            frame(eyes: .down, dy: 1, laptopOn: true, extras: [Stamp(art: ["o"], x: 20, y: 15)]),
            frame(eyes: .down, laptopOn: true),
            frame(eyes: .down, dy: 1, laptopOn: true, extras: [Stamp(art: ["o"], x: 22, y: 15)]),
            frame(eyes: .down, laptopOn: true),
            frame(eyes: .blink, laptopOn: true),
        ],
        // Esperando você: pula batendo a asa com um balão de "!".
        "waiting": [
            frame(eyes: .open, dy: -1, wingRaised: true, beakOpen: true, extras: [Stamp(art: bubble, x: 19, y: 0)]),
            frame(eyes: .open, extras: [Stamp(art: bubble, x: 19, y: 0)]),
            frame(eyes: .open, dy: -1, wingRaised: true, beakOpen: true, extras: [Stamp(art: bubble, x: 19, y: 0)]),
            frame(eyes: .open),
        ],
        // Comemorando: asa para cima, chuva de doces de Halloween e o ✓ de tarefa concluída.
        "celebrating": [
            frame(eyes: .happy, extras: [Stamp(art: checkBubble, x: 17, y: 0)]),
            frame(eyes: .happy, dy: -1, wingRaised: true, beakOpen: true, extras: [
                Stamp(art: ["o"], x: 1, y: 1), Stamp(art: ["r"], x: 22, y: 2), Stamp(art: ["o"], x: 21, y: 8),
                Stamp(art: ["r"], x: 3, y: 4),
            ]),
            frame(eyes: .happy, extras: [
                Stamp(art: ["r"], x: 0, y: 3), Stamp(art: ["o"], x: 23, y: 4), Stamp(art: ["r"], x: 19, y: 0),
                Stamp(art: ["o"], x: 2, y: 0),
            ]),
        ],
        // Mac quente: suando, tonto e de bico aberto.
        "hot": [
            frame(eyes: .dizzy, beakOpen: true, extras: [Stamp(art: drop, x: 22, y: 3), Stamp(art: drop, x: 3, y: 6)]),
            frame(eyes: .dizzy, beakOpen: true, extras: [Stamp(art: drop, x: 22, y: 5), Stamp(art: drop, x: 3, y: 8)]),
        ],
        // Cansado (perto do limite do plano): pálpebra pesada, bocejo e bateria fraca piscando.
        "tired": [
            frame(eyes: .tired, extras: [Stamp(art: batteryLow, x: 19, y: 1)]),
            frame(eyes: .tired, extras: [Stamp(art: batteryEmpty, x: 19, y: 1)]),
            frame(eyes: .closed, dy: 1, beakOpen: true, extras: [Stamp(art: batteryLow, x: 19, y: 1)]),
            frame(eyes: .tired, extras: [Stamp(art: batteryEmpty, x: 19, y: 1)]),
        ],
        // Dormindo: olho fechado, respirando, Zzz.
        "sleeping": [
            frame(eyes: .closed, cheek: false, extras: [Stamp(art: zSmall, x: 20, y: 1)]),
            frame(eyes: .closed, dy: 1, cheek: false, extras: [Stamp(art: zBig, x: 20, y: 0)]),
        ],
    ] }
}
