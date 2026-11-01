import AppKit
import Combine
import OtowakeCore

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var preferences = Preferences()
    @Published private(set) var snapshot = AudioSnapshot()
    @Published var settingsError: String?
    @Published var search = ""
    private let file = SettingsFile()
    private var canSave = true
    private var saveTask: Task<Void, Never>?
    lazy var audio = AudioController { [weak self] snapshot in
        Task { @MainActor [weak self] in self?.snapshot = snapshot }
    }
    init() {
        do { preferences = try file.load() }
        catch { settingsError = "設定を読み込めません。既存のファイルを保護するため保存を停止しています。\n\(error.localizedDescription)"; canSave = false }
    }
    func start() { audio.start(preferences: preferences) }
    func stop() { saveTask?.cancel(); save(); audio.shutdown() }
    var visibleApps: [AudioApplication] {
        snapshot.applications.filter {
            (preferences.showAllApps || $0.isPlaying || preferences.rules[$0.id] != nil) &&
            (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search))
        }.sorted {
            if $0.isPlaying != $1.isPlaying { return $0.isPlaying }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    var activeCount: Int { snapshot.statuses.values.filter { if case .active = $0 { true } else { false } }.count }
    func rule(for app: AudioApplication) -> AppRule { preferences.rules[app.id] ?? AppRule(name: app.name) }
    func setEnabled(_ value: Bool) { preferences.enabled = value; changed() }
    func setShowAll(_ value: Bool) { preferences.showAllApps = value; changed() }
    func setVolume(_ volume: Double, app: AudioApplication) { edit(app) { $0.volume = min(1, max(0, volume)) } }
    func toggleMute(_ app: AudioApplication) { edit(app) { $0.muted.toggle() } }
    func setDevice(_ uid: String, app: AudioApplication) {
        edit(app) { rule in
            rule.deviceUID = uid.isEmpty ? nil : uid
            rule.deviceName = snapshot.devices.first { $0.uid == uid }?.name
        }
    }
    func reset(_ app: AudioApplication) { preferences.rules.removeValue(forKey: app.id); changed() }
    private func edit(_ app: AudioApplication, _ change: (inout AppRule) -> Void) {
        var rule = rule(for: app); rule.name = app.name; change(&rule)
        preferences.rules[app.id] = rule; changed()
    }
    private func changed() {
        audio.update(preferences)
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            self?.save()
        }
    }
    private func save() {
        guard canSave else { return }
        do { try file.save(preferences); settingsError = nil }
        catch { settingsError = "設定を保存できません：\(error.localizedDescription)" }
    }
    func openSettingsFolder() {
        let directory = file.url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }
    func openPrivacy() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
    }
}
