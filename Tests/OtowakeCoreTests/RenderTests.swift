import AudioRealtime
import CoreAudio
import Foundation
import Testing

// Owns a variable-length ABL, just like the HAL. Allows testing the real C callback.
private final class Buffers {
    let raw: UnsafeMutableRawPointer
    let pointer: UnsafeMutablePointer<AudioBufferList>
    let layout: [Int]
    let frames: Int
    init(_ layout: [Int], frames: Int = 512, values: [Float] = []) {
        self.layout = layout; self.frames = frames
        raw = .allocate(byteCount: MemoryLayout<AudioBufferList>.size + (layout.count - 1) * MemoryLayout<AudioBuffer>.stride,
                        alignment: MemoryLayout<AudioBufferList>.alignment)
        pointer = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        pointer.pointee.mNumberBuffers = UInt32(layout.count)
        let list = UnsafeMutableAudioBufferListPointer(pointer)
        for (i, channels) in layout.enumerated() {
            let count = frames * channels
            let memory = UnsafeMutablePointer<Float>.allocate(capacity: count)
            memory.initialize(repeating: 0, count: count)
            for f in 0..<frames { for c in 0..<channels { memory[f * channels + c] = values.isEmpty ? 0 : values[(layout.prefix(i).reduce(0, +) + c) % values.count] } }
            list[i] = AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(count * 4), mData: memory)
        }
    }
    deinit {
        for b in UnsafeMutableAudioBufferListPointer(pointer) { b.mData?.assumingMemoryBound(to: Float.self).deallocate() }
        raw.deallocate()
    }
    func sample(buffer: Int = 0, frame: Int = 511, channel: Int = 0) -> Float {
        let b = UnsafeMutableAudioBufferListPointer(pointer)[buffer]
        return b.mData!.assumingMemoryBound(to: Float.self)[frame * Int(b.mNumberChannels) + channel]
    }
}

struct RenderTests {
    @Test func stereoGainAndTelemetry() throws {
        let state = try #require(OWRenderCreate(0, 0, 1, 0.25, 48000)); defer { OWRenderDestroy(state) }
        let input = Buffers([2], values: [0.8, -0.4]), output = Buffers([2], values: [1, 1])
        OWRenderProcess(state, input.pointer, output.pointer)
        #expect(abs(output.sample() - 0.2) < 0.000001)
        #expect(abs(output.sample(channel: 1) + 0.1) < 0.000001)
        #expect(OWRenderCallbacks(state) == 1); #expect(OWRenderSignalCallbacks(state) == 1)
        #expect(abs(OWRenderPeak(state) - 0.2) < 0.000001)
    }
    @Test func ignoresPhysicalMicAndSupportsPlanarStereoOutput() throws {
        let state = try #require(OWRenderCreate(2, 0, 1, 1, 48000)); defer { OWRenderDestroy(state) }
        let input = Buffers([2, 2], values: [0.95, 0.95, 0.2, -0.3]), output = Buffers([1, 1])
        OWRenderProcess(state, input.pointer, output.pointer)
        #expect(abs(output.sample(buffer: 0) - 0.2) < 0.000001)
        #expect(abs(output.sample(buffer: 1) + 0.3) < 0.000001)
    }
    @Test func planarInputAndPreferredOutputChannelsLeaveOthersSilent() throws {
        let state = try #require(OWRenderCreate(0, 2, 3, 1, 48000)); defer { OWRenderDestroy(state) }
        let input = Buffers([1, 1], values: [0.2, 0.4]), output = Buffers([4], values: [1, 1, 1, 1])
        OWRenderProcess(state, input.pointer, output.pointer)
        #expect(output.sample(channel: 0) == 0); #expect(output.sample(channel: 1) == 0)
        #expect(abs(output.sample(channel: 2) - 0.2) < 0.000001)
        #expect(abs(output.sample(channel: 3) - 0.4) < 0.000001)
    }
    @Test func monoOutputFoldsDown() throws {
        let state = try #require(OWRenderCreate(0, 0, 0, 1, 48000)); defer { OWRenderDestroy(state) }
        let input = Buffers([2], values: [0.2, 0.6]), output = Buffers([1])
        OWRenderProcess(state, input.pointer, output.pointer)
        #expect(abs(output.sample() - 0.4) < 0.000001)
    }
    @Test func muteRampsAndUnmuteRecoversWithoutRebuilding() throws {
        let state = try #require(OWRenderCreate(0, 0, 1, 1, 48000)); defer { OWRenderDestroy(state) }
        let input = Buffers([2], values: [0.5, 0.5]), output = Buffers([2])
        OWRenderSetGain(state, 0); OWRenderProcess(state, input.pointer, output.pointer)
        #expect(output.sample(frame: 0) > 0.49); #expect(output.sample() == 0)
        OWRenderSetGain(state, 0.6); OWRenderProcess(state, input.pointer, output.pointer)
        #expect(abs(output.sample() - 0.3) < 0.000001)
    }
    @Test func missingBuffersFailSilentWithoutReadingOutOfBounds() throws {
        let state = try #require(OWRenderCreate(20, 0, 1, 1, 48000)); defer { OWRenderDestroy(state) }
        let input = Buffers([2], frames: 4), output = Buffers([2], values: [1, 1])
        OWRenderProcess(state, input.pointer, output.pointer)
        #expect(output.sample() == 0); #expect(OWRenderInvalidBuffers(state) == 1)
    }
    @Test func shortBufferAndNonfiniteSamplesAreSafe() throws {
        let state = try #require(OWRenderCreate(0, 0, 1, 1, 48000)); defer { OWRenderDestroy(state) }
        let input = Buffers([2], frames: 2, values: [.nan, .infinity]), output = Buffers([2], values: [1, 1])
        OWRenderProcess(state, input.pointer, output.pointer)
        #expect(output.sample(frame: 0) == 0); #expect(output.sample() == 0)
    }
}
