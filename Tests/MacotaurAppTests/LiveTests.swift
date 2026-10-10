import Foundation
import MacotaurCore
import Metal
import Testing
@testable import MacotaurApp

// The real (non-demo) lifecycle in-process: MiningModel drives a real
// MetalSolver and Miner against MockPool, with the thermal monitor and
// telemetry running. Settings stay in memory, files go to a temp directory, and nothing
// leaves localhost.

private struct TimedOut: Error {}

/// One live model with its own pool and temp directory.
@MainActor private final class Rig {
    /// Never freed, as in the app, where the model lives until the process exits.
    private static var kept: [MiningModel] = []
    static func keep(_ m: MiningModel) { kept.append(m) }

    let pool: MockPool
    let dir: URL
    let store: MemoryStore
    let model: MiningModel
    private let device = MTLCreateSystemDefaultDevice()
    /// The most GPU memory this process had allocated at any check.
    private(set) var peakBytes = 0
    /// The model's state the first time more than one solver's worth was allocated.
    private(set) var overlap: String?

    init() throws {
        pool = try MockPool()
        dir = FileManager.default.temporaryDirectory.appending(path: "macotaur-live-\(UUID().uuidString)")
        store = MemoryStore(seed: [
            PreferenceKey.preset: MiningModel.PoolPreset.custom.rawValue,
            PreferenceKey.customHost: "127.0.0.1",
            PreferenceKey.customPort: "\(pool.port)",
            PreferenceKey.wallet: "12LiveTestWallet",
            PreferenceKey.worker: "rig",
        ])
        model = MiningModel(environment: Self.environment(store, dir), hardware: .detect())
        Self.keep(model)
    }

    /// The live environment, except for the store and the files' folder.
    var environment: AppEnvironment { Self.environment(store, dir) }

    private static func environment(_ store: PreferenceStore, _ dir: URL) -> AppEnvironment {
        AppEnvironment(isDemo: false, store: store, historyURL: dir.appending(path: "history-v1.json"),
                       statsURL: dir.appending(path: "stats-v1.json"), activityLogURL: dir.appending(path: "activity.log"),
                       networking: false, systemMonitors: true, telemetry: true, canMine: true, keepAwake: true)
    }

    var solverBytes: Int { Int(model.hardware.solverBytes) }
    var gpuBytes: Int { device?.currentAllocatedSize ?? 0 }

    /// Polls every 50 ms; the main run loop (ticks, monitors, Miner events) runs in between.
    func wait(_ what: String, timeout: TimeInterval, sourceLocation: SourceLocation = #_sourceLocation,
              until done: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            peakBytes = max(peakBytes, gpuBytes)
            if overlap == nil, gpuBytes > solverBytes * 3 / 2 { overlap = state }
            if done() { return }
            guard Date() < deadline else {
                Issue.record("Timed out after \(Int(timeout)) s waiting for \(what). \(state)", sourceLocation: sourceLocation)
                throw TimedOut()
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Lets the app run for a while.
    func run(for seconds: TimeInterval) async throws {
        let end = Date().addingTimeInterval(seconds)
        try await wait("time to pass", timeout: seconds + 5) { Date() >= end }
    }

    /// Over a window: graphs per second, counted by the pool (with the real
    /// block as the job every graph yields a share), and the fraction of time
    /// the GPU was busy (nil without GPU residency counters).
    func measure(over seconds: TimeInterval) async throws -> (rate: Double, busy: Double?) {
        let meter = PowerMonitor()
        _ = meter.sample()
        let start = Date(), before = pool.submissions.count
        try await run(for: seconds)
        let rate = Double(pool.submissions.count - before) / Date().timeIntervalSince(start)
        return (rate, meter.sample().gpuBusy)
    }

    func count(_ kind: ActivityKind) -> Int { model.activity.filter { $0.kind == kind }.count }

    var state: String {
        "Status \(model.status), intent \(model.intent), GPU \(model.gpuMemory), "
            + "\(gpuBytes >> 20) MB allocated. Recent activity:\n"
            + model.activity.suffix(14).map { "  \($0.text)" }.joined(separator: "\n")
    }

    /// Stops if needed and waits until the solver's memory is really back.
    func shutDown() async {
        model.stop()
        try? await wait("the final stop", timeout: 20) {
            (model.status == .stopped || model.isFailed) && model.gpuMemory == .released && gpuBytes < solverBytes / 4
        }
        pool.shutDown()
        try? FileManager.default.removeItem(at: dir)
    }
}

@MainActor private func withRig(_ body: (Rig) async throws -> Void) async throws {
    let rig = try Rig()
    do {
        try await body(rig)
    } catch is TimedOut {
        // Already recorded with the model's state.
    } catch {
        await rig.shutDown()
        throw error
    }
    await rig.shutDown()
}

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MACOTAUR_GPU_TESTS"] != nil),
       .timeLimit(.minutes(2)))
@MainActor struct LiveLifecycleTests {

