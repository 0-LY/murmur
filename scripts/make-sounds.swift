import AVFoundation
import Foundation

let rate = 44_100.0
let peakTarget = 0.5

struct Voice {
    var duration: Double
    var render: (Double, Double) -> Double
}

func noise(_ seed: inout UInt64) -> Double {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return Double(Int64(bitPattern: seed >> 1)) / Double(Int64.max) * 2 - 1
}

func smooth(_ x: Double) -> Double { 0.5 - 0.5 * cos(.pi * min(1, max(0, x))) }

func envelope(_ t: Double, attack: Double, decay: Double, duration: Double) -> Double {
    let a = smooth(t / attack)
    let d = exp(-max(0, t - attack) / decay)
    let tail = smooth((duration - t) / 0.03)
    return a * d * tail
}

func sweep(from f0: Double, to f1: Double, duration: Double, harmonic: Double, attack: Double, decay: Double,
           transient: Double, seed s0: UInt64) -> [Double] {
    let n = Int(duration * rate)
    var out = [Double](repeating: 0, count: n)
    var phase = 0.0
    var seed = s0
    var lp = 0.0
    for i in 0..<n {
        let t = Double(i) / rate
        let f = f0 * pow(f1 / f0, min(1, t / (duration * 0.8)))
        phase += 2 * .pi * f / rate
        lp += (noise(&seed) - lp) * 0.08
        let burst = lp * transient * exp(-t / 0.012) * smooth(t / 0.002)
        out[i] = (sin(phase) + harmonic * sin(2 * phase)) * envelope(t, attack: attack, decay: decay, duration: duration) + burst
    }
    return out
}

func tap(pitch: Double, duration: Double, body: Double, seed s0: UInt64) -> [Double] {
    let n = Int(duration * rate)
    var out = [Double](repeating: 0, count: n)
    var seed = s0
    var lp = 0.0
    var phase = 0.0
    for i in 0..<n {
        let t = Double(i) / rate
        lp += (noise(&seed) - lp) * 0.18
        phase += 2 * .pi * pitch / rate
        let click = lp * exp(-t / 0.009) * smooth(t / 0.0015)
        let tone = sin(phase) * body * exp(-t / 0.045) * smooth(t / 0.004)
        out[i] = (click + tone) * smooth((duration - t) / 0.03)
    }
    return out
}

func pop(from f0: Double, to f1: Double, duration: Double, decay: Double) -> [Double] {
    let n = Int(duration * rate)
    var out = [Double](repeating: 0, count: n)
    var phase = 0.0
    for i in 0..<n {
        let t = Double(i) / rate
        let f = f1 + (f0 - f1) * exp(-t / 0.025)
        phase += 2 * .pi * f / rate
        let e = smooth(t / 0.006) * exp(-t / decay) * smooth((duration - t) / 0.03)
        out[i] = (sin(phase) + 0.18 * sin(3 * phase)) * e
    }
    return out
}

func finish(_ x: [Double]) -> [Float] {
    var y = [Double](repeating: 0, count: x.count)
    var prevX = 0.0, prevY = 0.0
    for i in 0..<x.count {
        prevY = x[i] - prevX + 0.997 * prevY
        prevX = x[i]
        y[i] = prevY
    }
    let edge = Int(0.006 * rate)
    for i in 0..<min(edge, y.count) {
        let g = smooth(Double(i) / Double(edge))
        y[i] *= g
        y[y.count - 1 - i] *= g
    }
    y[0] = 0
    y[y.count - 1] = 0
    let peak = y.map(abs).max() ?? 1
    return y.map { Float($0 / peak * peakTarget) }
}

func write(_ samples: [Float], to url: URL) throws {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { src in
        buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
    }
    try? FileManager.default.removeItem(at: url)
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
                                   AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: true]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    try file.write(from: buffer)
}

let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/Sounds", isDirectory: true)
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let sounds: [(String, [Double])] = [
    ("deep-start", sweep(from: 110, to: 165, duration: 0.32, harmonic: 0.22, attack: 0.018, decay: 0.11, transient: 0.35, seed: 7)),
    ("deep-stop", sweep(from: 165, to: 110, duration: 0.32, harmonic: 0.22, attack: 0.012, decay: 0.1, transient: 0.25, seed: 11)),
    ("soft-start", tap(pitch: 230, duration: 0.18, body: 0.55, seed: 3)),
    ("soft-stop", tap(pitch: 185, duration: 0.16, body: 0.4, seed: 5)),
    ("bubble-start", pop(from: 520, to: 260, duration: 0.24, decay: 0.07)),
    ("bubble-stop", pop(from: 420, to: 200, duration: 0.22, decay: 0.06)),
]
for (name, samples) in sounds {
    try write(finish(samples), to: dir.appendingPathComponent("\(name).caf"))
    print(name)
}
