import Foundation

public struct OutputDevice: Identifiable, Equatable, Sendable {
    public var id: UInt32
    public var uid: String
    public var name: String
    public var channels: Int
    public var sampleRate: Double
    public var transport: UInt32
    public init(id: UInt32, uid: String, name: String, channels: Int, sampleRate: Double, transport: UInt32 = 0) {
        self.id = id; self.uid = uid; self.name = name; self.channels = channels
        self.sampleRate = sampleRate; self.transport = transport
    }
}

public struct AudioApplication: Identifiable, Equatable, Sendable {
    public var id: String // Bundle ID, stable across launches.
    public var name: String
    public var bundlePath: String?
    public var processIDs: [UInt32]
    public var isPlaying: Bool
    public init(id: String, name: String, bundlePath: String? = nil, processIDs: [UInt32], isPlaying: Bool) {
        self.id = id; self.name = name; self.bundlePath = bundlePath
        self.processIDs = processIDs.sorted(); self.isPlaying = isPlaying
    }
}

public struct AppRule: Codable, Equatable, Sendable {
    public var name: String
    public var deviceUID: String?
    public var deviceName: String?
    public var volume: Double
    public var muted: Bool
    public init(name: String, deviceUID: String? = nil, deviceName: String? = nil, volume: Double = 1, muted: Bool = false) {
        self.name = name; self.deviceUID = deviceUID; self.deviceName = deviceName
        self.volume = volume.isFinite ? min(1, max(0, volume)) : 1; self.muted = muted
    }
    public var needsProcessing: Bool { deviceUID != nil || volume < 1 || muted }
    public var gain: Float { muted ? 0 : Float(volume) }
}

public struct Preferences: Codable, Equatable, Sendable {
    public var version = 1
    public var enabled = false
    public var showAllApps = false
    public var rules: [String: AppRule] = [:]
    public init() {}
    public func validated() throws -> Preferences {
        guard version == 1 else { throw SettingsError.unsupportedVersion(version) }
        guard rules.allSatisfy({ !$0.key.isEmpty && $0.value.volume.isFinite && (0...1).contains($0.value.volume) }) else {
            throw SettingsError.invalidValues
        }
        return self
    }
}

public enum SettingsError: LocalizedError {
    case unsupportedVersion(Int), invalidValues
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): "設定ファイルの形式（バージョン\(version)）に対応していません。"
        case .invalidValues: "設定ファイルに無効な音量またはアプリIDが含まれています。"
        }
    }
}

public struct SettingsFile: Sendable {
    public let url: URL
    public init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Otowake/settings.json")
    }
    public func load() throws -> Preferences {
        guard FileManager.default.fileExists(atPath: url.path) else { return Preferences() }
        return try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: url)).validated()
    }
    public func save(_ preferences: Preferences) throws {
        _ = try preferences.validated()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(preferences).write(to: url, options: .atomic)
    }
}

public enum RouteStatus: Equatable, Sendable {
    case native, paused, connecting(String), waiting, active(String), missingDevice(String), failed(String), noSignal
    public var text: String {
        switch self {
        case .native: "標準の出力"
        case .paused: "制御を一時停止中"
        case .connecting(let name): "\(name) に接続中。macOSの音声取得の許可を確認してください。"
        case .waiting: "音声の開始を待機中"
        case .active(let name): "\(name) に出力中"
        case .missingDevice(let name): "\(name) が未接続・標準出力に復帰"
        case .failed(let reason): reason
        case .noSignal: "音声を取得できません。録音の許可を確認してください。"
        }
    }
    public var isWarning: Bool {
        switch self { case .failed, .missingDevice, .noSignal: true; default: false }
    }
}

public struct RoutePlan: Equatable, Sendable {
    public var processIDs: [UInt32]
    public var device: OutputDevice
    // Global mixdown taps follow source output format changes, including the default device.
    public var sourceFingerprint: String
    public init(processIDs: [UInt32], device: OutputDevice, sourceFingerprint: String) {
        self.processIDs = processIDs.sorted(); self.device = device; self.sourceFingerprint = sourceFingerprint
    }
}

public enum RouteDecision: Equatable, Sendable {
    case idle(RouteStatus)
    case route(RoutePlan)
}

public enum RoutePlanner {
    public static func decide(app: AudioApplication, rule: AppRule?, enabled: Bool,
                              devices: [OutputDevice], defaultUID: String?, sourceFingerprint: String) -> RouteDecision {
        guard let rule, rule.needsProcessing else { return .idle(.native) }
        guard enabled else { return .idle(.paused) }
        guard !app.processIDs.isEmpty else { return .idle(.waiting) }
        let uid = rule.deviceUID ?? defaultUID
        guard let device = devices.first(where: { $0.uid == uid }) else {
            return .idle(.missingDevice(rule.deviceName ?? "出力デバイス"))
        }
        return .route(RoutePlan(processIDs: app.processIDs, device: device, sourceFingerprint: sourceFingerprint))
    }
}

public struct AudioSnapshot: Sendable {
    public var devices: [OutputDevice] = []
    public var applications: [AudioApplication] = []
    public var defaultUID: String?
    public var statuses: [String: RouteStatus] = [:]
    public var peaks: [String: Float] = [:]
    public var error: String?
    public init() {}
}
