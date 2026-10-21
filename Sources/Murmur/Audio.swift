import AppKit
import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import os

struct Recording: Sendable {
    let samples: [Float]
    let url: URL
    let dir: URL

    static let sampleRate: Double = 16_000

    var duration: Double { Double(samples.count) / Self.sampleRate }

    func discard() {
        try? FileManager.default.removeItem(at: dir)
    }
}

enum AudioFiles {
    static func privateDir() throws -> URL {
        let base = FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("\(Identity.appName)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return dir
    }

    static func cleanLeftovers() {
        let base = FileManager.default.temporaryDirectory
        let prefix = "\(Identity.appName)-"
        let items = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        for name in items where name.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: base.appendingPathComponent(name))
        }
    }

    static var format16k: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Recording.sampleRate, channels: 1, interleaved: false)!
    }

    static func write(_ samples: [Float], to url: URL) throws {
        let format = format16k
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, samples.count))) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        try file.write(from: buffer)
        file.close()
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func recording(from samples: [Float]) throws -> Recording {
        let dir = try privateDir()
        let url = dir.appendingPathComponent("speech.wav")
        try write(samples, to: url)
        return Recording(samples: samples, url: url, dir: dir)
    }

    static func load(_ source: URL) throws -> Recording {
        try recording(from: readSamples(source))
    }

    static func readSamples(_ source: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: source)
        let input = file.processingFormat
        let out = format16k
        let chunk: AVAudioFrameCount = 32768
        var result: [Float] = []
        result.reserveCapacity(Int(Double(file.length) * out.sampleRate / max(1, input.sampleRate)) + 1024)
        if input.sampleRate == out.sampleRate, input.channelCount == 1, input.commonFormat == .pcmFormatFloat32 {
            while file.framePosition < file.length {
                guard let buf = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: chunk) else { break }
                try file.read(into: buf, frameCount: chunk)
                guard buf.frameLength > 0, let data = buf.floatChannelData?[0] else { break }
                result.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(buf.frameLength)))
            }
            return result
        }
        guard let converter = AVAudioConverter(from: input, to: out) else { throw CocoaError(.fileReadUnsupportedScheme) }
        let capacity = AVAudioFrameCount(Double(chunk) * out.sampleRate / input.sampleRate + 4096)
        var readError: Error?
        while true {
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: capacity) else { break }
            var error: NSError?
            let status = converter.convert(to: outBuf, error: &error) { _, inStatus in
                guard file.framePosition < file.length, let buf = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: chunk) else {
                    inStatus.pointee = .endOfStream
                    return nil
                }
                do { try file.read(into: buf, frameCount: chunk) } catch { readError = error; inStatus.pointee = .endOfStream; return nil }
                if buf.frameLength == 0 { inStatus.pointee = .endOfStream; return nil }
                inStatus.pointee = .haveData
                return buf
            }
            if let error { throw error }
            if let readError { throw readError }
            if let data = outBuf.floatChannelData?[0], outBuf.frameLength > 0 {
                result.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(outBuf.frameLength)))
            }
            if status == .endOfStream || status == .error { break }
        }
        return result
    }

    static func level(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        let rms = (sum / Float(samples.count)).squareRoot()
        let db = 20 * log10(max(rms, 1e-6))
        return min(1, max(0, (db + 55) / 50))
    }
}

enum MicAccess {
    static var status: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }
    static var granted: Bool { status == .authorized }

    static func request() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }
}

