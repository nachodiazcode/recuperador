import Foundation

/// Tonos cortos de sintetizador, todos en la misma familia (re mayor; la menor si algo falla).
/// Senos con ataque suave, caída exponencial y un poco de desafinación entre los dos canales.
enum Synth {
    enum Tone {
        case rise, chord, air, tap, low, mixed

        var duration: Double {
            switch self {
            case .rise: return 0.42
            case .chord: return 0.95
            case .air: return 0.85
            case .tap: return 0.22
            case .low: return 0.68
            case .mixed: return 0.78
            }
        }

        /// Eco corto solo en los tonos largos. El tic y el fallo quedan secos.
        var echoes: Bool { self == .chord || self == .air }
    }

    private struct Voice {
        var frequency: (Double) -> Double
        var gain: Double
        var attack: Double
        var decay: Double
        var delay: Double
    }

    private static let rate = 44_100
    private static var cache: [Tone: Data] = [:]

    static func wav(for tone: Tone) -> Data {
        if let ready = cache[tone] { return ready }
        let count = Int((tone.duration * Double(rate)).rounded(.up))
        var left = render(tone, count: count, cents: -3.5)
        var right = render(tone, count: count, cents: 3.5)
        soften(&left)
        soften(&right)
        if tone.echoes {
            echo(&left)
            echo(&right)
        }
        normalize(&left, &right, peak: 0.46)
        let data = encode(left, right)
        cache[tone] = data
        return data
    }

    private static func voices(for tone: Tone) -> [Voice] {
        switch tone {
        case .rise:
            // Barrido sol → mi, como encender un oscilador.
            let sweep = glide(392, 659.25, 0.16)
            return [
                Voice(frequency: sweep, gain: 0.62, attack: 0.010, decay: 0.34, delay: 0),
                Voice(frequency: { sweep($0) * 2 }, gain: 0.14, attack: 0.014, decay: 0.20, delay: 0.01),
                Voice(frequency: { sweep($0) * 1.5 }, gain: 0.08, attack: 0.020, decay: 0.24, delay: 0.02),
            ]
        case .chord:
            // Re mayor abierto, entradas escalonadas.
            return [
                note(220.00, 0.30, attack: 0.018, decay: 0.78, delay: 0),
                note(293.66, 0.26, attack: 0.016, decay: 0.72, delay: 0.035),
                note(369.99, 0.16, attack: 0.018, decay: 0.60, delay: 0.070),
                note(440.00, 0.18, attack: 0.016, decay: 0.55, delay: 0.105),
                note(587.33, 0.09, attack: 0.020, decay: 0.40, delay: 0.140),
            ]
        case .air:
            return [
                note(880.00, 0.50, attack: 0.040, decay: 0.70, delay: 0),
                note(1318.51, 0.10, attack: 0.050, decay: 0.50, delay: 0.03),
                note(1760.00, 0.035, attack: 0.030, decay: 0.32, delay: 0.05),
            ]
        case .tap:
            return [
                note(587.33, 0.75, attack: 0.008, decay: 0.12, delay: 0),
                note(880.00, 0.12, attack: 0.008, decay: 0.07, delay: 0),
            ]
        case .low:
            // La menor, grave y redondo. Se distingue del acorde sin sonar a alarma.
            return [
                note(220.00, 0.40, attack: 0.016, decay: 0.55, delay: 0),
                note(164.81, 0.28, attack: 0.022, decay: 0.50, delay: 0.04),
                note(261.63, 0.16, attack: 0.020, decay: 0.40, delay: 0.08),
            ]
        case .mixed:
            return [
                note(293.66, 0.40, attack: 0.012, decay: 0.30, delay: 0),
                note(261.63, 0.34, attack: 0.012, decay: 0.42, delay: 0.18),
                note(196.00, 0.20, attack: 0.020, decay: 0.45, delay: 0.18),
            ]
        }
    }

    private static func note(_ frequency: Double, _ gain: Double, attack: Double, decay: Double, delay: Double) -> Voice {
        Voice(frequency: { _ in frequency }, gain: gain, attack: attack, decay: decay, delay: delay)
    }

