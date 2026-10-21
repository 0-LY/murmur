import AVFoundation
import Foundation
import Testing
@testable import Murmur

struct SoundFileTests {
    static let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/Sounds", isDirectory: true)

    static func samples(_ name: String) throws -> (rate: Double, channels: Int, data: [Float]) {
        let file = try AVAudioFile(forReading: dir.appendingPathComponent("\(name).caf"))
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: file.fileFormat.sampleRate,
                                   channels: file.fileFormat.channelCount, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let n = Int(buffer.frameLength)
        let data = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: n))
        return (file.fileFormat.sampleRate, Int(file.fileFormat.channelCount), data)
    }

    @Test(arguments: SoundSet.allCases.flatMap { [$0.file(start: true), $0.file(start: false)] })
    func soundIsShortQuietAndClean(_ name: String) throws {
        let s = try Self.samples(name)
        #expect(s.rate == 44_100)
        #expect(s.channels == 1)
        let seconds = Double(s.data.count) / s.rate
        #expect(seconds > 0.1 && seconds <= 0.35)
        let peak = s.data.map(abs).max() ?? 0
        let peakDB = 20 * log10(Double(peak))
        #expect(peakDB <= -6 && peakDB >= -9)
        let mean = s.data.reduce(0, +) / Float(s.data.count)
        #expect(abs(mean) < 0.002)
        #expect(s.data.prefix(32).allSatisfy { abs($0) < 0.005 })
        #expect(s.data.suffix(32).allSatisfy { abs($0) < 0.005 })
        let jump = zip(s.data, s.data.dropFirst()).map { abs($1 - $0) }.max() ?? 0
        #expect(jump < 0.2)
    }

    @Test func deepRisesForStartAndFallsForStop() throws {
        func zeroCrossRate(_ x: ArraySlice<Float>) -> Double {
            Double(zip(x, x.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count) / Double(x.count)
        }
        let start = try Self.samples("deep-start").data
        let stop = try Self.samples("deep-stop").data
        let a = Int(0.04 * 44_100), b = Int(0.22 * 44_100)
        #expect(zeroCrossRate(start[a..<a + 2000]) < zeroCrossRate(start[b..<b + 2000]))
        #expect(zeroCrossRate(stop[a..<a + 2000]) > zeroCrossRate(stop[b..<b + 2000]))
    }

    @Test func everySetHasBothFiles() {
        for set in SoundSet.allCases {
            for start in [true, false] {
                #expect(FileManager.default.fileExists(atPath: Self.dir.appendingPathComponent("\(set.file(start: start)).caf").path))
            }
        }
    }
}

struct MigrationTests {
    func sandbox() throws -> (home: URL, support: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MurmurMigration-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".config/speak"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support.appendingPathComponent("Speak/Models/parakeet-ultra"), withIntermediateDirectories: true)
        try Data(#"{"engine":"parakeet-ultra"}"#.utf8).write(to: home.appendingPathComponent(".config/speak/config.json"))
        try Data(repeating: 7, count: 4096).write(to: support.appendingPathComponent("Speak/Models/parakeet-ultra/weights.bin"))
        try Data("{}".utf8).write(to: support.appendingPathComponent("Speak/Models/.library.json"))
        return (home, support)
    }

    @Test func movesModelsAndSettings() throws {
        let (home, support) = try sandbox()
        Migration.run(previous: ["Speak"], appName: "Murmur", configDir: "murmur", home: home, support: support)
        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: support.appendingPathComponent("Speak").path))
        let weights = support.appendingPathComponent("Murmur/Models/parakeet-ultra/weights.bin")
        #expect(try Data(contentsOf: weights) == Data(repeating: 7, count: 4096))
        #expect(fm.fileExists(atPath: support.appendingPathComponent("Murmur/Models/.library.json").path))
        let cfg = home.appendingPathComponent(".config/murmur/config.json")
        #expect(String(decoding: try Data(contentsOf: cfg), as: UTF8.self) == #"{"engine":"parakeet-ultra"}"#)
        #expect(!fm.fileExists(atPath: home.appendingPathComponent(".config/speak").path))
        let dirPerm = try fm.attributesOfItem(atPath: cfg.deletingLastPathComponent().path)[.posixPermissions] as? Int
        let filePerm = try fm.attributesOfItem(atPath: cfg.path)[.posixPermissions] as? Int
        #expect(dirPerm == 0o700 && filePerm == 0o600)
    }

    @Test func runningTwiceChangesNothing() throws {
        let (home, support) = try sandbox()
        Migration.run(previous: ["Speak"], appName: "Murmur", configDir: "murmur", home: home, support: support)
        Migration.run(previous: ["Speak"], appName: "Murmur", configDir: "murmur", home: home, support: support)
        let weights = support.appendingPathComponent("Murmur/Models/parakeet-ultra/weights.bin")
        #expect(try Data(contentsOf: weights).count == 4096)
    }

    @Test func neverOverwritesUsedTarget() throws {
        let (home, support) = try sandbox()
        let mine = support.appendingPathComponent("Murmur/Models/redux/w.bin")
        try FileManager.default.createDirectory(at: mine.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: mine)
        #expect(Migration.move(from: support.appendingPathComponent("Speak"), to: support.appendingPathComponent("Murmur")) == .targetInUse)
        #expect(FileManager.default.fileExists(atPath: support.appendingPathComponent("Speak/Models/parakeet-ultra/weights.bin").path))
        #expect(try Data(contentsOf: mine) == Data([1, 2, 3]))
        _ = home
    }

    @Test func emptyTargetIsReplaced() throws {
        let (_, support) = try sandbox()
        try FileManager.default.createDirectory(at: support.appendingPathComponent("Murmur/Models"), withIntermediateDirectories: true)
        #expect(Migration.move(from: support.appendingPathComponent("Speak"), to: support.appendingPathComponent("Murmur")) == .moved)
    }

    @Test func nothingToDoWithoutOldNames() throws {
        let (home, support) = try sandbox()
        Migration.run(previous: [], appName: "Murmur", configDir: "murmur", home: home, support: support)
        #expect(FileManager.default.fileExists(atPath: support.appendingPathComponent("Speak").path))
        #expect(Migration.previousNames(["AppPreviousNames": "Speak, \(Identity.appName)"]) == ["Speak"])
        #expect(Migration.previousNames([:]).isEmpty)
    }
}
