import Foundation
import Testing
@testable import MacotaurApp

// MARK: Stored settings

@Test func uiStateIgnoresRemovedFields() throws {
    let old = #"{"chartRange":"day","detailsExpanded":true,"activityExpanded":true,"activityFilter":"problems"}"#
    let s = try JSONDecoder().decode(UIState.self, from: Data(old.utf8))
    #expect(s.activityExpanded)
}

// MARK: Live-like model (memory store, nothing real)

@MainActor private func liveModel(store: MemoryStore) -> MiningModel {
    let env = AppEnvironment(isDemo: false, store: store, historyURL: nil, statsURL: nil,
                             activityLogURL: nil, networking: false, systemMonitors: false,
                             telemetry: false, canMine: false, keepAwake: false)
    return MiningModel(environment: env, hardware: DemoData.hardware(.air))
}

@MainActor private func liveModel(seed: [String: Any] = ["wallet": "12TestWallet"]) -> MiningModel {
    liveModel(store: MemoryStore(seed: seed))
}

@MainActor @Test func newInstallDefaults() {
    let store = MemoryStore()
    let fresh = liveModel(store: store)
    #expect(fresh.worker == "mac" && fresh.intensity == 100 && fresh.duty == 1)
    #expect(fresh.status == .stopped && fresh.activity.isEmpty)
    #expect(store.string(forKey: "intensity") == nil)  // a default isn't a choice to store
}

