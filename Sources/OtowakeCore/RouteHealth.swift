import Foundation

// The permission prompt may block route creation for minutes. Only running IO
// participates in the health timeout; time spent asking for consent never does.
struct RouteHealth {
    private var startedAt: Date?
    private var lastCallbackAt: Date?
    private var observedCallbacks: UInt64 = 0

    mutating func didStart(at now: Date = Date()) {
        startedAt = now; lastCallbackAt = now; observedCallbacks = 0
    }

    mutating func hasFailed(playing: Bool, callbacks: UInt64, signals: UInt64, invalid: UInt64,
                            now: Date = Date()) -> Bool {
        guard let startedAt else { return false }
        if callbacks != observedCallbacks || !playing {
            observedCallbacks = callbacks; lastCallbackAt = now
        }
        guard now.timeIntervalSince(startedAt) > 12 else { return false }
        // A browser can keep its audio client running while paused or silent.
        // Silence is not evidence of denied permission and must not disable the route.
        return (invalid > 10 && invalid > callbacks / 2) ||
            (playing && callbacks > 0 && now.timeIntervalSince(lastCallbackAt ?? startedAt) > 8)
    }
}