    // Start, mine real shares, Stop: status, speed, history, telemetry, files and GPU memory.
    @Test func startMineAndStop() async throws {
        try await withRig { rig in
            let m = rig.model
            #expect(m.canStart && m.statusWord == "Ready")
            m.start()
            #expect(m.status == .preparingGPU && m.gpuMemory == .reserving(m.hardware.solverBytes))
            #expect(m.hasActiveSession && m.statusWord == "Preparing")
            try await rig.wait("mining", timeout: 30) { m.status == .mining }
            #expect(m.gpuMemory == .inUse(m.hardware.solverBytes))
            #expect(rig.gpuBytes > rig.solverBytes / 2)
            #expect(rig.pool.logins == ["12LiveTestWallet.rig"])
            #expect(rig.count(.gpuReady) == 1 && rig.count(.connected) == 1 && rig.count(.loggedIn) == 1)

            try await rig.wait("an accepted share", timeout: 20) { (m.session?.accepted ?? 0) >= 1 }
            #expect(m.activity.contains { $0.kind == .shareAccepted })
            #expect(m.today.accepted >= 1)
            #expect(rig.pool.submissions.allSatisfy { $0.valid })

            try await rig.wait("a measured speed", timeout: 20) { m.speed != nil }
            #expect(m.speedText != "–.––" && m.windowSubtitle.hasPrefix("Mining · "))
            let graphs = m.session?.graphs ?? 0, revision = m.historyRevision
            try await rig.wait("more graphs", timeout: 10) { (m.session?.graphs ?? 0) > graphs && m.historyRevision > revision }
            #expect(m.historyStore.meanSpeed(over: 900, now: Date()) != nil)
            #expect(m.historyStore.miningSeconds(over: 900, now: Date()) > 0)

            // Telemetry: sampled every 2 s while mining, for whatever this Mac reports.
            let caps = PowerMonitor().capabilities
            if !caps.intersection([.gpuEnergy, .gpuPMP]).isEmpty {
                try await rig.wait("a GPU power reading", timeout: 10) { m.power.gpuWatts != nil && m.power.joulesPerGraph != nil }
            }
            if caps.contains(.gpuClock) { try await rig.wait("a GPU clock reading", timeout: 10) { m.power.gpuMHz != nil } }

            // Past 30 s of mining the session's average is kept.
            try await rig.wait("30 s of mining", timeout: 40) { (m.session?.miningSeconds ?? 0) >= 30 }
            let accepted = m.session?.accepted ?? 0
            m.stop()
            #expect(m.status == .stopping && m.intent == .stopped && !m.canStart)
            try await rig.wait("stopped", timeout: 15) { m.status == .stopped }
            #expect(m.gpuMemory == .released)
            #expect(m.session == nil && m.speed == nil && m.power.gpuWatts == nil && m.power.gpuMHz == nil)
            #expect(m.lastSessionSpeed != nil && m.canStart)
            #expect(rig.count(.memoryReleased) == 1 && rig.count(.stopped) == 1)
            let released = try #require(m.activity.last { $0.kind == .memoryReleased })
            let stopped = try #require(m.activity.last { $0.kind == .stopped })
            #expect(stopped.time >= released.time, "Stopped is dated before Released")
            try await rig.wait("the solver's buffers freed", timeout: 10) { rig.gpuBytes < rig.solverBytes / 4 }
            #expect(rig.peakBytes < rig.solverBytes * 3 / 2)

            for name in ["history-v1.json", "stats-v1.json", "activity.log"] {
                #expect(FileManager.default.fileExists(atPath: rig.dir.appending(path: name).path), "\(name)")
            }
            let log = try String(contentsOf: rig.dir.appending(path: "activity.log"), encoding: .utf8)
            #expect(log.contains("Started mining on 127.0.0.1"))
            #expect(log.contains("Share accepted"))
            #expect(log.contains("Released"))

            // A fresh model reads the saved stats and history (the 2-minute
            // totals) back, and saves the same history again.
            let history = rig.dir.appending(path: "history-v1.json")
            let mined = try Self.minedSeconds(in: history)
            #expect(mined >= 10)
            let reopened = MiningModel(environment: rig.environment, hardware: m.hardware)
            Rig.keep(reopened)
            #expect(reopened.today.accepted >= accepted)
            #expect(reopened.lastSessionSpeed != nil)
            try FileManager.default.removeItem(at: history)
            reopened.saveStores()
            #expect(try Self.minedSeconds(in: history) == mined)
        }
    }

