import Foundation
import Testing
@testable import MacotaurApp

// Swift 6 checks a main-actor closure's isolation when it runs, so a callback
// that Dispatch or Foundation runs off the main thread traps if it was formed
// as one. These tests run the live callback paths for real; the real start
// and stop on the GPU are in LiveTests.

/// Polls until `done` holds, letting the main queue run in between.
@MainActor private func wait(until done: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(10)
    while !done() {
        if Date() > deadline { return false }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return true
}

// Samples are read on Telemetry's queue and delivered on the main actor.
// This trapped on the first sample before the timer handler was @Sendable.
@MainActor @Test func telemetrySamplesOnItsOwnQueue() async {
    var samples = 0
    let t = Telemetry { _ in samples += 1 }
    t.setInterval(0.1)
    #expect(await wait { samples >= 2 })
    t.setInterval(nil)
}

// Thermal changes are posted on whatever thread noticed them; the monitor
// handles them on the main actor.
@MainActor @Test func systemMonitorHandlesChangesPostedOffMain() async {
    var changes = 0
    let m = SystemMonitor { changes += 1 }
    m.start()
    DispatchQueue.global().async {
        NotificationCenter.default.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        NotificationCenter.default.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
    }
    #expect(await wait { changes >= 2 })
    m.stop()
    // Stopped: later changes aren't delivered.
    let seen = changes
    NotificationCenter.default.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
    try? await Task.sleep(for: .milliseconds(100))
    #expect(changes == seen)
}

// Quitting waits for the Miner off the main thread, then replies on it.
@MainActor @Test func prepareToQuitRepliesOnTheMainActor() async {
    let env = AppEnvironment(isDemo: false, store: MemoryStore(), historyURL: nil, statsURL: nil, activityLogURL: nil,
                             networking: false, systemMonitors: false, telemetry: false, canMine: false, keepAwake: false)
    let m = MiningModel(environment: env, hardware: DemoData.hardware(.air))
    var replied = false
    m.prepareToQuit { replied = true }
    #expect(await wait { replied })
}