enum MonoExtract {
    static func channels(_ buffer: AVAudioPCMBuffer) -> [[Float]] {
        let frames = Int(buffer.frameLength)
        let n = Int(buffer.format.channelCount)
        guard frames > 0, n > 0 else { return [] }
        let interleaved = buffer.format.isInterleaved
        var out = Array(repeating: [Float](repeating: 0, count: frames), count: n)
        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let data = buffer.floatChannelData else { return [] }
            for c in 0..<n {
                if interleaved {
                    let base = data[0]
                    for i in 0..<frames { out[c][i] = base[i * n + c] }
                } else {
                    let ch = data[c]
                    for i in 0..<frames { out[c][i] = ch[i] }
                }
            }
        case .pcmFormatInt16:
            guard let data = buffer.int16ChannelData else { return [] }
            let scale = Float(Int16.max)
            for c in 0..<n {
                for i in 0..<frames {
                    let v = interleaved ? data[0][i * n + c] : data[c][i]
                    out[c][i] = Float(v) / scale
                }
            }
        case .pcmFormatInt32:
            guard let data = buffer.int32ChannelData else { return [] }
            let scale = Float(Int32.max)
            for c in 0..<n {
                for i in 0..<frames {
                    let v = interleaved ? data[0][i * n + c] : data[c][i]
                    out[c][i] = Float(v) / scale
                }
            }
        default:
            return []
        }
        return out
    }

    static func peak(_ x: [Float]) -> Float { x.reduce(0) { max($0, abs($1)) } }

    static func pick(_ channels: [[Float]]) -> (samples: [Float], channel: Int) {
        guard let first = channels.first else { return ([], 0) }
        if peak(first) >= VoiceGate.silentPeak || channels.count == 1 { return (first, 0) }
        var best = 0
        var bestPeak = peak(first)
        for (i, ch) in channels.enumerated().dropFirst() {
            let p = peak(ch)
            if p > bestPeak { best = i; bestPeak = p }
        }
        return (channels[best], best)
    }

    static func mono(_ buffer: AVAudioPCMBuffer) -> (samples: [Float], channel: Int) {
        pick(channels(buffer))
    }
}

final class Resampler {
    let inputRate: Double
    private let converter: AVAudioConverter?
    private let inFormat: AVAudioFormat?

    init(inputRate: Double) {
        self.inputRate = inputRate
        let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1, interleaved: false)
        self.inFormat = inFormat
        converter = (inputRate == Recording.sampleRate || inFormat == nil) ? nil : AVAudioConverter(from: inFormat!, to: AudioFiles.format16k)
    }

    func process(_ mono: [Float]) -> [Float] {
        guard !mono.isEmpty else { return [] }
        guard let converter, let inFormat else { return mono }
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(mono.count)) else { return [] }
        inBuf.frameLength = AVAudioFrameCount(mono.count)
        mono.withUnsafeBufferPointer { inBuf.floatChannelData![0].update(from: $0.baseAddress!, count: mono.count) }
        let capacity = AVAudioFrameCount(Double(mono.count) * Recording.sampleRate / inputRate + 512)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: AudioFiles.format16k, frameCapacity: capacity) else { return [] }
        var fed = false
        var error: NSError?
        converter.convert(to: outBuf, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return inBuf
        }
        guard error == nil, let data = outBuf.floatChannelData?[0], outBuf.frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(outBuf.frameLength)))
    }
}

struct CaptureStats: Equatable, Sendable {
    var inputRate: Double = 0
    var inputChannels: Int = 0
    var interleaved = false
    var rawFrames = 0
    var converted = 0
    var sumSquares: Double = 0
    var peak: Float = 0
    var channelUsed = 0

    var rmsDB: Double {
        guard converted > 0 else { return -120 }
        return 20 * log10(max((sumSquares / Double(converted)).squareRoot(), 1e-7))
    }

    var seconds: Double { Double(converted) / Recording.sampleRate }

    mutating func add(_ chunk: [Float]) {
        converted += chunk.count
        for v in chunk {
            sumSquares += Double(v * v)
            peak = max(peak, abs(v))
        }
    }

    var summary: String {
        String(format: "in %.0f Hz %d ch %@ raw %d → 16k %d (%.2f s) rms %.1f dBFS peak %.4f ch%d",
               inputRate, inputChannels, interleaved ? "interleaved" : "planar", rawFrames, converted, seconds, rmsDB, Double(peak), channelUsed)
    }
}

