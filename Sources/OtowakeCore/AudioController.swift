import CoreAudio
import Foundation

// Mutable HAL state is confined to queue. No UI or Swift objects enter the RT callback.
public final class AudioController: @unchecked Sendable {
    private let queue = DispatchQueue(label: "jp.otowake.audio-control", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var preferences = Preferences()
    private var routes: [String: ProcessRoute] = [:]
    private var failures: [String: (Date, RoutePlan, String)] = [:]
    private var silentPlans: [String: RoutePlan] = [:]
    private var sourceFingerprint = ""
    private var generation: UInt64 = 0
    private var suspended = false
    private var pendingRefresh: DispatchWorkItem?
    private var lastStatuses: [String: RouteStatus] = [:]
    private let receive: @Sendable (AudioSnapshot) -> Void
    public init(receive: @escaping @Sendable (AudioSnapshot) -> Void) { self.receive = receive }
    public func start(preferences: Preferences) {
        queue.async { [self] in
            self.preferences = preferences
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(1200), leeway: .milliseconds(200))
            timer.setEventHandler { [weak self] in self?.refresh() }
            self.timer = timer; timer.resume()
        }
    }
    public func update(_ preferences: Preferences) {
        queue.async { [self] in
            self.preferences = preferences
            for (id, route) in routes { route.setGain(preferences.rules[id]?.gain ?? 1) }
            pendingRefresh?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.refresh() }
            pendingRefresh = work
            queue.asyncAfter(deadline: .now() + .milliseconds(100), execute: work)
        }
    }
    public func retry() {
        queue.async { [self] in failures.removeAll(); silentPlans.removeAll(); generation &+= 1; refresh() }
    }
    public func suspend(_ value: Bool) {
        queue.async { [self] in suspended = value; if value { stopRoutes() } else { refresh() } }
    }
    public func shutdown() {
        queue.sync { timer?.cancel(); timer = nil; pendingRefresh?.cancel(); pendingRefresh = nil; stopRoutes() }
    }
    private func stopRoutes() { for route in routes.values { route.stop() }; routes.removeAll() }
    private func refresh() {
        guard !suspended else { return }
        var snapshot = AudioSnapshot()
        do {
            snapshot.devices = try HAL.devices()
            snapshot.applications = try ProcessDiscovery.applications()
            let defaultID = try HAL.value(HAL.system, kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(0))
            snapshot.defaultUID = snapshot.devices.first { $0.id == defaultID }?.uid
            // A source device/rate change invalidates existing global mixdown taps.
            let fingerprint = "\(generation)|\(defaultID)|" + snapshot.devices.map { "\($0.id):\($0.sampleRate):\($0.channels)" }.joined(separator: ",")
            if fingerprint != sourceFingerprint { failures.removeAll(); silentPlans.removeAll(); sourceFingerprint = fingerprint }
            var apps = Dictionary(uniqueKeysWithValues: snapshot.applications.map { ($0.id, $0) })
            for (id, rule) in preferences.rules where apps[id] == nil {
                apps[id] = AudioApplication(id: id, name: rule.name, processIDs: [], isPlaying: false)
            }
            snapshot.applications = apps.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            snapshot.statuses = lastStatuses.filter { apps[$0.key] != nil }
            for id in Array(routes.keys) where apps[id] == nil { routes.removeValue(forKey: id)?.stop() }
            for (id, app) in apps {
                let rule = preferences.rules[id]
                let decision = RoutePlanner.decide(app: app, rule: rule, enabled: preferences.enabled,
                    devices: snapshot.devices, defaultUID: snapshot.defaultUID, sourceFingerprint: fingerprint)
                switch decision {
                case .idle(let status):
                    routes.removeValue(forKey: id)?.stop()
                    snapshot.statuses[id] = status
                    failures.removeValue(forKey: id); silentPlans.removeValue(forKey: id)
                case .route(let plan):
                    guard let rule else { continue }
                    if silentPlans[id] == plan {
                        snapshot.statuses[id] = .noSignal; continue
                    }
                    silentPlans.removeValue(forKey: id)
                    if routes[id]?.plan != plan {
                        if let (until, failedPlan, message) = failures[id], failedPlan == plan, until > Date() {
                            snapshot.statuses[id] = .failed(message); continue
                        }
                        do {
                            // Core Audio may wait for the OS permission prompt inside IOProc creation.
                            // Publish progress before entering it so the UI never shows stale "paused".
                            snapshot.statuses[id] = .connecting(plan.device.name)
                            receive(snapshot)
                            // Keep the old tap consumed until its replacement is ready. In particular,
                            // changing devices while muted must not briefly restore native playback.
                            let replacement = try ProcessRoute(plan: plan, rule: rule)
                            let previous = routes.updateValue(replacement, forKey: id)
                            previous?.stop()
                            failures.removeValue(forKey: id)
                        } catch {
                            routes.removeValue(forKey: id)?.stop()
                            let message = error.localizedDescription
                            failures[id] = (Date().addingTimeInterval(15), plan, message)
                            snapshot.statuses[id] = .failed(message); continue
                        }
                    }
                    guard let route = routes[id] else { continue }
                    route.setGain(rule.gain)
                    // Malformed buffers or stalled running IO fail open. Valid silence waits for audio.
                    if route.hasFailed(whilePlaying: app.isPlaying) {
                        routes.removeValue(forKey: id)?.stop()
                        silentPlans[id] = plan
                        snapshot.statuses[id] = .noSignal
                    } else {
                        snapshot.statuses[id] = app.isPlaying && route.signalCallbacks > 0 ? .active(plan.device.name) : .waiting
                        snapshot.peaks[id] = route.peak
                    }
                }
            }
        } catch {
            // Losing HAL inventory must never leave an invisible muted tap alive.
            stopRoutes(); snapshot.error = error.localizedDescription
        }
        lastStatuses = snapshot.statuses
        receive(snapshot)
    }
}
