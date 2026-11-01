import Foundation
import Testing
@testable import OtowakeCore

struct RouteHealthTests {
    let origin = Date(timeIntervalSince1970: 1000)

    @Test func permissionWaitDoesNotConsumeStartupGracePeriod() {
        var health = RouteHealth()
        var failed = health.hasFailed(playing: true, callbacks: 0, signals: 0, invalid: 0, now: origin.addingTimeInterval(180))
        #expect(!failed)
        health.didStart(at: origin.addingTimeInterval(180))
        failed = health.hasFailed(playing: true, callbacks: 0, signals: 0, invalid: 0, now: origin.addingTimeInterval(180.1))
        #expect(!failed)
        failed = health.hasFailed(playing: true, callbacks: 10, signals: 0, invalid: 0, now: origin.addingTimeInterval(185))
        #expect(!failed)
        failed = health.hasFailed(playing: true, callbacks: 100, signals: 80, invalid: 0, now: origin.addingTimeInterval(195))
        #expect(!failed)
    }
    @Test func validSilenceWaitsButBrokenBuffersFailAfterGrace() {
        var silent = RouteHealth(); silent.didStart(at: origin)
        let silentFailed = silent.hasFailed(playing: true, callbacks: 100, signals: 0, invalid: 0, now: origin.addingTimeInterval(13))
        #expect(!silentFailed)
        var awaitingAudio = RouteHealth(); awaitingAudio.didStart(at: origin)
        let noCallbacksYet = awaitingAudio.hasFailed(playing: true, callbacks: 0, signals: 0, invalid: 0, now: origin.addingTimeInterval(60))
        #expect(!noCallbacksYet)
        var broken = RouteHealth(); broken.didStart(at: origin)
        let brokenFailed = broken.hasFailed(playing: true, callbacks: 100, signals: 20, invalid: 70, now: origin.addingTimeInterval(13))
        #expect(brokenFailed)
    }
    @Test func pausedSourceAndInitialTransientBuffersDoNotFail() {
        var health = RouteHealth(); health.didStart(at: origin)
        var failed = health.hasFailed(playing: false, callbacks: 0, signals: 0, invalid: 0, now: origin.addingTimeInterval(60))
        #expect(!failed)
        failed = health.hasFailed(playing: true, callbacks: 100, signals: 80, invalid: 11, now: origin.addingTimeInterval(61))
        #expect(!failed)
        failed = health.hasFailed(playing: true, callbacks: 100, signals: 80, invalid: 11, now: origin.addingTimeInterval(70))
        #expect(failed)
    }
}
