import AVFoundation

/// A música do Samba do Corvo: um pagode romântico original, sintetizado de uma vez ao abrir o jogo (~52 s, 24 kHz
/// mono, ~5 MB enquanto ele está aberto). Cresce junto com a partida: banjo puxando e tantã na introdução; cavaco,
/// banjo e violão de 7 cordas; depois tamborim e a melodia; no fim, repique de mão e a melodia de novo.
/// As cordas são Karplus-Strong: corda dedilhada barata e com cara de instrumento de verdade.
enum SambaSong {
    static let rate: Double = 24_000

    /// I–vi–ii–V em dó com sétimas (um acorde por compasso): vozes do cavaco e baixos do violão (tônica e quinta).
    private static let chords: [(voicing: [Int], bass: [Int])] = [
        ([67, 71, 72, 76], [48, 55]),  // Cmaj7
        ([67, 69, 72, 76], [45, 52]),  // Am7
        ([69, 72, 74, 77], [50, 57]),  // Dm7
        ([67, 71, 74, 77], [43, 50]),  // G7
    ]

    /// Melodia de 8 compassos (passo de semicolcheia, nota MIDI, duração em passos), sobre dois ciclos de acordes.
    private static let melody: [(step: Int, note: Int, length: Int)] = [
        (0, 76, 3), (3, 74, 1), (4, 72, 2), (6, 71, 2),
        (8, 72, 2), (10, 76, 2), (12, 79, 3), (15, 76, 1),
        (16, 77, 3), (19, 76, 1), (20, 74, 2), (22, 72, 2),
        (24, 71, 4), (28, 74, 2), (30, 77, 2),
        (32, 76, 3), (35, 79, 1), (36, 83, 2), (38, 79, 2),
        (40, 81, 3), (43, 79, 1), (44, 76, 4),
        (48, 77, 2), (50, 74, 2), (52, 72, 2), (54, 74, 2),
        (56, 71, 2), (58, 74, 1), (59, 77, 1), (60, 76, 4),
    ]

    /// Cavaco no pagode: palhetadas (passo no compasso, acento).
    private static let strums: [(step: Int, accent: Bool)] = [(0, false), (2, false), (3, true), (5, false), (7, true)]
    /// Banjo: contratempos que dão o balanço do pagode.
    private static let banjo = [1, 3, 5, 7]
    private static let telecoteco: Set<Int> = [0, 2, 4, 5, 7, 9, 11, 13, 14]
    private static let repique = [2, 3, 6, 7]

    // Seções, em compassos (as mesmas do jogo): introdução, entrada, meio, final e fecho.
    private static let firstBar = 2, middle = 10, finale = 22, ending = 38