// Settings an older version stored (the pausing rules among them) are
// neither read nor rewritten.
@MainActor @Test func oldSettingsAreLeftAlone() {
    let junk = Data(#"{"showSpeedInMenuBar":true}"#.utf8)
    let pausing = Data(#"{"battery":"pause","ups":true,"memory":true}"#.utf8)
    let store = MemoryStore(seed: ["wallet": "12TestWallet", "powerMode": "turbo", "general": junk, "alerts": junk,
                                   "pausing": pausing])
    let m = liveModel(store: store)
    #expect(m.intensity == 100)                        // an unknown mode falls back to the default
    m.intensity = 50
    m.ui.activityExpanded = true
    #expect(store.data(forKey: "general") == junk && store.data(forKey: "alerts") == junk)
    #expect(store.data(forKey: "pausing") == pausing && !PreferenceKey.json.contains("pausing"))
    #expect(m.activity.isEmpty)
    #expect(store.string(forKey: "powerMode") == "turbo" && store.string(forKey: "intensity") == "50")
}

// MARK: Intensity

@MainActor @Test func intensityClampsAndRoundsToFives() {
    for (asked, got) in [(100, 100), (10, 10), (75, 75), (73, 75), (72, 70), (77, 75), (78, 80), (12, 10), (13, 15),
                         (9, 10), (0, 10), (-40, 10), (101, 100), (250, 100)] {
        #expect(MiningModel.intensity(nearest: asked) == got, "\(asked)")
    }
    let m = liveModel()
    m.intensity = 73
    #expect(m.intensity == 75 && m.duty == 0.75)
    m.intensity = 3
    #expect(m.intensity == 10 && m.duty == 0.1)
    m.intensity = 400
    #expect(m.intensity == 100 && m.duty == 1)
    // Every stop on the slider.
    for step in stride(from: 10, through: 100, by: 5) {
        m.intensity = step
        #expect(m.intensity == step && abs(m.duty - Double(step) / 100) < 1e-12)
    }
}

@MainActor @Test func intensityPersists() {
    let store = MemoryStore(seed: ["wallet": "12TestWallet"])
    let m = liveModel(store: store)
    m.intensity = 60
    #expect(store.string(forKey: "intensity") == "60")
    m.intensity = 58                                    // rounds to the same stop: stored as that
    #expect(store.string(forKey: "intensity") == "60")
    #expect(liveModel(store: store).intensity == 60)
    #expect(store.string(forKey: "powerMode") == nil)
    // A stored value that isn't a stop on the slider is read as the nearest one.
    for (stored, got) in [("73", 75), ("7", 10), ("1000", 100), ("abc", 100), ("", 100)] {
        #expect(liveModel(seed: ["intensity": stored]).intensity == got, "\(stored)")
    }
}

// An older version's power mode is carried over once; its key stays as it was.
@MainActor @Test func intensityComesFromTheOldPowerModeOnce() {
    for (mode, percent) in [("full", 100), ("auto", 100), ("balanced", 75), ("cool", 50)] {
        let store = MemoryStore(seed: ["wallet": "12TestWallet", "powerMode": mode])
        let m = liveModel(store: store)
        #expect(m.intensity == percent && m.duty == Double(percent) / 100, "\(mode)")
        #expect(store.string(forKey: "intensity") == "\(percent)" && store.string(forKey: "powerMode") == mode, "\(mode)")
        // From here on only the intensity counts.
        m.intensity = 35
        #expect(store.string(forKey: "powerMode") == mode)
        store.set("full", forKey: "powerMode")
        #expect(liveModel(store: store).intensity == 35, "\(mode)")
    }
    // A stored intensity wins over an old mode.
    let both = MemoryStore(seed: ["powerMode": "cool", "intensity": "90"])
    #expect(liveModel(store: both).intensity == 90 && both.string(forKey: "intensity") == "90")
}

// The slider works during a session, and says nothing in the log. (The real
// Miner's duty is measured in LiveTests.)
@MainActor @Test func intensityChangesDuringASession() async throws {
    let store = MemoryStore(seed: ["wallet": "12TestWallet"])
    let m = liveModel(store: store)
    m.start()
    let deadline = Date().addingTimeInterval(10)
    while m.status != .mining {
        try #require(Date() < deadline, "never got to mining")
        try await Task.sleep(for: .milliseconds(20))
    }
    let lines = m.activity
    for step in [95, 90, 85, 40] { m.intensity = step }
    #expect(m.intensity == 40 && m.duty == 0.4 && m.status == .mining)
    #expect(store.string(forKey: "intensity") == "40")
    #expect(m.activity == lines)
    m.stop()
}

// One bad response (paid 0) must not become the baseline for a false payout.
@MainActor @Test func payoutBaselineIgnoresALowerTotal() {
    let m = liveModel()
    func snap(_ paid: Double) -> KryptexAPI.Snapshot { KryptexAPI.Snapshot(payouts: .init(paid: paid)) }
    m.detectPayout(snap(400))
    m.detectPayout(snap(0))
    m.detectPayout(snap(400))
    #expect(m.lastPayout == nil)
    m.detectPayout(snap(601.5))
    #expect(m.lastPayout?.amount == 201.5)
    #expect(m.activity.last?.kind == .payout)
}

// A submit whose answer went with the connection mustn't shift later results.
@MainActor @Test func shareResultsStayMatchedAfterReconnecting() {
    let m = liveModel()
    let t = Date()
    m.apply(.share(difficulty: 100, target: 48, submitted: true), at: t, replay: false)
    m.apply(.pool(.disconnected("connection reset")), at: t.addingTimeInterval(1), replay: false)
    m.apply(.pool(.loggedIn(session: "s")), at: t.addingTimeInterval(7), replay: false)
    m.apply(.share(difficulty: 200, target: 48, submitted: true), at: t.addingTimeInterval(20), replay: false)
    m.apply(.pool(.shareResult(accepted: true, error: nil)), at: t.addingTimeInterval(21), replay: false)
    #expect(m.activity.last?.text == "Share accepted · difficulty 200 (needs 48)")
    #expect(m.activity.contains { $0.text == "Found a share · difficulty 100 (needs 48)" })
    #expect(m.today.accepted == 1 && m.sharesFigure.text == "1 share")
}

// MARK: Demo

@MainActor @Test func demoStatusLineFigures() throws {
    let m = MiningModel(demo: DemoScenario(profile: .pro, state: .mining))
    let speed = try #require(m.speed)
    #expect(m.statusWord == "Mining" && m.speedText == Format.rate(speed))
    #expect(m.power.gpuWatts != nil && m.power.gpuMHz == 1296 && m.power.joulesPerGraph != nil)
    #expect(m.sharesFigure.text.hasSuffix(" shares") && m.sharesFigure.help.contains("expected"))
    let perDay = try #require(m.perDayFigure)
    #expect(perDay.text.hasPrefix("≈ ") && perDay.text.hasSuffix(" XTM/day") && perDay.help.contains("$"))
    let payout = try #require(m.payoutFigure)
    #expect(payout.text.hasPrefix("≈ ") && payout.help.contains("at your recent pace"))
    #expect(m.intensity == 100)

    // Another pool: an estimate from network figures, and no payout.
    let other = MiningModel(demo: DemoScenario(profile: .pro, state: .luckyPool))
    #expect(other.perDayFigure?.help.contains("before your pool's fee") == true && other.payoutFigure == nil)

    // Stopped: no readings and no estimate, but the balance still counts toward the payout.
    let stopped = MiningModel(demo: DemoScenario(profile: .pro, state: .stopped))
    #expect(stopped.power.gpuWatts == nil && stopped.perDayFigure == nil)
    #expect(stopped.payoutFigure == Figure(text: "63%", help: "to 200 XTM"))
    #expect(stopped.speedCaption.hasPrefix("Last session averaged "))

    // A Mac that reports no GPU power or clock.
    let m1 = MiningModel(demo: DemoScenario(profile: .m1, state: .mining))
    #expect(m1.power.gpuWatts == nil && m1.power.gpuMHz == nil && m1.power.joulesPerGraph == nil)

    let fresh = MiningModel(demo: DemoScenario(profile: .pro, state: .firstRun))
    #expect(!fresh.hasWallet && !fresh.canStart && fresh.statusWord == "Not set up" && fresh.payoutFigure == nil)
}
