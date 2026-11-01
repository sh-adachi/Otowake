import AudioRealtime
import CoreAudio
import Foundation

// All lifecycle calls run on AudioController's one serial queue. The callback is pure C.
final class ProcessRoute {
    let plan: RoutePlan
    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var ioHandle: OpaquePointer?
    private var render: OpaquePointer?
    private var health = RouteHealth()
    var callbacks: UInt64 { render.map(OWRenderCallbacks) ?? 0 }
    var signalCallbacks: UInt64 { render.map(OWRenderSignalCallbacks) ?? 0 }
    var invalidBuffers: UInt64 { render.map(OWRenderInvalidBuffers) ?? 0 }
    var peak: Float { render.map(OWRenderPeak) ?? 0 }

    init(plan: RoutePlan, rule: AppRule) throws {
        self.plan = plan
        do { try start(rule: rule) }
        catch { stop(); throw error }
    }
    deinit { stop() }
    func setGain(_ gain: Float) { if let render { OWRenderSetGain(render, gain) } }
    func hasFailed(whilePlaying playing: Bool) -> Bool {
        health.hasFailed(playing: playing, callbacks: callbacks, signals: signalCallbacks, invalid: invalidBuffers)
    }

    private func start(rule: AppRule) throws {
        let description = CATapDescription(stereoMixdownOfProcesses: plan.processIDs)
        description.name = "Otowake · \(rule.name)"
        description.uuid = UUID()
        description.isPrivate = true
        // Native playback is restored as soon as this tap stops being consumed.
        description.muteBehavior = .mutedWhenTapped
        try HAL.check(AudioHardwareCreateProcessTap(description, &tapID), "アプリ音声の取得")
        let tapUID = try HAL.string(tapID, kAudioTapPropertyUID)
        let composition: [String: Any] = [
            kAudioAggregateDeviceUIDKey: "jp.otowake.route.\(UUID().uuidString)",
            kAudioAggregateDeviceNameKey: "Otowake · \(rule.name)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: plan.device.uid,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: plan.device.uid]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]]
        ]
        try HAL.check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregateID), "音声ルートの作成")
        // The HAL returns before its aggregate is ready. Never block the UI while waiting.
        var alive = false
        for _ in 0..<30 {
            if (try? HAL.value(aggregateID, kAudioDevicePropertyDeviceIsAlive, UInt32(0))) == 1 { alive = true; break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard alive else { throw HardwareError("音声ルートの起動待機", kAudioHardwareNotRunningError) }

        let physicalInputs = try HAL.objects(plan.device.id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        let inputStreams = try HAL.objects(aggregateID, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        let outputStreams = try HAL.objects(aggregateID, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        // One stereo mixdown tap is appended after physical input streams.
        guard inputStreams.count == physicalInputs.count + 1, !outputStreams.isEmpty else {
            throw HardwareError("音声ストリーム構成の確認", kAudioHardwareBadStreamError)
        }
        let tapStream = inputStreams[physicalInputs.count]
        var inputFormat = try HAL.value(tapStream, kAudioStreamPropertyVirtualFormat, AudioStreamBasicDescription())
        // Aggregate drift compensation converts the tap to the output device's clock.
        let rate = try HAL.value(aggregateID, kAudioDevicePropertyNominalSampleRate, Float64(0))
        guard rate > 0 else { throw HardwareError("サンプルレートの確認", kAudioDeviceUnsupportedFormatError) }
        inputFormat = Self.floatFormat(rate: rate, channels: 2)
        try HAL.set(tapStream, kAudioStreamPropertyVirtualFormat, inputFormat)
        for stream in outputStreams {
            let format = try HAL.value(stream, kAudioStreamPropertyVirtualFormat, AudioStreamBasicDescription())
            try HAL.set(stream, kAudioStreamPropertyVirtualFormat, Self.floatFormat(rate: rate, channels: format.mChannelsPerFrame))
        }
        let checkedInput = try HAL.value(tapStream, kAudioStreamPropertyVirtualFormat, AudioStreamBasicDescription())
        guard Self.isFloatPCM(checkedInput), checkedInput.mChannelsPerFrame == 2, checkedInput.mSampleRate == rate else {
            throw HardwareError("入力フォーマットの確認", kAudioDeviceUnsupportedFormatError)
        }
        for stream in outputStreams {
            let checked = try HAL.value(stream, kAudioStreamPropertyVirtualFormat, AudioStreamBasicDescription())
            guard Self.isFloatPCM(checked), checked.mSampleRate == rate else {
                throw HardwareError("出力フォーマットの確認", kAudioDeviceUnsupportedFormatError)
            }
        }
        let firstChannel = try HAL.value(tapStream, kAudioStreamPropertyStartingChannel, UInt32(1))
        var stereo: (UInt32, UInt32) = (1, UInt32(min(2, plan.device.channels)))
        // Respect the device's configured stereo pair; mono folds down L/R.
        var a = HAL.address(kAudioDevicePropertyPreferredChannelsForStereo, kAudioObjectPropertyScopeOutput)
        var pair = [UInt32](repeating: 0, count: 2), size = UInt32(2 * MemoryLayout<UInt32>.size)
        let status = pair.withUnsafeMutableBytes { AudioObjectGetPropertyData(plan.device.id, &a, 0, nil, &size, $0.baseAddress!) }
        if status == noErr, pair.allSatisfy({ $0 > 0 && $0 <= plan.device.channels }) { stereo = (pair[0], pair[1]) }
        guard let state = OWRenderCreate(firstChannel - 1, stereo.0 - 1, stereo.1 - 1, rule.gain, rate) else {
            throw HardwareError("音声処理メモリの確保", kAudioHardwareUnspecifiedError)
        }
        render = state
        // Avoid opening microphone/line inputs on duplex USB/Bluetooth devices.
        try HAL.check(OWIOCreate(aggregateID, state, UInt32(inputStreams.count), UInt32(physicalInputs.count), &ioHandle), "音声処理の登録と未使用入力の無効化")
        guard let ioHandle else { throw HardwareError("音声処理の登録", kAudioHardwareUnspecifiedError) }
        try HAL.check(OWIOStart(ioHandle), "音声ルートの開始（システムオーディオ録音の許可を確認してください）")
        health.didStart()
    }
    private static func floatFormat(rate: Double, channels: UInt32) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian,
            mBytesPerPacket: 4 * channels, mFramesPerPacket: 1, mBytesPerFrame: 4 * channels,
            mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
    }
    private static func isFloatPCM(_ format: AudioStreamBasicDescription) -> Bool {
        format.mFormatID == kAudioFormatLinearPCM && format.mBitsPerChannel == 32 &&
        format.mFormatFlags & kAudioFormatFlagIsFloat != 0 && format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0 &&
        format.mBytesPerFrame == 4 * (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? 1 : format.mChannelsPerFrame)
    }
    func stop() {
        if let ioHandle { OWIODestroy(ioHandle); self.ioHandle = nil }
        if aggregateID != 0 { AudioHardwareDestroyAggregateDevice(aggregateID); aggregateID = 0 }
        if tapID != 0 { AudioHardwareDestroyProcessTap(tapID); tapID = 0 }
        if let render { OWRenderDestroy(render); self.render = nil }
    }
}
