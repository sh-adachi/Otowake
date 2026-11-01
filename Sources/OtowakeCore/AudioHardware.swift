import AppKit
import AudioRealtime
import CoreAudio

public struct HardwareError: LocalizedError, Sendable {
    public let operation: String
    public let status: OSStatus
    public init(_ operation: String, _ status: OSStatus) { self.operation = operation; self.status = status }
    public var errorDescription: String? {
        let code = UInt32(bitPattern: status)
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xff) }
        let fourCC = bytes.allSatisfy { (32...126).contains($0) } ? " / \(String(bytes: bytes, encoding: .ascii) ?? "")" : ""
        return "\(operation)に失敗しました（\(status)\(fourCC)）。"
    }
}

enum HAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw HardwareError(operation, status) }
    }
    static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         _ initial: T, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> T {
        var a = address(selector, scope), result = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &result) {
            AudioObjectGetPropertyData(object, &a, 0, nil, &size, $0)
        }
        try check(status, "音声プロパティの取得")
        return result
    }
    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var a = address(selector), value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &a, 0, nil, &size, $0)
        }
        try check(status, "音声デバイス名の取得")
        return value as String
    }
    static func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> [AudioObjectID] {
        var a = address(selector, scope), size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size), "音声一覧の取得")
        guard size > 0 else { return [] }
        var result = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = result.withUnsafeMutableBytes { AudioObjectGetPropertyData(object, &a, 0, nil, &size, $0.baseAddress!) }
        try check(status, "音声一覧の読み込み")
        return Array(result.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }
    static func set<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       _ value: T, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws {
        var a = address(selector, scope), copy = value
        let status = withUnsafePointer(to: &copy) { AudioObjectSetPropertyData(object, &a, 0, nil, UInt32(MemoryLayout<T>.size), $0) }
        try check(status, "音声プロパティの設定")
    }
    static func channelCount(_ device: AudioObjectID, scope: AudioObjectPropertyScope) throws -> Int {
        var a = address(kAudioDevicePropertyStreamConfiguration, scope), size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(device, &a, 0, nil, &size), "チャンネル数の取得")
        guard size >= MemoryLayout<AudioBufferList>.size else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        try check(AudioObjectGetPropertyData(device, &a, 0, nil, &size, raw), "チャンネル構成の取得")
        return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
    }
    static func devices() throws -> [OutputDevice] {
        try objects(system, kAudioHardwarePropertyDevices).compactMap { id in
            // Aggregate devices made by this app must not feed back into the output chooser.
            guard let uid = try? string(id, kAudioDevicePropertyDeviceUID), !uid.hasPrefix("jp.otowake.route."),
                  (try? value(id, kAudioDevicePropertyDeviceIsAlive, UInt32(0))) == 1,
                  let channels = try? channelCount(id, scope: kAudioDevicePropertyScopeOutput), channels > 0 else { return nil }
            return OutputDevice(id: id, uid: uid, name: (try? string(id, kAudioObjectPropertyName)) ?? uid,
                                channels: channels, sampleRate: (try? value(id, kAudioDevicePropertyNominalSampleRate, Float64(0))) ?? 0,
                                transport: (try? value(id, kAudioDevicePropertyTransportType, UInt32(0))) ?? 0)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

public enum ApplicationIdentity {
    public static func owningPID(processPID: Int32, responsiblePID: Int32,
                                 applicationPIDs: Set<Int32>, parentOf: (Int32) -> Int32) -> Int32? {
        if applicationPIDs.contains(processPID) { return processPID }
        if responsiblePID > 1 && applicationPIDs.contains(responsiblePID) { return responsiblePID }
        var current = processPID
        var visited: Set<Int32> = [current]
        for _ in 0..<12 {
            let parent = parentOf(current)
            guard parent > 1, visited.insert(parent).inserted else { return nil }
            if applicationPIDs.contains(parent) { return parent }
            current = parent
        }
        return nil
    }
    // Helpers nested in Chrome.app/Contents/... belong to the OUTERMOST app bundle.
    public static func outerApplicationURL(_ executable: URL) -> URL? {
        var current = executable.standardizedFileURL
        var result: URL?
        while current.path != "/" {
            if current.pathExtension.lowercased() == "app" { result = current }
            current.deleteLastPathComponent()
        }
        return result
    }
}

enum ProcessDiscovery {
    static func applications() throws -> [AudioApplication] {
        let running = NSWorkspace.shared.runningApplications
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let regularApps = running.filter { $0.activationPolicy == .regular }
        let appPIDs = Set(regularApps.map(\.processIdentifier))
        var groups: [String: AudioApplication] = [:]
        for app in running where app.activationPolicy == .regular && app.processIdentifier != ownPID {
            guard let id = app.bundleIdentifier else { continue }
            groups[id] = AudioApplication(id: id, name: app.localizedName ?? id,
                                          bundlePath: app.bundleURL?.path, processIDs: [], isPlaying: false)
        }
        for object in try HAL.objects(HAL.system, kAudioHardwarePropertyProcessObjectList) {
            guard let pid = try? HAL.value(object, kAudioProcessPropertyPID, pid_t(0)), pid != ownPID else { continue }
            let processApp = NSRunningApplication(processIdentifier: pid)
            var ownerURL = processApp?.executableURL.flatMap(ApplicationIdentity.outerApplicationURL)
            var owner = ownerURL.flatMap { Bundle(url: $0) }?.bundleIdentifier
            // launchd-spawned XPC helpers (Safari/WebKit) need responsibility attribution.
            // Use only verified, running app PIDs; never assign all WebKit services to Safari.
            if owner == nil {
                let owningPID = ApplicationIdentity.owningPID(processPID: pid, responsiblePID: OWResponsiblePID(pid),
                    applicationPIDs: appPIDs, parentOf: { OWParentPID($0) })
                if let app = regularApps.first(where: { $0.processIdentifier == owningPID }) {
                    owner = app.bundleIdentifier; ownerURL = app.bundleURL
                }
            }
            let bundleID = owner ?? (try? HAL.string(object, kAudioProcessPropertyBundleID))
            guard let id = bundleID, !id.isEmpty, id != Bundle.main.bundleIdentifier else { continue }
            let isPlaying = (try? HAL.value(object, kAudioProcessPropertyIsRunningOutput, UInt32(0))) == 1
            // Keep background OS daemons out of the app picker. A playing accessory app is still useful.
            guard groups[id] != nil || (ownerURL != nil && isPlaying) else { continue }
            let name = ownerURL.flatMap { Bundle(url: $0) }.flatMap {
                ($0.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? ($0.object(forInfoDictionaryKey: "CFBundleName") as? String)
            } ?? processApp?.localizedName ?? id
            var group = groups[id] ?? AudioApplication(id: id, name: name, bundlePath: ownerURL?.path, processIDs: [], isPlaying: false)
            group.processIDs.append(object)
            group.isPlaying = group.isPlaying || isPlaying
            group.processIDs.sort()
            groups[id] = group
        }
        return groups.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

public enum AudioDiagnostics {
    public static func inventory() throws -> String {
        let devices = try HAL.devices()
        let apps = try ProcessDiscovery.applications()
        return (["Output devices: \(devices.count)"] + devices.map { "  \($0.name) | \($0.uid) | \($0.channels)ch | \($0.sampleRate)Hz" }
                + ["Audio applications: \(apps.count)"] + apps.filter { !$0.processIDs.isEmpty }.map { "  \($0.name) | \($0.id) | objects=\($0.processIDs) | playing=\($0.isPlaying)" }).joined(separator: "\n")
    }
}