    /// Glissando exponencial: el oído lo oye lineal en tono, no en hercios.
    private static func glide(_ from: Double, _ to: Double, _ seconds: Double) -> (Double) -> Double {
        { t in
            let x = min(max(t / seconds, 0), 1)
            let k = x * x * (3 - 2 * x)
            return from * pow(to / from, k)
        }
    }

    private static func render(_ tone: Tone, count: Int, cents: Double) -> [Double] {
        let detune = pow(2, cents / 1200)
        var out = [Double](repeating: 0, count: count)
        let sampleRate = Double(rate)
        for voice in voices(for: tone) {
            var phase = 0.0
            for i in 0..<count {
                let t = Double(i) / sampleRate
                phase += 2 * Double.pi * voice.frequency(t) * detune / sampleRate
                if phase > 64 { phase.formTruncatingRemainder(dividingBy: 2 * Double.pi) }
                var amp = voice.gain * envelope(t, delay: voice.delay, attack: voice.attack, decay: voice.decay)
                let fade = 0.012
                if t > tone.duration - fade {
                    let u = (tone.duration - t) / fade
                    amp *= u * u
                }
                out[i] += amp * sin(phase)
            }
        }
        return out
    }

    private static func envelope(_ t: Double, delay: Double, attack: Double, decay: Double) -> Double {
        let x = t - delay
        guard x > 0, attack > 0 else { return 0 }
        let attackGain = x < attack ? 0.5 - 0.5 * cos(Double.pi * x / attack) : 1
        return attackGain * exp(-4 * x / decay)
    }

    /// Paso-bajo suave, para quitar el filo digital sin apagar el brillo.
    private static func soften(_ samples: inout [Double]) {
        let coeff = exp(-2 * Double.pi * 6500 / Double(rate))
        var y = 0.0
        for i in samples.indices {
            y = (1 - coeff) * samples[i] + coeff * y
            samples[i] = y
        }
    }

    private static func echo(_ samples: inout [Double]) {
        let sampleRate = Double(rate)
        for (delay, gain) in [(0.082, 0.20), (0.164, 0.07)] {
            let offset = Int(delay * sampleRate)
            guard offset > 0 else { continue }
            for i in offset..<samples.count {
                samples[i] += gain * samples[i - offset]
            }
        }
    }

    private static func normalize(_ left: inout [Double], _ right: inout [Double], peak target: Double) {
        func saturate(_ samples: inout [Double]) {
            for i in samples.indices { samples[i] = tanh(samples[i] * 1.15) }
        }
        saturate(&left)
        saturate(&right)
        var peak = 0.000_1
        for i in left.indices { peak = max(peak, abs(left[i]), abs(right[i])) }
        let gain = target / peak
        for i in left.indices {
            left[i] *= gain
            right[i] *= gain
        }
    }

    private static func encode(_ left: [Double], _ right: [Double]) -> Data {
        let count = min(left.count, right.count)
        let dataBytes = count * 4
        var data = Data(capacity: 44 + dataBytes)
        data.append(contentsOf: "RIFF".utf8)
        data.appendLE(UInt32(36 + dataBytes))
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        data.appendLE(UInt32(16))
        data.appendLE(UInt16(1))
        data.appendLE(UInt16(2))
        data.appendLE(UInt32(rate))
        data.appendLE(UInt32(rate * 4))
        data.appendLE(UInt16(4))
        data.appendLE(UInt16(16))
        data.append(contentsOf: "data".utf8)
        data.appendLE(UInt32(dataBytes))
        for i in 0..<count {
            data.appendLE(Int16(clamping: (left[i] * 32_767).rounded()))
            data.appendLE(Int16(clamping: (right[i] * 32_767).rounded()))
        }
        return data
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}

private extension Int16 {
    init(clamping value: Double) {
        if value >= Double(Int16.max) { self = .max }
        else if value <= Double(Int16.min) { self = .min }
        else { self = Int16(value) }
    }
}
