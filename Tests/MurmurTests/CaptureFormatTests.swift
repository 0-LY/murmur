import AVFoundation
import Foundation
import Testing
@testable import Murmur

enum VFSynth {
    static func tone(seconds: Double, rate: Double, amp: Float = 0.1, freq: Double = 220) -> [Float] {
        let n = Int(seconds * rate)
        return (0..<n).map { amp * Float(sin(2 * Double.pi * freq * Double($0) / rate)) }
    }

    static func silence(seconds: Double, rate: Double = 16_000) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * rate))
    }

    static func buffer(channels: [[Float]], rate: Double, interleaved: Bool,
                       common: AVAudioCommonFormat = .pcmFormatFloat32) -> AVAudioPCMBuffer {
        let n = channels.count
        let frames = channels[0].count
        let format = fmt(rate: rate, channels: n, interleaved: interleaved, common: common)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buf.frameLength = AVAudioFrameCount(frames)
        switch common {
        case .pcmFormatFloat32:
            let data = buf.floatChannelData!
            for c in 0..<n {
                for i in 0..<frames {
                    if interleaved { data[0][i * n + c] = channels[c][i] } else { data[c][i] = channels[c][i] }
                }
            }
        case .pcmFormatInt16:
            let data = buf.int16ChannelData!
            for c in 0..<n {
                for i in 0..<frames {
                    let v = Int16(max(-1, min(1, channels[c][i])) * Float(Int16.max))
                    if interleaved { data[0][i * n + c] = v } else { data[c][i] = v }
                }
            }
        default: break
        }
        return buf
    }

    static func fmt(rate: Double, channels n: Int, interleaved: Bool, common: AVAudioCommonFormat = .pcmFormatFloat32) -> AVAudioFormat {
        if n <= 2 {
            return AVAudioFormat(commonFormat: common, sampleRate: rate, channels: AVAudioChannelCount(n), interleaved: interleaved)!
        }
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(n))!
        return AVAudioFormat(commonFormat: common, sampleRate: rate, interleaved: interleaved, channelLayout: layout)
    }

    static func speechLike(voicedSeconds: Double, gap: Double = 0.4, amp: Float = 0.1) -> [Float] {
        var out: [Float] = []
        var left = voicedSeconds
        while left > 0 {
            let chunk = min(0.8, left)
            out += tone(seconds: chunk, rate: 16_000, amp: amp)
            out += silence(seconds: gap)
            left -= chunk
        }
        return out
    }
}

@Suite struct MonoExtractTests {
    @Test func picksChannelZeroFromThreeChannelPlanar() {
        let sig = VFSynth.tone(seconds: 0.1, rate: 48_000)
        let zero = [Float](repeating: 0, count: sig.count)
        let buf = VFSynth.buffer(channels: [sig, zero, zero], rate: 48_000, interleaved: false)
        let m = MonoExtract.mono(buf)
        #expect(m.channel == 0)
        #expect(m.samples.count == sig.count)
        #expect(MonoExtract.peak(m.samples) > 0.09)
    }

    @Test func fallsBackToLoudestChannelWhenChannelZeroIsSilent() {
        let sig = VFSynth.tone(seconds: 0.1, rate: 48_000)
        let zero = [Float](repeating: 0, count: sig.count)
        let buf = VFSynth.buffer(channels: [zero, zero, sig], rate: 48_000, interleaved: false)
        let m = MonoExtract.mono(buf)
        #expect(m.channel == 2)
        #expect(MonoExtract.peak(m.samples) > 0.09)
    }

    @Test func readsInterleavedStereo() {
        let a = VFSynth.tone(seconds: 0.05, rate: 44_100, amp: 0.2)
        let b = VFSynth.tone(seconds: 0.05, rate: 44_100, amp: 0.05)
        let m = MonoExtract.mono(VFSynth.buffer(channels: [a, b], rate: 44_100, interleaved: true))
        #expect(m.channel == 0)
        #expect(abs(MonoExtract.peak(m.samples) - 0.2) < 0.01)
    }

    @Test func readsInt16() {
        let a = VFSynth.tone(seconds: 0.05, rate: 16_000, amp: 0.5)
        let m = MonoExtract.mono(VFSynth.buffer(channels: [a], rate: 16_000, interleaved: true, common: .pcmFormatInt16))
        #expect(abs(MonoExtract.peak(m.samples) - 0.5) < 0.01)
    }
}

@Suite struct ResampleAndDurationTests {
    @Test(arguments: [48_000.0, 44_100.0, 24_000.0, 16_000.0])
    func oneSecondBecomesSixteenThousandSamples(rate: Double) {
        let r = Resampler(inputRate: rate)
        var total = 0
        let block = Int(rate / 50)
        let sig = VFSynth.tone(seconds: 1, rate: rate)
        var i = 0
        while i < sig.count {
            total += r.process(Array(sig[i..<min(sig.count, i + block)])).count
            i += block
        }
        #expect(abs(total - 16_000) < 400)
    }

    @Test func sinkCountsConvertedSamplesFromVoiceProcessingFormat() {
        let rate = 48_000.0
        let format = VFSynth.fmt(rate: rate, channels: 3, interleaved: false)
        let sink = SampleSink(input: format)
        sink.begin()
        for _ in 0..<50 {
            let sig = VFSynth.tone(seconds: 0.02, rate: rate)
            let zero = [Float](repeating: 0, count: sig.count)
            _ = sink.append(VFSynth.buffer(channels: [sig, zero, zero], rate: rate, interleaved: false))
        }
        let stats = sink.currentStats
        let samples = sink.take()
        #expect(abs(samples.count - 16_000) < 400)
        #expect(abs(stats.seconds - 1) < 0.03)
        #expect(stats.inputChannels == 3)
        #expect(stats.rawFrames == 48_000)
        #expect(stats.peak > 0.09)
        #expect(stats.rmsDB > -25 && stats.rmsDB < -15)
        #expect(!VoiceGate.isSilentInput(samples))
    }
}

