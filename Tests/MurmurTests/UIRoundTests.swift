import AppKit
import SwiftUI
import Testing
@testable import Murmur

@Suite struct LevelDisplayTests {
    @Test func belowThresholdIsFlat() {
        let threshold = -45.0
        let quiet = Float((-50 + 55) / 50.0)
        #expect(LevelDisplay.gated(quiet, threshold: threshold) == 0)
        #expect(LevelDisplay.gated(0, threshold: threshold) == 0)
    }

    @Test func aboveThresholdRises() {
        let threshold = -45.0
        let speech = Float((-25 + 55) / 50.0)
        let loud = Float((-12 + 55) / 50.0)
        let a = LevelDisplay.gated(speech, threshold: threshold)
        let b = LevelDisplay.gated(loud, threshold: threshold)
        #expect(a > 0 && b > a && b <= 1)
    }

    @Test func roomNoiseNeverMovesBars() {
        let threshold = -45.0
        var v: Float = 0
        for i in 0..<200 {
            let jitter = Float(i % 7) * 0.005
            let noise = Float((-58 + 55) / 50.0) + jitter
            v = LevelDisplay.smooth(v, toward: LevelDisplay.gated(noise, threshold: threshold), dt: 0.021)
        }
        #expect(v == 0)
    }

    @Test func smoothingAttackFasterThanRelease() {
        let up = LevelDisplay.smooth(0, toward: 1, dt: 0.02)
        let down = 1 - LevelDisplay.smooth(1, toward: 0, dt: 0.02)
        #expect(up > down)
        var v: Float = 0
        for _ in 0..<10 { v = LevelDisplay.smooth(v, toward: 1, dt: 0.02) }
        #expect(v > 0.95)
        for _ in 0..<5 { v = LevelDisplay.smooth(v, toward: 0, dt: 0.02) }
        #expect(v > 0.5)
    }

    @Test func meterScaleShowsSpeech() {
        #expect(LevelDisplay.meterFraction(db: -60) == 0)
        #expect(LevelDisplay.meterFraction(db: -10) == 1)
        #expect(LevelDisplay.meterFraction(db: -35) > 0.45 && LevelDisplay.meterFraction(db: -35) < 0.55)
    }
}

@Suite struct CheckMicTests {
    @Test func goodRoomAndVoice() {
        let r = CheckMic.evaluate(quiet: Synth.noise(2, amp: 0.002), speech: Synth.speech(amp: 0.08, lead: 0.3, talk: 3, tail: 0.3))
        #expect(r.verdict == .good)
        #expect(r.threshold > r.noise && r.threshold < r.voice)
        #expect(CheckMic.summary(r).contains("✓ Good"))
    }

    @Test func silentMic() {
        let r = CheckMic.evaluate(quiet: Synth.silence(2), speech: Synth.silence(4))
        #expect(r.verdict == .silent)
    }

    @Test func noVoiceKeepsThresholdUnapplied() {
        let r = CheckMic.evaluate(quiet: Synth.noise(2, amp: 0.002), speech: Synth.noise(4, amp: 0.002, seed: 9))
        #expect(r.verdict == .noVoice)
    }

    @Test func quietVoice() {
        let r = CheckMic.evaluate(quiet: Synth.noise(2, amp: 0.0002), speech: Synth.speech(amp: 0.008, lead: 0.3, talk: 3, tail: 0.3))
        #expect(r.verdict == .tooQuiet)
    }

    @Test func noisyRoom() {
        let r = CheckMic.evaluate(quiet: Synth.noise(2, amp: 0.02), speech: Synth.mix(Synth.noise(4, amp: 0.02, seed: 4), Synth.tone(4, amp: 0.05)))
        #expect(r.verdict == .tooNoisy)
    }
}

@MainActor @Suite(.serialized) struct SteadyUITests {
    @Test func bubbleSameFrameInEveryState() async {
        let phases: [HUDPhase] = [.listening, .working, .done("Done"), .done("Copied"), .done("Copied · allow Accessibility"),
                                  .failed(HUDText.noSpeech), .failed(HUDText.allowAccessibility("Right ⌥"))]
        for k in [CGFloat(0.72), 1, 1.4] {
            var frames: [CGRect] = []
            for p in phases {
                let f = await probeFrames(MicPill(phase: p, levels: Array(repeating: 0.5, count: HUDModel.bars), k: k, paused: true),
                                          size: CGSize(width: 400, height: 120))
                if let r = f["bubble"] { frames.append(r) }
            }
            #expect(frames.count == phases.count)
            #expect(Set(frames.map { "\($0)" }).count == 1, "bubble changed at k=\(k): \(frames)")
            let expected = HUDGeometry.size(k: k)
            #expect(abs(frames[0].width - expected.width) < 0.5 && abs(frames[0].height - expected.height) < 0.5)
        }
    }

    @Test func checkMicRowDoesNotMove() async {
        var seen: [[String: CGRect]] = []
        let tester = MicTester()
        for phase in [MicTester.Phase.idle, .quiet, .speak, .done] {
            tester.phase = phase
            tester.countdown = 3
            tester.check = phase == .done ? CheckMic.Result(noise: -55, voice: -32, threshold: -43, verdict: .good) : nil
            let view = Form { Section { CheckMicRow(tester: tester, threshold: -45, granted: true) { _ in } } }
                .formStyle(.grouped)
                .controlSize(.small)
            seen.append(await probeFrames(view, size: CGSize(width: 480, height: 140)))
        }
        for id in ["level", "checkMic"] {
            let frames = seen.compactMap { $0[id] }
            #expect(frames.count == 4, "missing \(id)")
            #expect(Set(frames.map { "\(Int($0.minX)) \(Int($0.minY)) \(Int($0.width))" }).count == 1, "\(id) moved: \(frames)")
        }
    }

    @Test func micModeButtonDoesNotResize() async {
        var frames: [CGRect] = []
        for listening in [false, true] {
            let f = await probeFrames(MicModeLabel(listening: listening, level: 0.6), size: CGSize(width: 200, height: 40))
            if let r = f["micMode"] { frames.append(r) }
        }
        #expect(frames.count == 2)
        #expect(Set(frames.map { "\($0)" }).count == 1, "mic mode moved: \(frames)")
    }
}
