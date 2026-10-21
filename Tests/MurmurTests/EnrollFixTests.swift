import AVFoundation
import Foundation
import Testing
@testable import Murmur

@Suite struct VoiceModelFilesTests {
    private func makeModel(_ root: URL, _ name: String, files: [String]) throws {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        for f in files {
            let url = dir.appendingPathComponent(f)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 1, count: 64).write(to: url)
        }
    }

    private func scratch() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("vmf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @Test func completeLayoutPasses() throws {
        let d = try scratch()
        try makeModel(d, "CamPlusPreprocessor.mlmodelc", files: ["coremldata.bin", "model.mil", "analytics/coremldata.bin"])
        try makeModel(d, "CamPlusPlus.mlmodelc", files: ["coremldata.bin", "model.mil", "weights/weight.bin"])
        #expect(VoiceModelFiles.complete(at: d))
    }

    @Test func usersBrokenLayoutIsIncomplete() throws {
        let d = try scratch()
        try makeModel(d, "CamPlusPreprocessor.mlmodelc", files: ["analytics/coremldata.bin"])
        try makeModel(d, "CamPlusPlus.mlmodelc", files: ["coremldata.bin", "model.mil", "weights/weight.bin", "analytics/coremldata.bin"])
        #expect(!VoiceModelFiles.complete(at: d))
        #expect(VoiceModelFiles.present(at: d))
    }

    @Test func missingIsIncomplete() throws {
        #expect(!VoiceModelFiles.complete(at: try scratch()))
    }
}

@Suite struct VoiceErrorTests {
    @Test func mapping() {
        #expect(VoiceError.from(URLError(.notConnectedToInternet)) == .downloadFailed)
        #expect(VoiceError.from(NSError(domain: NSURLErrorDomain, code: -1001)) == .downloadFailed)
        #expect(VoiceError.from(VoiceError.incomplete) == .incomplete)
        #expect(VoiceError.from(NSError(domain: "com.apple.CoreML", code: 0)) == .loadFailed)
    }

    @Test func messagesAreSpecific() {
        #expect(VoiceError.downloadFailed.message.contains("connection"))
        #expect(VoiceError.incomplete.message.contains("completely"))
        let all: [VoiceError] = [.downloadFailed, .incomplete, .loadFailed, .badEmbedding, .tooShort, .saveFailed]
        #expect(Set(all.map(\.message)).count == all.count)
        #expect(!all.contains { $0.message.contains("Couldn't learn your voice — try again") })
    }
}

@Suite struct MicModeNameTests {
    @Test func names() {
        #expect(MicModeName.name(.standard) == "Standard")
        #expect(MicModeName.name(.voiceIsolation) == "Voice Isolation")
        #expect(MicModeName.name(.wideSpectrum) == "Wide Spectrum")
    }
}