    /// The time recorded in a saved history's 2-minute totals that have a speed.
    private static func minedSeconds(in url: URL) throws -> Double {
        let file = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let buckets = try #require(file?["buckets"] as? [[String: Any]])
        return buckets.reduce(0) { $0 + (($1["speedSum"] as? Double ?? 0) > 0 ? $1["weight"] as? Double ?? 0 : 0) }
    }

    // Start and Stop in quick succession, including Stop while the GPU is
    // being prepared and while connecting: never two solvers, and the memory
    // always comes back.
    @Test func rapidStartStop() async throws {
        try await withRig { rig in
            let m = rig.model
            m.start()
            #expect(m.status == .preparingGPU)
            m.stop()
            #expect(m.status == .stopped && m.intent == .stopped && m.session == nil)
            m.start()
            #expect(m.status == .preparingGPU)
            m.stop()
            m.start()
            // The first load is still running; its solver is the one used.
            try await rig.wait("mining", timeout: 30) { m.status == .mining }
            #expect(rig.count(.gpuReady) == 1)
            m.stop()
            #expect(m.status == .stopping)
            m.start()                                   // ignored until the stop finishes
            #expect(m.status == .stopping && m.intent == .stopped)
            try await rig.wait("stopped", timeout: 15) { m.status == .stopped }

            // Stop while connecting (the pool turns the connection away).
            rig.pool.refuse(true)
            m.start()
            try await rig.wait("connecting", timeout: 30) { if case .connecting = m.status { true } else { false } }
            m.stop()
            #expect(m.status == .stopping)
            try await rig.wait("stopped", timeout: 15) { m.status == .stopped }
            rig.pool.refuse(false)

            // Stop during a load, and let that load finish while stopped.
            m.start()
            m.stop()
            try await rig.wait("the abandoned load to be released", timeout: 30) { m.gpuMemory == .released }
            #expect(m.status == .stopped)

            // Stop after a moment, whatever state that lands in.
            for delay in [0, 0.01, 0.03, 0.06, 0.1, 0.2, 0.4] {
                m.start()
                try await rig.run(for: delay)
                m.stop()
                try await rig.wait("stopped", timeout: 15) { m.status == .stopped }
            }

            // One more full cycle on a clean slate.
            m.start()
            try await rig.wait("mining", timeout: 30) { m.status == .mining }
            try await rig.wait("an accepted share", timeout: 20) { (m.session?.accepted ?? 0) >= 1 }
            m.stop()
            try await rig.wait("stopped", timeout: 15) { m.status == .stopped && m.gpuMemory == .released }
            try await rig.wait("the solver's buffers freed", timeout: 10) { rig.gpuBytes < rig.solverBytes / 4 }

            #expect(rig.peakBytes < rig.solverBytes * 3 / 2, "peak \(rig.peakBytes >> 20) MB. \(rig.overlap ?? "")")
            // Each "GPU ready" is followed by a release before the next one.
            var held = false
            for e in m.activity where e.kind == .gpuReady || e.kind == .memoryReleased {
                if e.kind == .gpuReady { #expect(!held, "a second solver was ready before the first was released"); held = true }
                else { held = false }
            }
        }
    }

    // The slider applies to the running Miner at once, with no restart and
    // nothing in the log.
    @Test func intensityChangesWhileMining() async throws {
        try await withRig { rig in
            let m = rig.model
            #expect(m.intensity == 100)
            m.start()
            try await rig.wait("mining", timeout: 30) { m.status == .mining }
            #expect(m.duty == 1)
            try await rig.run(for: 2)
            let full = try await rig.measure(over: 5)

            // At 50% the GPU rests half the time. Busy time is the measure: a
            // hot Mac clocks the GPU up when it rests, so speed drops less.
            // Here every graph also has a proof to recover on the GPU, so it
            // reads above 0.5.
            m.intensity = 50
            #expect(m.intensity == 50 && m.duty == 0.5)
            #expect(rig.store.string(forKey: PreferenceKey.intensity) == "50")
            try await rig.run(for: 1.5)
            let half = try await rig.measure(over: 5)
            if let fullBusy = full.busy, let halfBusy = half.busy {
                #expect(fullBusy > 0.9 && halfBusy < 0.8, "GPU busy \(halfBusy) at 50%, \(fullBusy) at 100%")
            } else {
                #expect(half.rate < full.rate * 0.8, "50% ran \(half.rate) graphs/s against \(full.rate) at 100%")
            }

            // Dragged through several stops: the last one counts, rounded to a step of 5.
            for percent in [55, 70, 85, 98] { m.intensity = percent }
            #expect(m.intensity == 100 && m.duty == 1)
            #expect(rig.store.string(forKey: PreferenceKey.intensity) == "100")
            try await rig.run(for: 1.5)
            let back = try await rig.measure(over: 5)
            if let backBusy = back.busy {
                #expect(backBusy > 0.85, "GPU busy \(backBusy) back at 100%")
            } else {
                #expect(back.rate > half.rate * 1.2, "100% ran \(back.rate) graphs/s against \(half.rate) at 50%")
            }

            // The same session and solver throughout, and not a word about it in the log.
            #expect(m.status == .mining && rig.count(.gpuReady) == 1 && rig.count(.started) == 1)
            #expect(rig.pool.logins.count == 1 && rig.pool.submissions.allSatisfy { $0.valid })
            let log = try String(contentsOf: rig.dir.appending(path: "activity.log"), encoding: .utf8)
            for word in ["power", "intensity", "%"] { #expect(!log.localizedCaseInsensitiveContains(word), "\(word)") }
        }
    }

    // The pool goes away: Reconnecting, retries while it turns connections
    // away, then mining again once it's back.
    @Test func poolDropAndReconnect() async throws {
        try await withRig { rig in
            let m = rig.model
            m.start()
            try await rig.wait("mining", timeout: 30) { m.status == .mining }
            try await rig.wait("an accepted share", timeout: 20) { (m.session?.accepted ?? 0) >= 1 }
            try await rig.wait("a measured speed", timeout: 20) { m.speed != nil }

            rig.pool.refuse(true)
            rig.pool.dropAll()
            try await rig.wait("reconnecting", timeout: 10) { m.status == .reconnecting }
            #expect(m.speed == nil && m.lastSpeed != nil && m.speedText != "—")
            #expect(m.statusWord == "Reconnecting" && m.windowSubtitle == "Reconnecting…")
            #expect(m.activity.contains { $0.kind == .disconnected })
            let logins = rig.pool.logins.count

            // Turned away at least once more; still reconnecting, and the
            // time offline doesn't count as mining.
            let mined = m.historyStore.miningSeconds(over: 900, now: Date()), counted = m.session?.miningSeconds
            #expect(mined > 0)
            try await rig.run(for: 7)
            #expect(m.status == .reconnecting)
            #expect(m.historyStore.miningSeconds(over: 900, now: Date()) == mined && m.session?.miningSeconds == counted)

            let accepted = m.session?.accepted ?? 0
            rig.pool.refuse(false)
            try await rig.wait("mining again", timeout: 15) { m.status == .mining }
            #expect(rig.pool.logins.count == logins + 1)
            try await rig.wait("a share after reconnecting", timeout: 20) { (m.session?.accepted ?? 0) > accepted }
            #expect(m.session?.rejected == 0)
            #expect(rig.count(.gpuReady) == 1)
        }
    }

    // A pool that keeps rejecting the login stops the session with an error
    // and gives the GPU back; Try Again works once the pool accepts it.
    @Test func rejectedLoginFailsAndRetries() async throws {
        try await withRig { rig in
            let m = rig.model
            rig.pool.rejectLogins(true)
            m.start()
            try await rig.wait("the login error", timeout: 40) { m.isFailed }
            #expect(m.status == .failed(.loginRejected) && m.intent == .stopped && m.canStart)
            #expect(m.statusWord == "Error" && m.session == nil)
            try await rig.wait("GPU memory released", timeout: 15) { m.gpuMemory == .released }
            try await rig.wait("the solver's buffers freed", timeout: 10) { rig.gpuBytes < rig.solverBytes / 4 }

            rig.pool.rejectLogins(false)
            m.retry()
            #expect(m.status == .preparingGPU)
            try await rig.wait("mining after Try Again", timeout: 30) { m.status == .mining }
            try await rig.wait("an accepted share", timeout: 20) { (m.session?.accepted ?? 0) >= 1 }
        }
    }

    // Quitting while mining: totals saved, the Miner stopped, done called.
    @Test func quitWhileMining() async throws {
        try await withRig { rig in
            let m = rig.model
            m.start()
            try await rig.wait("an accepted share", timeout: 40) { (m.session?.accepted ?? 0) >= 1 }
            var done = false
            m.prepareToQuit { done = true }
            #expect(!m.hasActiveSession)
            try await rig.wait("quit to finish", timeout: 5) { done }
            try await rig.wait("the Miner to leave the pool", timeout: 5) { rig.pool.openConnections == 0 }
            let stats = try Data(contentsOf: rig.dir.appending(path: "stats-v1.json"))
            #expect(!stats.isEmpty)
            let reopened = MiningModel(environment: rig.environment, hardware: m.hardware)
            Rig.keep(reopened)
            #expect(reopened.today.accepted >= 1)
        }
    }
}

// MARK: Kryptex refresh

/// Answers Kryptex's endpoints from memory; every request in the session
/// lands here, so nothing reaches the network.
private final class KryptexStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _paid = 400.0
    nonisolated(unsafe) private static var _paths: [String] = []
    static var paid: Double {
        get { lock.withLock { _paid } }
        set { lock.withLock { _paid = newValue } }
    }
    static var paths: [String] { lock.withLock { _paths } }

    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [KryptexStub.self]
        return URLSession(configuration: c)
    }()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        let path = url.path
        Self.lock.withLock { Self._paths.append(path) }
        let body: String? = if path.hasSuffix("/pool/info") {
            #"{"miners":1320,"hashrate":20330.17,"net_hashrate":23394,"fee":0.01,"minpay":200.0,"height":361360,"block_time":480,"block_reward":10156.1}"#
        } else if path.hasSuffix("/api/v1/rates") {
            #"{"crypto":{"XTM":0.0017111}}"#
        } else if path.contains("/miner/balance/") {
            #"{"total":126.4,"unconfirmed":4.1,"confirmed":122.3,"threshold":200.0,"maturation_time":21600.0}"#
        } else if path.contains("/miner/payouts/") {
            #"{"paid":\#(Self.paid),"unpaid":126.4}"#
        } else {
            nil
        }
        let response = HTTPURLResponse(url: url, statusCode: body == nil ? 404 : 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((body ?? "").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

// The earnings loop the live model starts at launch, a payout, a wallet edit
// and a switch to another pool, all against a stubbed Kryptex.
@MainActor @Test func kryptexRefreshAndPayout() async throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "macotaur-earnings-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    KryptexStub.paid = 400
    let store = MemoryStore(seed: [PreferenceKey.wallet: "12LiveTestWallet", PreferenceKey.worker: "rig"])
    let env = AppEnvironment(isDemo: false, store: store, historyURL: dir.appending(path: "history-v1.json"),
                             statsURL: dir.appending(path: "stats-v1.json"), activityLogURL: dir.appending(path: "activity.log"),
                             networking: true, urlSession: KryptexStub.session, systemMonitors: false,
                             telemetry: false, canMine: false, keepAwake: false)
    let m = MiningModel(environment: env, hardware: DemoData.hardware(.air))
    func wait(_ what: String, until done: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !done() {
            guard Date() < deadline else { Issue.record("Timed out waiting for \(what)"); throw TimedOut() }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    // The first fetch at launch sets the payout baseline.
    try await wait("the first fetch") { m.kryptex != nil }
    #expect(m.kryptex?.balance?.total == 126.4 && m.kryptex?.usdPerXTM == 0.0017111)
    #expect(m.lastPayout == nil && !m.activity.contains { $0.kind == .payout })
    #expect(m.payoutFigure == Figure(text: "63%", help: "to 200 XTM"))
    // Only the balance and payouts are asked for by wallet.
    #expect(KryptexStub.paths.filter { $0.contains("12LiveTestWallet") }
        .allSatisfy { $0.contains("/miner/balance/") || $0.contains("/miner/payouts/") })
    // With a window open the model ticks every 2 s.
    m.noteVisible(.dashboard, true)
    let revision = m.historyRevision
    try await wait("a tick") { m.historyRevision > revision }

    // The paid total grows: a payout.
    KryptexStub.paid = 601.5
    await m.refreshEarnings()
    #expect(m.lastPayout?.amount == 201.5)
    #expect(m.activity.filter { $0.kind == .payout }.count == 1)
    #expect(m.payoutFigure?.help.hasPrefix("Paid ") == true)
    #expect(FileManager.default.fileExists(atPath: dir.appending(path: "stats-v1.json").path))

    // Another wallet: refetched after the debounce, with its own baseline.
    m.wallet = "12OtherWallet"
    #expect(m.kryptex == nil)
    try await wait("the refetch for the new wallet") { m.kryptex != nil }
    #expect(KryptexStub.paths.contains { $0.hasSuffix("/12OtherWallet") })
    #expect(m.activity.filter { $0.kind == .payout }.count == 1)

    // Another pool: only pool info and rates, and no wallet sent.
    let before = KryptexStub.paths.count
    m.preset = .custom
    try await wait("the network-only refetch") { m.kryptex != nil && KryptexStub.paths.count > before }
    let after = KryptexStub.paths.dropFirst(before)
    #expect(after.allSatisfy { !$0.contains("Wallet") })
    #expect(m.kryptex?.pool?.netHashrate == 23394 && m.kryptex?.balance == nil)
    #expect(m.payoutFigure == nil)
}