final class SampleSink: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var capturing = false
    private var resampler: Resampler?
    private var stats = CaptureStats()

    init(input: AVAudioFormat) {
        resampler = Resampler(inputRate: input.sampleRate)
    }

    func begin() {
        lock.lock(); samples.removeAll(); stats = CaptureStats(); capturing = true; lock.unlock()
    }

    var isCapturing: Bool {
        lock.lock(); defer { lock.unlock() }
        return capturing
    }

    func append(_ buffer: AVAudioPCMBuffer) -> Float? {
        guard isCapturing else { return nil }
        let picked = MonoExtract.mono(buffer)
        let level = picked.samples.withUnsafeBufferPointer { AudioFiles.level($0) }
        if resampler == nil || resampler!.inputRate != buffer.format.sampleRate {
            resampler = Resampler(inputRate: buffer.format.sampleRate)
        }
        let chunk = resampler!.process(picked.samples)
        lock.lock()
        if capturing {
            samples.append(contentsOf: chunk)
            stats.inputRate = buffer.format.sampleRate
            stats.inputChannels = Int(buffer.format.channelCount)
            stats.interleaved = buffer.format.isInterleaved
            stats.rawFrames += Int(buffer.frameLength)
            stats.channelUsed = picked.channel
            stats.add(chunk)
        }
        lock.unlock()
        return level
    }

    func peek(from start: Int) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        guard start < samples.count else { return [] }
        return Array(samples[start...])
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return samples.count
    }

    var currentStats: CaptureStats {
        lock.lock(); defer { lock.unlock() }
        return stats
    }

    func take() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        capturing = false
        let out = samples
        samples.removeAll()
        return out
    }
}

enum CaptureLog {
    static let logger = Logger(subsystem: Identity.bundleId, category: "capture")

    static func capture(_ stats: CaptureStats, device: String) {
        logger.notice("capture: \(stats.summary, privacy: .public) device \(device, privacy: .public)")
    }
}

struct RecorderKey: Equatable {
    let device: AudioDeviceID?
}

enum RecorderPlan: Equatable {
    case reuseRunning
    case startPrepared
    case rebuild

    static func decide(current: RecorderKey?, wanted: RecorderKey, running: Bool) -> RecorderPlan {
        guard let current, current == wanted else { return .rebuild }
        return running ? .reuseRunning : .startPrepared
    }

    static let idleSeconds: TimeInterval = 0
}

enum MicModeName {
    static func name(_ mode: AVCaptureDevice.MicrophoneMode) -> String {
        switch mode {
        case .standard: return "Standard"
        case .wideSpectrum: return "Wide Spectrum"
        case .voiceIsolation: return "Voice Isolation"
        @unknown default: return "Standard"
        }
    }
}

@MainActor
final class MicModeController: NSObject, ObservableObject {
    static let shared = MicModeController()
    static let listenSeconds: TimeInterval = 20
    static let firstBufferTimeout: TimeInterval = 1.5

    @Published private(set) var modeName = MicModeName.name(AVCaptureDevice.activeMicrophoneMode)
    @Published private(set) var listening = false
    @Published var showHint = false
    @Published private(set) var level: Float = 0

    private let recorder = Recorder()
    private var gotBuffer = false
    private var stopWork: DispatchWorkItem?
    private var observing = false
    private var poll: Timer?

    override init() {
        super.init()
        recorder.onLevel = { [weak self] l in
            self?.gotBuffer = true
            self?.level = l
        }
        observe()
    }

    private func observe() {
        guard !observing else { return }
        let target = AVCaptureDevice.self as AnyObject
        if let object = target as? NSObject {
            object.addObserver(self, forKeyPath: "activeMicrophoneMode", options: [.new], context: nil)
            object.addObserver(self, forKeyPath: "preferredMicrophoneMode", options: [.new], context: nil)
            observing = true
        }
    }

    override nonisolated func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                           change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        Task { @MainActor in self.refresh() }
    }

    func refresh() {
        modeName = MicModeName.name(AVCaptureDevice.activeMicrophoneMode)
    }

    func show() {
        guard MicAccess.granted else {
            Task { if !(await MicAccess.request()) { MicAccess.openSettings() } }
            return
        }
        if Dictation.shared.isListening || recorder.running {
            present()
            return
        }
        Dictation.shared.releaseAudio()
        gotBuffer = false
        do {
            try recorder.start()
        } catch {
            showHint = true
            return
        }
        listening = true
        startPolling()
        scheduleStop()
        let deadline = Date().addingTimeInterval(Self.firstBufferTimeout)
        func wait() {
            if gotBuffer || Date() > deadline {
                present()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { wait() }
            }
        }
        wait()
    }

    private func present() {
        AVCaptureDevice.showSystemUserInterface(.microphoneModes)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.listening || Dictation.shared.isListening else { return }
            self.showHint = true
        }
    }

    private func scheduleStop() {
        stopWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.stop() }
        stopWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.listenSeconds, execute: w)
    }

    private func startPolling() {
        poll?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        poll = t
    }

    func stop() {
        stopWork?.cancel()
        stopWork = nil
        poll?.invalidate()
        poll = nil
        if recorder.running { _ = recorder.stop(keepWarm: false) }
        listening = false
        showHint = false
        level = 0
        refresh()
    }
}

