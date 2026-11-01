import CoreAudio
import Foundation

public struct SmokeTestError: LocalizedError {
    let message: String
    public var errorDescription: String? { message }
}

extension AudioDiagnostics {
    // Opt-in integration test: two independent afplay sources, real taps, real device IO.
    // Only synthesized quiet test tones are used; no user's application is intercepted.
    public static func smokeTest(outputUIDs: [String]) throws -> String {
        let devices = try HAL.devices()
        let defaultID = try HAL.value(HAL.system, kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(0))
        let requested = outputUIDs.isEmpty ? devices.filter { $0.id == defaultID } : outputUIDs.compactMap { uid in devices.first { $0.uid == uid } }
        guard !requested.isEmpty, outputUIDs.isEmpty || requested.count == outputUIDs.count else {
            throw SmokeTestError(message: "指定した出力デバイスが見つかりません。--diagnose でUIDを確認してください。")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Otowake-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var players: [Process] = []
        var routes: [ProcessRoute] = []
        let beforeTaps = Set(try HAL.objects(HAL.system, kAudioHardwarePropertyTapList))
        defer {
            routes.forEach { $0.stop() }
            for player in players where player.isRunning { player.terminate(); player.waitUntilExit() }
        }
        var report = ["Core Audio integration test (synthesized tones, 44.1 kHz, -42 dBFS)"]
        for (index, device) in requested.enumerated() {
            let tone = directory.appendingPathComponent("tone-\(index).wav")
            try testWave(frequency: 440 + Double(index) * 220).write(to: tone)
            let player = Process(); player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            player.arguments = [tone.path]; try player.run(); players.append(player)
            var object: AudioObjectID = 0
            for _ in 0..<30 {
                var pid = player.processIdentifier, a = HAL.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
                var size = UInt32(MemoryLayout<AudioObjectID>.size)
                try HAL.check(AudioObjectGetPropertyData(HAL.system, &a, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object), "テスト音源の取得")
                if object != 0 { break }
                Thread.sleep(forTimeInterval: 0.1)
            }
            guard object != 0 else { throw SmokeTestError(message: "テスト音源がCore Audioに登録されませんでした。") }
            let plan = RoutePlan(processIDs: [object], device: device, sourceFingerprint: "smoke-test")
            let route = try ProcessRoute(plan: plan, rule: AppRule(name: "Test \(index + 1)", volume: 0.5))
            routes.append(route)
        }
        Thread.sleep(forTimeInterval: 2)
        for (index, route) in routes.enumerated() {
            guard route.callbacks > 0, route.signalCallbacks > 0, route.invalidBuffers == 0, route.peak > 0.0001 else {
                throw SmokeTestError(message: "音声取得を検証できませんでした（\(requested[index].name), callbacks=\(route.callbacks), signal=\(route.signalCallbacks), invalid=\(route.invalidBuffers)）。システムオーディオ録音を許可して再実行してください。")
            }
            report.append("PASS route \(index + 1): \(requested[index].name), callbacks=\(route.callbacks), signal=\(route.signalCallbacks), output peak=\(route.peak)")
            route.setGain(0)
        }
        Thread.sleep(forTimeInterval: 0.3)
        guard routes.allSatisfy({ $0.peak < 0.000001 }) else { throw SmokeTestError(message: "ミュートの検証に失敗しました。") }
        report.append("PASS mute: all output buffers are silent")
        // Validate the handover used by AudioController while muted: start new, then stop old.
        for index in routes.indices {
            let previous = routes[index]
            let destination = requested[(index + 1) % requested.count]
            let plan = RoutePlan(processIDs: previous.plan.processIDs, device: destination, sourceFingerprint: "smoke-test-switch")
            let replacement = try ProcessRoute(plan: plan, rule: AppRule(name: "Test replacement", muted: true))
            // Bluetooth can take longer than 200ms to deliver its first buffers.
            // Wait for real source data, retaining the old muted route throughout.
            let deadline = Date().addingTimeInterval(3)
            while replacement.signalCallbacks == 0 && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            guard replacement.signalCallbacks > 0, replacement.peak == 0, replacement.invalidBuffers == 0 else {
                let detail = "device=\(destination.name), callbacks=\(replacement.callbacks), signal=\(replacement.signalCallbacks), invalid=\(replacement.invalidBuffers), peak=\(replacement.peak)"
                replacement.stop(); throw SmokeTestError(message: "ミュート中のデバイス切り替えを検証できませんでした（\(detail)）。")
            }
            routes[index] = replacement
            previous.stop()
        }
        report.append("PASS device handover: replacement taps receive audio while muted")
        routes.forEach { $0.setGain(0.25) }
        Thread.sleep(forTimeInterval: 0.3)
        guard routes.allSatisfy({ $0.peak > 0.0001 && $0.peak < 0.003 }) else { throw SmokeTestError(message: "音量変更とミュート解除の検証に失敗しました。") }
        report.append("PASS gain/unmute: 25% output amplitude")
        routes.forEach { $0.stop() }
        Thread.sleep(forTimeInterval: 0.1)
        let afterTaps = Set(try HAL.objects(HAL.system, kAudioHardwarePropertyTapList))
        guard afterTaps.subtracting(beforeTaps).isEmpty else { throw SmokeTestError(message: "タップの解放を確認できませんでした。") }
        report.append("PASS teardown: no remaining test taps; native playback restored")
        return report.joined(separator: "\n")
    }

    private static func testWave(frequency: Double) -> Data {
        let rate = 44100, frames = rate * 30
        var data = Data()
        func string(_ value: String) { data.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) { var x = value.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var x = value.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        string("RIFF"); u32(UInt32(36 + frames * 4)); string("WAVEfmt "); u32(16); u16(1); u16(2)
        u32(UInt32(rate)); u32(UInt32(rate * 4)); u16(4); u16(16); string("data"); u32(UInt32(frames * 4))
        for frame in 0..<frames {
            let fade = min(1, Double(frame) / 441, Double(frames - frame) / 441)
            let sample = Int16(sin(Double(frame) * 2 * .pi * frequency / Double(rate)) * 260 * fade)
            u16(UInt16(bitPattern: sample)); u16(UInt16(bitPattern: sample))
        }
        return data
    }
}