    static func render(format: AVAudioFormat, bars: Int, step: Double) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount((Double(bars * 8) * step + 0.5) * rate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let samples = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames
        let count = Int(frames)
        samples.update(repeating: 0, count: count)

        var seed: UInt32 = 0x9E37_79B9
        func noise() -> Float {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Float(seed >> 8) / Float(1 << 23) - 1
        }
        func frequency(_ note: Int) -> Double { 440 * pow(2, Double(note - 69) / 12) }
        func at(_ bar: Int, _ index: Int) -> Int { Int(Double(bar * 8 + index) * step * rate) }
        func add(_ start: Int, seconds: Double, _ sample: (Double) -> Float) {
            for n in 0..<Int(seconds * rate) where start + n < count {
                samples[start + n] += sample(Double(n) / rate)
            }
        }

        /// Corda dedilhada (Karplus-Strong com afinação fina por all-pass).
        func pluck(_ start: Int, _ note: Int, amp: Float, seconds: Double, damping: Float) {
            let delay = rate / frequency(note) - 0.5
            let period = max(2, Int(delay))
            let fraction = Float(delay - Double(period))
            let coefficient = (1 - fraction) / (1 + fraction)
            var line = [Float](repeating: 0, count: period)
            var smooth: Float = 0
            for i in 0..<period {
                smooth = smooth * 0.4 + noise() * 0.6  // ataque menos áspero
                line[i] = smooth * amp
            }
            var index = 0, inputBefore: Float = 0, outputBefore: Float = 0
            let total = Int(seconds * rate)
            for n in 0..<total where start + n < count {
                let next = index + 1 == period ? 0 : index + 1
                let value = line[index]
                let averaged = (value + line[next]) * 0.5 * damping
                let tuned = coefficient * averaged + inputBefore - coefficient * outputBefore
                inputBefore = averaged
                outputBefore = tuned
                line[index] = tuned
                let release: Float = n > total - 240 ? Float(total - n) / 240 : 1
                samples[start + n] += value * release
                index = next
            }
        }

        func strum(_ start: Int, _ notes: [Int], accent: Bool, down: Bool, seconds: Double = 0.34) {
            for (order, note) in (down ? notes : notes.reversed()).enumerated() {
                pluck(start + Int(Double(order) * 0.01 * rate), note, amp: accent ? 0.3 : 0.2, seconds: seconds,
                      damping: 0.994)
            }
        }

        /// Banjo: duas cordas agudas, curtas e brilhantes, no contratempo.
        func banjoHit(_ start: Int, _ notes: [Int]) {
            for (order, note) in notes.suffix(2).enumerated() {
                pluck(start + Int(Double(order) * 0.006 * rate), note + 12, amp: 0.16, seconds: 0.16, damping: 0.99)
            }
        }

        /// Voz da melodia (flauta suave): ataque macio, um pouco de sopro e vibrato depois do começo da nota.
        func voice(_ start: Int, _ note: Int, seconds: Double) {
            let f = frequency(note)
            var phase = 0.0
            add(start, seconds: seconds + 0.08) { t in
                let vibrato = t > 0.15 ? 1 + 0.005 * sin(2 * .pi * 5 * t) : 1
                phase += 2 * .pi * f * vibrato / rate
                let attack = min(1, t / 0.04), release = t > seconds ? max(0, 1 - (t - seconds) / 0.08) : 1
                let tone = sin(phase) + 0.3 * sin(2 * phase) + 0.1 * sin(3 * phase)
                return Float(tone * attack * release) * 0.15 + noise() * Float(attack * release) * 0.005
            }
        }

        /// Tantã: tambor grave e redondo do pagode.
        func tanta(_ start: Int, strong: Bool) {
            let base = strong ? 62.0 : 80.0, amp: Float = strong ? 0.7 : 0.38
            var phase = 0.0
            add(start, seconds: 0.5) { t in
                phase += 2 * .pi * base * (1 + 0.4 * exp(-t * 25)) / rate
                return Float(sin(phase) * exp(-t * 6)) * amp
            }
        }

        func repiqueHit(_ start: Int, accent: Bool) {
            var phase = 0.0
            add(start, seconds: 0.15) { t in
                phase += 2 * .pi * 210 * (1 + 0.3 * exp(-t * 40)) / rate
                return Float(sin(phase) * exp(-t * 20)) * (accent ? 0.22 : 0.13) + noise() * Float(exp(-t * 70)) * 0.04
            }
        }

        func tamborim(_ start: Int) {
            add(start, seconds: 0.07) { t in
                let tone = sin(2 * .pi * 900 * t) + 0.5 * sin(2 * .pi * 1350 * t)
                return Float(tone * exp(-t * 60)) * 0.16 + noise() * Float(exp(-t * 90)) * 0.04
            }
        }

        /// Ruído "agudo" (diferença entre amostras): platinelas do pandeiro.
        func hiss(_ start: Int, seconds: Double, decay: Double, amp: Float) {
            var previous: Float = 0
            add(start, seconds: seconds) { t in
                let value = noise()
                defer { previous = value }
                return (value - previous) * Float(exp(-t * decay)) * amp
            }
        }

        // Introdução: tantã marcando e o banjo puxando em arpejo no G7.
        for bar in 0..<firstBar {
            tanta(at(bar, 0), strong: false)
            tanta(at(bar, 4), strong: true)
        }
        for (index, note) in chords[3].voicing.enumerated() {
            pluck(at(1, index * 2), note + 12, amp: 0.2, seconds: 0.4, damping: 0.993)
        }

        for bar in firstBar..<ending {
            let chord = chords[(bar - firstBar) % 4]
            let next = chords[(bar - firstBar + 1) % 4]
            let section = bar < middle ? 1 : bar < finale ? 2 : 3

            tanta(at(bar, 0), strong: false)
            tanta(at(bar, 4), strong: true)
            for index in 0..<8 {
                hiss(at(bar, index), seconds: 0.07, decay: 60, amp: index == 0 || index == 4 ? 0.1 : 0.045)  // pandeiro
            }
            if section >= 2 {
                for index in 0..<8 where telecoteco.contains((bar % 2) * 8 + index) { tamborim(at(bar, index)) }
            }
            if section == 3 {
                for index in repique { repiqueHit(at(bar, index), accent: index == 3 || index == 7) }
            }

            for (order, hit) in strums.enumerated() { strum(at(bar, hit.step), chord.voicing, accent: hit.accent, down: order % 2 == 0) }
            for index in banjo { banjoHit(at(bar, index), chord.voicing) }
            // Violão de 7 cordas: tônica e quinta; do meio em diante, uma nota de passagem até o próximo acorde.
            pluck(at(bar, 0), chord.bass[0], amp: 0.5, seconds: 0.7, damping: 0.996)
            pluck(at(bar, 4), chord.bass[1], amp: 0.42, seconds: 0.45, damping: 0.996)
            if section >= 2 { pluck(at(bar, 7), next.bass[0] - 1, amp: 0.34, seconds: 0.2, damping: 0.995) }
        }

        // Melodia: frase de 8 compassos no meio (uma vez e meia) e duas vezes no final.
        for (from, bars) in [(middle, 8), (middle + 8, 4), (finale, 8), (finale + 8, 8)] {
            for note in melody where note.step < bars * 8 {
                voice(at(from, note.step), note.note, seconds: Double(note.length) * step * 0.94)
            }
        }

        // Fecho: Cmaj7 aberto, a melodia resolvendo no dó e o tantã.
        tanta(at(ending, 0), strong: true)
        strum(at(ending, 0), chords[0].voicing, accent: true, down: true, seconds: 1.8)
        pluck(at(ending, 0), 36, amp: 0.55, seconds: 1.5, damping: 0.997)
        voice(at(ending, 0), 72, seconds: 1.2)

        for i in 0..<count { samples[i] = tanhf(samples[i] * 0.9) }
        return buffer
    }
}