enum MacMic {
    @MainActor static func showMicModes() {
        MicModeController.shared.show()
    }

    static let soundInputURL = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension?input")!
    static let soundURL = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!

    static func openSoundSettings() {
        if !NSWorkspace.shared.open(soundInputURL) { NSWorkspace.shared.open(soundURL) }
    }
}

@MainActor
final class Recorder {
    private var engine: AVAudioEngine?
    private var sink: SampleSink?
    private var key: RecorderKey?
    private var engineRunning = false
    private var idle: DispatchWorkItem?
    private var configObserver: NSObjectProtocol?
    private(set) var running = false
    private(set) var lastStartMillis: Double = 0
    private(set) var lastStats = CaptureStats()
    private(set) var deviceName = ""
    var defaultInput: () -> AudioDeviceID? = { CoreAudioMics.defaultInput() }
    var onLevel: (Float) -> Void = { _ in }

    var currentKey: RecorderKey { RecorderKey(device: defaultInput()) }

    func prepare() {
        guard !running, MicAccess.granted else { return }
        let wanted = currentKey
        guard RecorderPlan.decide(current: key, wanted: wanted, running: engineRunning) == .rebuild else { return }
        teardown()
        if (try? build()) != nil { key = wanted }
    }

    func invalidate() {
        guard !running else { return }
        teardown()
    }

    func start() throws {
        guard !running else { return }
        let t0 = Date()
        idle?.cancel()
        let wanted = currentKey
        var plan = RecorderPlan.decide(current: key, wanted: wanted, running: engineRunning)
        if plan == .rebuild {
            teardown()
            try build()
            key = wanted
            plan = .startPrepared
        }
        guard let engine, let sink else { throw CocoaError(.featureUnsupported) }
        sink.begin()
        if plan == .startPrepared {
            do {
                try engine.start()
                engineRunning = true
            } catch {
                _ = sink.take()
                teardown()
                throw error
            }
        }
        running = true
        lastStartMillis = Date().timeIntervalSince(t0) * 1000
    }

    private func build() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        deviceName = CoreAudioMics.name(of: defaultInput()) ?? "default"
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CocoaError(.featureUnsupported) }
        let sink = SampleSink(input: format)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let level = sink.append(buffer) else { return }
            Task { @MainActor in self?.onLevel(level) }
        }
        engine.prepare()
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.configurationChanged() }
        }
        self.engine = engine
        self.sink = sink
        engineRunning = false
    }

    private func configurationChanged() {
        if running {
            key = nil
            return
        }
        teardown()
    }

    private func teardown() {
        idle?.cancel()
        idle = nil
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            if engineRunning { engine.stop() }
        }
        engine = nil
        sink = nil
        key = nil
        engineRunning = false
        running = false
    }

    func samples(from start: Int) -> [Float] {
        sink?.peek(from: start) ?? []
    }

    func stop(keepWarm: Bool = true) -> [Float] {
        guard running else { return [] }
        running = false
        lastStats = sink?.currentStats ?? CaptureStats()
        let out = sink?.take() ?? []
        CaptureLog.capture(lastStats, device: deviceName)
        if keepWarm, key != nil { scheduleIdleStop() } else { teardown() }
        return out
    }

    private func scheduleIdleStop() {
        idle?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.running, let engine = self.engine, self.engineRunning else { return }
                engine.stop()
                self.engineRunning = false
                engine.prepare()
            }
        }
        idle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + RecorderPlan.idleSeconds, execute: work)
    }
}
