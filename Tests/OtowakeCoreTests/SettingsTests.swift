import Foundation
import Testing
@testable import OtowakeCore

struct SettingsTests {
    @Test func settingsSurviveNewStoreInstance() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        var settings = Preferences(); settings.enabled = true
        settings.rules["com.google.Chrome"] = AppRule(name: "Chrome", deviceUID: "display:123", deviceName: "Monitor", volume: 0.37, muted: true)
        settings.rules["com.openai.chat"] = AppRule(name: "ChatGPT", deviceUID: "headphones:456", volume: 0.8)
        try SettingsFile(url: url).save(settings)
        #expect(try SettingsFile(url: url).load() == settings)
    }
    @Test func missingSettingsStartDisabled() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(try SettingsFile(url: url).load() == Preferences())
    }
    @Test func corruptFileIsNotOverwrittenByLoad() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let bytes = Data("not json".utf8); try bytes.write(to: url)
        #expect(throws: (any Error).self) { try SettingsFile(url: url).load() }
        #expect(try Data(contentsOf: url) == bytes)
    }
    @Test func rejectsFutureVersionAndOutOfRangeGain() throws {
        var future = Preferences(); future.version = 99
        #expect(throws: SettingsError.self) { try future.validated() }
        var invalid = Preferences(); var rule = AppRule(name: "App"); rule.volume = -1
        invalid.rules["app.id"] = rule
        #expect(throws: SettingsError.self) { try invalid.validated() }
    }
    @Test func constructorClampsAndMuteRetainsVolume() {
        #expect(AppRule(name: "App", volume: .nan).volume == 1)
        #expect(AppRule(name: "App", volume: 2).volume == 1)
        var rule = AppRule(name: "App", volume: 0.37, muted: true)
        #expect(rule.gain == 0); #expect(rule.volume == 0.37)
        rule.muted = false; #expect(abs(rule.gain - 0.37) < 0.00001)
    }
}

struct RoutePlannerTests {
    let monitor = OutputDevice(id: 10, uid: "monitor", name: "Monitor", channels: 2, sampleRate: 48000)
    let headphones = OutputDevice(id: 20, uid: "headphones", name: "Headphones", channels: 2, sampleRate: 44100)
    let chrome = AudioApplication(id: "com.google.Chrome", name: "Chrome", processIDs: [3, 1], isPlaying: true)
    let chatGPT = AudioApplication(id: "com.openai.chat", name: "ChatGPT", processIDs: [7], isPlaying: true)
    func decide(_ app: AudioApplication, _ rule: AppRule?, enabled: Bool = true, devices: [OutputDevice]? = nil, defaultUID: String = "monitor") -> RouteDecision {
        RoutePlanner.decide(app: app, rule: rule, enabled: enabled, devices: devices ?? [monitor, headphones], defaultUID: defaultUID, sourceFingerprint: "source")
    }
    @Test func simultaneousApplicationsUseIndependentDevices() {
        #expect(decide(chrome, AppRule(name: "Chrome", deviceUID: "monitor")) == .route(RoutePlan(processIDs: [1, 3], device: monitor, sourceFingerprint: "source")))
        #expect(decide(chatGPT, AppRule(name: "ChatGPT", deviceUID: "headphones", volume: 0.3)) == .route(RoutePlan(processIDs: [7], device: headphones, sourceFingerprint: "source")))
    }
    @Test func nativeDefaultsDoNotCreateAnyTap() {
        #expect(decide(chrome, nil) == .idle(.native))
        #expect(decide(chrome, AppRule(name: "Chrome")) == .idle(.native))
    }
    @Test func volumeAndMuteNeedTapOnDefaultOutput() {
        #expect(decide(chrome, AppRule(name: "Chrome", volume: 0.5)) == .route(RoutePlan(processIDs: [1, 3], device: monitor, sourceFingerprint: "source")))
        #expect(decide(chrome, AppRule(name: "Chrome", muted: true), defaultUID: "headphones") == .route(RoutePlan(processIDs: [1, 3], device: headphones, sourceFingerprint: "source")))
    }
    @Test func missingDeviceRestoresNativeAndReconnectReusesSavedChoice() {
        let rule = AppRule(name: "Chrome", deviceUID: "headphones", deviceName: "Headphones")
        #expect(decide(chrome, rule, devices: [monitor]) == .idle(.missingDevice("Headphones")))
        #expect(decide(chrome, rule) == .route(RoutePlan(processIDs: [1, 3], device: headphones, sourceFingerprint: "source")))
    }
    @Test func pauseAndApplicationRestart() {
        let rule = AppRule(name: "Chrome", volume: 0.5)
        #expect(decide(chrome, rule, enabled: false) == .idle(.paused))
        var stopped = chrome; stopped.processIDs = []
        #expect(decide(stopped, rule) == .idle(.waiting))
        var restarted = chrome; restarted.processIDs = [100, 200]
        #expect(decide(restarted, rule) == .route(RoutePlan(processIDs: [100, 200], device: monitor, sourceFingerprint: "source")))
    }
    @Test func nestedHelperResolvesToChromeWithoutPrefixGuessing() {
        let url = URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Helper")
        #expect(ApplicationIdentity.outerApplicationURL(url)?.path == "/Applications/Google Chrome.app")
        #expect(ApplicationIdentity.outerApplicationURL(URL(fileURLWithPath: "/usr/bin/afplay")) == nil)
    }
    @Test func safariXPCUsesResponsibleAppDespiteLaunchdParent() {
        let owner = ApplicationIdentity.owningPID(processPID: 400, responsiblePID: 100,
            applicationPIDs: [100, 200], parentOf: { _ in 1 })
        #expect(owner == 100)
    }
    @Test func webKitOwnedByAnotherAppIsNotAssignedToSafari() {
        // 100=Safari, 200=another WKWebView app, 400=that app's WebKit GPU helper.
        let owner = ApplicationIdentity.owningPID(processPID: 400, responsiblePID: 200,
            applicationPIDs: [100, 200], parentOf: { _ in 1 })
        #expect(owner == 200)
    }
    @Test func missingResponsibilityUsesAncestryAndRejectsCycles() {
        let parents: [Int32: Int32] = [400: 300, 300: 100]
        #expect(ApplicationIdentity.owningPID(processPID: 400, responsiblePID: 0,
            applicationPIDs: [100], parentOf: { parents[$0] ?? 1 }) == 100)
        #expect(ApplicationIdentity.owningPID(processPID: 400, responsiblePID: 999,
            applicationPIDs: [100], parentOf: { $0 == 400 ? 300 : 400 }) == nil)
        #expect(ApplicationIdentity.owningPID(processPID: 400, responsiblePID: 0,
            applicationPIDs: [100], parentOf: { _ in 1 }) == nil)
    }
}
