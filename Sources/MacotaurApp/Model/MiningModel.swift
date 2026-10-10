import AppKit
import CryptoKit
import Foundation
import MacotaurCore
import Observation
import SwiftUI

/// App state: settings, the mining lifecycle (start, stop, GPU memory),
/// stats, history, earnings, telemetry and activity. Views read it through
/// `@Environment(MiningModel.self)`.
@MainActor @Observable
final class MiningModel {
    static let shared: MiningModel = {
        let o = LaunchOptions.current
        if let p = o.demo {
            let m = MiningModel(demo: o.isSnapshot ? .default(p) : .interactive(p))
            if !o.isSnapshot { m.startDemoDriver() }
            return m
        }
        return MiningModel(environment: .live(readOnly: o.isSnapshot || o.powerDebug))
    }()

    // MARK: Nested types

    enum PoolPreset: String, CaseIterable, Identifiable {
        case kryptex, luckyPool, custom
        var id: Self { self }
        var title: String {
            switch self {
            case .kryptex: "Kryptex"
            case .luckyPool: "LuckyPool"
            case .custom: "Custom"
            }
        }
        var summary: String {
            switch self {
            case .kryptex: Copy.kryptexSummary
            case .luckyPool: "LuckyPool's C29 pool."
            case .custom: "Any pool that speaks the XMRig-style protocol."
            }
        }
    }

    enum KryptexRegion: String, CaseIterable, Identifiable {
        case global, northAmerica = "us", europe = "eu", southAmerica = "br"
        case singapore = "sg", hongKong = "hk", russia = "ru", middleEast = "ae"
        var id: Self { self }
        var title: String {
            switch self {
            case .global: "Global (automatic)"
            case .northAmerica: "North America"
            case .europe: "Europe"
            case .southAmerica: "South America"
            case .singapore: "Singapore"
            case .hongKong: "Hong Kong"
            case .russia: "Russia"
            case .middleEast: "Middle East"
            }
        }
        var host: String { self == .global ? "xtm-c29.kryptex.network" : "xtm-c29-\(rawValue).kryptex.network" }
    }

    enum WalletCheck { case empty, looksValid, suspicious(String) }
    enum Intent: Equatable { case stopped, mining }

    struct Problem: Equatable {
        var title: String
        var detail: String
    }

    enum Status: Equatable {
        case stopped, preparingGPU
        case connecting(trouble: String?)
        case mining
        case reconnecting, stopping
        case failed(Problem)
    }

    static let connectTrouble = "Can't reach the pool yet. Retrying every 5 seconds."
    static let tickInterval: TimeInterval = 2

    // MARK: Environment

    let environment: AppEnvironment
    let hardware: HardwareProfile
    var isDemo: Bool { environment.isDemo }

    // MARK: Settings (persisted through environment.store)

    var preset: PoolPreset {
        didSet { guard preset != oldValue else { return }; save(PreferenceKey.preset, preset.rawValue); earningsInputsChanged() }
    }
    var kryptexRegion: KryptexRegion { didSet { save(PreferenceKey.kryptexRegion, kryptexRegion.rawValue) } }
    var customHost: String { didSet { save(PreferenceKey.customHost, customHost) } }
    var customPort: String { didSet { save(PreferenceKey.customPort, customPort) } }
    var customSeparator: String { didSet { save(PreferenceKey.customSeparator, customSeparator) } }
    var wallet: String {
        didSet { guard wallet != oldValue else { return }; save(PreferenceKey.wallet, wallet); earningsInputsChanged() }
    }
    var worker: String { didSet { save(PreferenceKey.worker, worker) } }
    /// How much of the time the GPU works, in percent: 10 to 100 in steps of
    /// 5. A running Miner takes a change at once.
    var intensity: Int {
        get { storedIntensity }
        set {
            let v = Self.intensity(nearest: newValue)
            guard v != storedIntensity else { return }
            storedIntensity = v
            save(PreferenceKey.intensity, String(v))
            miner?.dutyCycle = duty
        }
    }
    private var storedIntensity: Int
    var ui: UIState { didSet { if ui != oldValue { saveJSON(ui, PreferenceKey.ui) } } }

    // MARK: Lifecycle state

    private(set) var intent: Intent = .stopped
    private(set) var status: Status = .stopped
    private(set) var gpuMemory: GPUMemoryState = .released

    // MARK: Speed and stats

    private(set) var speed: Double?
    /// The last measured speed of this session (shown dimmed while reconnecting or stopping).
    private(set) var lastSpeed: Double?
    private(set) var session: SessionStats?
    private(set) var today: TodayStats
    private(set) var thermalState: ProcessInfo.ThermalState
    /// The last session's average speed.
    private(set) var lastSessionSpeed: Double?

    // MARK: Earnings

    private(set) var kryptex: KryptexAPI.Snapshot?
    private(set) var lastPayout: PayoutEvent?

    // MARK: Power

    private(set) var power = PowerReadout()

    // MARK: History, activity, clock

    private(set) var historyRevision = 0
    private(set) var activity: [ActivityEntry] = []
    /// Tick clock (2 s); fixed in demo snapshots.
    private(set) var now: Date

    // MARK: Internals

    @ObservationIgnored let historyStore: HistoryStore
    @ObservationIgnored private let statsStore: StatsStore
    @ObservationIgnored private var visibleSurfaces: Set<UISurface> = []
    @ObservationIgnored private var connectedOptions: PoolClient.Options?
    @ObservationIgnored private var meter = SpeedMeter()
    @ObservationIgnored private var solver: MetalSolver?
    @ObservationIgnored private var solverLoading = false
    /// A solver is being given back; a new one waits for it (never two at once).
    @ObservationIgnored private var releasing = 0
    @ObservationIgnored private var loadAfterRelease = false
    @ObservationIgnored private var miner: Miner?
    @ObservationIgnored private var minerID = 0
    @ObservationIgnored private var lastMinerStats = Miner.Stats()
    @ObservationIgnored private var lastTickAt: Date?
    @ObservationIgnored private var lastSaveAt = Date()
    @ObservationIgnored private var lastHeat: HeatLevel?
    @ObservationIgnored private var loginFailures = 0
    @ObservationIgnored private var loggedInThisRun = false
    @ObservationIgnored private var lastAnnouncedAt: Date?
    @ObservationIgnored private var shareFIFO: [(difficulty: UInt64, target: UInt64, entry: UUID)] = []
    @ObservationIgnored private var activityLog = ActivityLog(capacity: 1000)
    @ObservationIgnored private var logFile: FileHandle?
    @ObservationIgnored private var powerSamples: [PowerSample] = []
    @ObservationIgnored private var awake: NSObjectProtocol?
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var monitor: SystemMonitor?
    @ObservationIgnored private var telemetry: Telemetry?
    @ObservationIgnored private var pendingRefresh: Task<Void, Never>?
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var openWindowAction: OpenWindowAction?
    @ObservationIgnored private var demoDriver: Timer?
    @ObservationIgnored private var demoFixture: DemoFixture?
    @ObservationIgnored private var demoRandom = SplitMix64(seed: 1)
    @ObservationIgnored private var demoNextShare = Date.distantFuture
    @ObservationIgnored private var demoNextCycle = Date.distantFuture
    @ObservationIgnored private var demoGraphs = 0.0

    // MARK: Init

    init(environment: AppEnvironment, hardware: HardwareProfile = .detect()) {
        self.environment = environment
        self.hardware = hardware
        let store = environment.store
        let t = Date()
        now = t
        preset = PoolPreset(rawValue: store.string(forKey: PreferenceKey.preset) ?? "") ?? .kryptex
        kryptexRegion = KryptexRegion(rawValue: store.string(forKey: PreferenceKey.kryptexRegion) ?? "") ?? .global
        customHost = store.string(forKey: PreferenceKey.customHost) ?? ""
        customPort = store.string(forKey: PreferenceKey.customPort) ?? ""
        customSeparator = store.string(forKey: PreferenceKey.customSeparator) ?? "."
        wallet = store.string(forKey: PreferenceKey.wallet) ?? ""
        // Not the Mac's name: pools list worker names on their stats pages.
        worker = store.string(forKey: PreferenceKey.worker) ?? "mac"
        storedIntensity = Self.loadIntensity(from: store)
        ui = store.decode(UIState.self, forKey: PreferenceKey.ui) ?? UIState()
        historyStore = HistoryStore(url: environment.historyURL)
        statsStore = StatsStore(url: environment.statsURL, now: t)
        today = statsStore.today
        thermalState = environment.isDemo ? .nominal : ProcessInfo.processInfo.thermalState
        lastPayout = statsStore.lastPayout.map { PayoutEvent(amount: $0.amount, date: $0.date) }
        lastSessionSpeed = statsStore.lastSessionSpeed
        if !environment.isDemo { setUpLive() }
    }

    /// A fresh, fully populated, inert model for the demo and snapshots.
    convenience init(demo scenario: DemoScenario) {
        let fixture = DemoData.fixture(scenario)
        self.init(environment: .demo(), hardware: fixture.hardware)
        loadDemo(fixture, scenario: scenario)
    }

    private func setUpLive() {
        if environment.systemMonitors {
            let m = SystemMonitor { [weak self] in self?.mirrorMonitor() }
            monitor = m
            m.start()
            mirrorMonitor()
        }
        if environment.telemetry {
            telemetry = Telemetry { [weak self] s in self?.ingest(s) }
        }
        if environment.isReadOnly { return }
        ticker = makeTicker(every: Self.tickInterval)
        if environment.networking {
            Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    await self.refreshEarnings()
                    // Short steps, so opening a window or starting to mine
                    // brings back the 1-minute cadence at once.
                    var fetched = Date()
                    while !Task.isCancelled {
                        if let f = self.kryptex?.fetchedAt, f > fetched { fetched = f }
                        if Date().timeIntervalSince(fetched) >= self.earningsInterval { break }
                        try? await Task.sleep(for: .seconds(5))
                    }
                }
            }
        }
        updateCadence()
    }

    // MARK: Persistence

    private func save(_ key: String, _ value: String) { environment.store.set(value, forKey: key) }
    private func saveJSON<T: Encodable>(_ value: T, _ key: String) { environment.store.encode(value, forKey: key) }

    /// Saves history and stats (no-ops with nil URLs: demo and snapshot).
    func saveStores() {
        try? historyStore.save()
        try? statsStore.save()
        lastSaveAt = Date()
    }

    // MARK: Setup

    var walletTrimmed: String { wallet.trimmingCharacters(in: .whitespacesAndNewlines) }
    var hasWallet: Bool { !walletTrimmed.isEmpty }
    var workerName: String {
        let w = worker.trimmingCharacters(in: .whitespaces)
        return w.isEmpty ? "mac" : w
    }

    /// Light sanity check, not a full decode: Tari addresses are Base58 and
    /// around 90 characters (one-sided addresses start with "12").
    var walletCheck: WalletCheck {
        let w = walletTrimmed
        if w.isEmpty { return .empty }
        let base58 = Set("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
        if let bad = w.first(where: { !base58.contains($0) }) {
            return .suspicious("Contains \"\(bad)\", which can't appear in a Tari address")
        }
        if w.count < 60 { return .suspicious("Too short for a Tari address") }
        return .looksValid
    }

    var endpoint: (host: String, port: UInt16, separator: String)? {
        switch preset {
        case .kryptex: return (kryptexRegion.host, 7040, "/")
        case .luckyPool: return ("taric29.luckypool.io", 3111, ".")
        case .custom:
            let host = customHost.trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty, let port = UInt16(customPort.trimmingCharacters(in: .whitespaces)) else { return nil }
            return (host, port, customSeparator.isEmpty ? "." : customSeparator)
        }
    }

    /// "Kryptex Europe" / "Kryptex" / "LuckyPool" / the custom host.
    var poolLabel: String {
        switch preset {
        case .kryptex: kryptexRegion == .global ? "Kryptex" : "Kryptex \(kryptexRegion.title)"
        case .luckyPool: "LuckyPool"
        case .custom: customHost.trimmingCharacters(in: .whitespaces).isEmpty ? "Custom pool" : customHost.trimmingCharacters(in: .whitespaces)
        }
    }

    var canStart: Bool {
        let idle = switch status {
        case .stopped, .failed: true
        default: false
        }
        return idle && intent == .stopped && hasWallet && endpoint != nil
    }

    var isRunning: Bool {
        switch status {
        case .preparingGPU, .connecting, .mining, .reconnecting: true
        default: false
        }
    }
    var isFailed: Bool { if case .failed = status { true } else { false } }
    /// A session is active from start until stop finishes.
    var hasActiveSession: Bool { intent == .mining || status == .stopping }

    // MARK: Lifecycle

    func start() {
        guard canStart, let endpoint else { return }
        if !isDemo || demoDriver != nil { now = Date() }
        let options = PoolClient.Options(host: endpoint.host, port: endpoint.port,
                                         user: walletTrimmed + endpoint.separator + workerName)
        connectedOptions = options
        intent = .mining
        speed = nil
        lastSpeed = nil
        session = SessionStats(startedAt: now)
        log(.started, "Started mining on \(endpoint.host):\(endpoint.port) as \(workerName)", at: now)
        beginKeepAwake()
        if environment.canMine {
            prepareSolver()
        } else {
            simulateRun()
        }
        updateCadence()
    }

    /// User Stop always wins, from any state.
    func stop() {
        switch status {
        case .stopped, .stopping: return
        case .failed:
            status = .stopped
            intent = .stopped
            return
        default: break
        }
        intent = .stopped
        endKeepAwake()
        switch status {
        case .preparingGPU:
            // The load can't be cancelled; its solver is dropped when it returns.
            status = .stopped
            finishSession()
        default:
            status = .stopping
            if !environment.canMine {
                simulateStop()
                return
            }
            retire { [weak self] in
                guard let self, self.status == .stopping else { return }
                self.now = Date()   // the tick clock lags; "Stopped" goes after "Released"
                self.status = .stopped
                self.finishSession()
            }
        }
        updateCadence()
    }

    /// Try Again after a failure.
    func retry() {
        if isFailed { status = .stopped; intent = .stopped }
        start()
    }

    /// Stops the Miner (waiting at most 2 s) and saves history and stats.
    func prepareToQuit(_ done: @escaping @MainActor () -> Void) {
        let m = miner
        if let m { account(m.stats, dt: 0, at: Date()) }
        miner = nil
        minerID += 1
        m?.stop()
        if hasActiveSession { finishSession() }
        intent = .stopped
        endKeepAwake()
        saveStores()
        logFile?.synchronizeFile()
        DispatchQueue.global(qos: .userInitiated).async {
            if let m {
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async { m.waitUntilStopped(); group.leave() }
                _ = group.wait(timeout: .now() + 2)
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { done() } }
        }
    }

    // MARK: Solver and Miner

    private func prepareSolver() {
        status = .preparingGPU
        gpuMemory = .reserving(hardware.solverBytes)
        guard !solverLoading else { return }   // an earlier load is still running; its result is used
        guard releasing == 0 else { loadAfterRelease = true; return }
        solverLoading = true
        let started = Date()
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<MetalSolver, Error> in
                Result { try MetalSolver() }
            }.value
            self?.solverLoaded(result, started: started)
        }
    }

    private func solverLoaded(_ result: Result<MetalSolver, Error>, started: Date) {
        solverLoading = false
        switch result {
        case .success(let s):
            guard intent == .mining else {
                // Stopped while preparing: give the memory back at once.
                solver = s
                retire()
                return
            }
            solver = s
            let seconds = Date().timeIntervalSince(started)
            var gpu = hardware.chipName
            if let c = hardware.gpuCores { gpu += ", \(c)-core GPU" }
            log(.gpuReady, "GPU ready: \(gpu) · \(Format.bytes(UInt64(s.gpuMemoryBytes))) reserved in "
                + seconds.formatted(.number.precision(.fractionLength(1))) + " s"
                + (s.isLowMemoryMode ? " · low-memory mode" : ""), at: Date())
            createMiner(s)
        case .failure(let error):
            gpuMemory = .released
            guard intent == .mining else { return }
            let allocation = if case MetalSolver.SolverError.allocation = error { true } else { false }
            fail(allocation ? .memory(bytes: hardware.solverBytes) : .setup(error))
        }
    }

    private func createMiner(_ s: MetalSolver) {
        guard let options = connectedOptions else { return }
        minerID += 1
        let id = minerID
        let m = Miner(solver: s, pool: options) { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(event, minerID: id) }
            }
        }
        m.dutyCycle = duty
        miner = m
        lastMinerStats = Miner.Stats()
        meter.reset()
        loginFailures = 0
        loggedInThisRun = false
        status = .connecting(trouble: nil)
        gpuMemory = .inUse(hardware.solverBytes)
        m.start()
    }

    /// Stops the Miner, waits for the GPU to go idle and drops the solver,
    /// giving its memory back.
    private func retire(then: (@MainActor @Sendable () -> Void)? = nil) {
        var m = miner
        if let m { account(m.stats, dt: 0, at: Date()) }
        miner = nil
        minerID += 1
        shareFIFO.removeAll()
        speed = nil
        m?.stop()
        var s = solver
        solver = nil
        let bytes = s.map { UInt64($0.gpuMemoryBytes) } ?? hardware.solverBytes
        guard m != nil || s != nil else {
            gpuMemory = .released
            then?()
            return
        }
        let released = s != nil
        if released { releasing += 1 }
        Task.detached {
            m?.waitUntilStopped()
            s?.waitUntilIdle()
            m = nil   // the Miner holds the solver too
            // So do the Miner's last graphs in its cycle search and proof
            // queues, for a few hundred ms more. A new solver mustn't be made
            // before this one is gone, so wait (at most 10 s) to hold the last
            // reference.
            for _ in 0..<500 where s != nil && !isKnownUniquelyReferenced(&s) {
                try? await Task.sleep(for: .milliseconds(20))
            }
            s = nil   // the last reference: the buffers go back to the system here
            await MainActor.run { [weak self] in
                guard let self else { return }
                if released { self.didRelease(bytes) }
                then?()
            }
        }
    }

    private func didRelease(_ bytes: UInt64) {
        releasing -= 1
        // Unless a new solver is already loading or held.
        if solver == nil && !solverLoading { gpuMemory = .released }
        log(.memoryReleased, "Released \(Format.bytes(bytes)) of GPU memory", at: Date())
        if releasing == 0 && loadAfterRelease {
            loadAfterRelease = false
            if intent == .mining && status == .preparingGPU { prepareSolver() }
        }
    }

    private func fail(_ p: Problem) {
        intent = .stopped
        if miner != nil || solver != nil { retire() }
        status = .failed(p)
        endKeepAwake()
        log(.problem, "\(p.title) · \(p.detail)", at: now)
        if session != nil { finishSession(logIt: false) }
        updateCadence()
    }

    private func finishSession(logIt: Bool = true) {
        guard let s = session else { return }
        let duration = now.timeIntervalSince(s.startedAt)
        if logIt {
            log(.stopped, "Stopped after \(Format.duration(duration)) · \(s.accepted) accepted, \(s.rejected) rejected", at: now)
        }
        if s.miningSeconds >= 30, s.graphs > 0 {
            let avg = Double(s.graphs) / s.miningSeconds
            statsStore.lastSessionSpeed = avg
            lastSessionSpeed = avg
        }
        session = nil
        speed = nil
        saveStores()
        refreshReadout()
    }

    private func beginKeepAwake() {
        guard environment.keepAwake, awake == nil else { return }
        awake = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                      reason: "Mining Tari C29")
    }

    private func endKeepAwake() {
        if let awake { ProcessInfo.processInfo.endActivity(awake) }
        awake = nil
    }

    // MARK: Power

    /// The Miner's duty cycle.
    var duty: Double { Double(intensity) / 100 }

    /// The nearest stop on the slider.
    static func intensity(nearest percent: Int) -> Int {
        min(100, max(10, Int((Double(percent) / 5).rounded()) * 5))
    }

    /// The stored intensity; without one, an older version's power mode is
    /// carried over once (and its key left as it is).
    private static func loadIntensity(from store: PreferenceStore) -> Int {
        if let v = store.string(forKey: PreferenceKey.intensity).flatMap(Int.init) { return intensity(nearest: v) }
        let carried: Int? = switch store.string(forKey: PreferenceKey.oldPowerMode) {
        case "full", "auto": 100
        case "balanced": 75
        case "cool": 50
        default: nil
        }
        if let carried { store.set(String(carried), forKey: PreferenceKey.intensity) }
        return carried ?? 100
    }

    // MARK: Tick

    private func tick() {
        let t = Date()
        let dt = lastTickAt.map { min(max(t.timeIntervalSince($0), 0), 10) } ?? 0
        lastTickAt = t
        now = t
        mirrorMonitor()
        statsStore.rollOver(now: t)

        if let m = miner {
            account(m.stats, dt: dt, at: t)
            meter.record(graphs: lastMinerStats.graphs, miningSeconds: session?.miningSeconds ?? 0, at: t)
            speed = status == .mining ? meter.speed() : nil
            if let v = speed { lastSpeed = v }
        }
        recordHistory(at: t)
        logHeatChange()
        today = statsStore.today
        refreshReadout()
        if hasActiveSession, t.timeIntervalSince(lastSaveAt) >= 300 { saveStores() }   // stop and quit save too
        updateCadence()
        historyRevision += 1
    }

    private func mirrorMonitor() {
        guard let monitor, thermalState != monitor.thermal else { return }
        thermalState = monitor.thermal
    }

    private func makeTicker(every seconds: TimeInterval) -> Timer {
        let t = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = seconds / 10
        return t
    }

    /// Folds a Miner's counters into the session and today's totals.
    private func account(_ s: Miner.Stats, dt: Double, at t: Date) {
        let dGraphs = max(0, s.graphs - lastMinerStats.graphs)
        lastMinerStats = s
        let miningDt = status == .mining ? dt : 0
        if let job = s.job, job.difficulty > 0 {
            statsStore.addExpected(Double(dGraphs) / 42 / Double(job.difficulty), now: t)
        }
        if var se = session {
            se.graphs = s.graphs
            se.accepted = s.accepted
            se.rejected = s.rejected
            se.job = s.job ?? se.job
            se.miningSeconds += miningDt
            session = se
        }
    }

    private func recordHistory(at t: Date) {
        guard intent == .mining else { return }
        switch status {
        case .mining: historyStore.record(HistorySample(time: t, speed: speed))
        // Out of the pool's reach: recorded, with no speed.
        case .reconnecting, .connecting(_?): historyStore.record(HistorySample(time: t, speed: nil))
        default: break
        }
    }

    private func logHeatChange() {
        let h = HeatLevel(thermalState)
        defer { lastHeat = h }
        guard hasActiveSession, let last = lastHeat, last != h else { return }
        log(.thermal, "Heat: \(h.title)", at: now)
    }

    // MARK: Miner events

    private func handle(_ e: Miner.Event, minerID id: Int) {
        guard id == minerID, miner != nil else { return }
        apply(e, at: Date(), replay: false)
    }

    /// The real event path; demo fixtures replay through it with `replay`
    /// (activity only, no side effects on stats or status).
    func apply(_ e: Miner.Event, at t: Date, replay: Bool) {
        switch e {
        case .pool(.connected):
            log(.connected, "Connected to the pool", at: t)
        case .pool(.loggedIn):
            log(.loggedIn, "Logged in", at: t)
            // Submits still unanswered went with the old connection.
            shareFIFO.removeAll()
            if !replay {
                loginFailures = 0
                loggedInThisRun = true
                poolReachable()
            }
        case .pool(.newJob(let j)):
            logJob(height: j.height, difficulty: j.difficulty, at: t)
            if !replay {
                session?.job = j
                poolReachable()
            }
        case .pool(.shareResult(let ok, let err)):
            let pending = shareFIFO.isEmpty ? nil : shareFIFO.removeFirst()
            let d = pending?.difficulty ?? 0, target = pending?.target ?? 0
            let needs = target > 0 ? " (needs \(target.formatted()))" : ""
            let text = ok ? "Share accepted · difficulty \(d.formatted())\(needs)"
                : "Share rejected · \(err ?? "no reason given") · difficulty \(d.formatted())"
            if let entry = pending?.entry {
                updateLog(entry, kind: ok ? .shareAccepted : .shareRejected, text: text)
            } else {
                log(ok ? .shareAccepted : .shareRejected, text, at: t)
            }
            if !replay {
                statsStore.addShare(accepted: ok, now: t)
                today = statsStore.today
                if ok { announceShare(at: t) }
            }
        case .pool(.loginFailed(let why)):
            log(.loginFailed, "Login failed · \(why)", at: t)
            if !replay {
                loginFailures += 1
                if loginFailures >= 3 && !loggedInThisRun { fail(.loginRejected) }
            }
        case .pool(.disconnected(let why)):
            activityLog.appendDisconnect(reason: why, retryDelay: connectedOptions?.reconnectDelay ?? 5, at: t)
            publishActivity(raw: "Disconnected · \(why)", at: t)
            if !replay {
                switch status {
                case .mining: status = .reconnecting
                case .connecting(nil): status = .connecting(trouble: Self.connectTrouble)
                default: break
                }
                speed = nil
            }
        case .pool(.log(let s)):
            log(.info, s.prefix(1).uppercased() + s.dropFirst(), at: t)
        case .share(let d, let target, let submitted):
            if submitted {
                let id = log(.shareSubmitted, "Found a share · difficulty \(d.formatted()) (needs \(target.formatted()))", at: t)
                shareFIFO.append((d, target, id))
            } else {
                activityLog.appendCycle(difficulty: d, target: target, at: t)
                // About one graph in 42: too many for the log file.
                publishActivity(raw: "42-cycle · difficulty \(d) (needs \(target))", at: t, toFile: false)
            }
        case .stale:
            log(.shareStale, "Share was stale · a newer block arrived", at: t)
        }
    }

    private func poolReachable() {
        switch status {
        case .connecting, .reconnecting: status = .mining
        default: break
        }
    }

    /// VoiceOver hears about accepted shares, at most once a minute.
    private func announceShare(at t: Date) {
        guard !isDemo, lastAnnouncedAt.map({ t.timeIntervalSince($0) >= 60 }) ?? true else { return }
        lastAnnouncedAt = t
        AccessibilityNotification.Announcement("Share accepted").post()
    }

    // MARK: Activity

    @discardableResult
    private func log(_ kind: ActivityKind, _ text: String, at t: Date) -> UUID {
        let id = activityLog.append(kind, text, at: t)
        publishActivity(raw: text, at: t)
        return id
    }

    private func logJob(height: UInt64, difficulty: UInt64, at t: Date) {
        activityLog.appendJob(height: height, difficulty: difficulty, at: t)
        publishActivity(raw: "New job · height \(height) · difficulty \(difficulty)", at: t)
    }

    private func updateLog(_ id: UUID, kind: ActivityKind, text: String) {
        activityLog.update(id: id, kind: kind, text: text)
        publishActivity(raw: text, at: now)
    }

    /// Publishes the collapsed list and appends the raw line to the log file
    /// (live only).
    private func publishActivity(raw: String, at t: Date, toFile: Bool = true) {
        activity = activityLog.entries
        guard toFile, let url = environment.activityLogURL else { return }
        if logFile == nil { logFile = Self.openLog(url) }
        // A full disk must not take mining down with it.
        do { try logFile?.write(contentsOf: Data("\(t.ISO8601Format()) \(raw)\n".utf8)) } catch { logFile = nil }
    }

    /// Opens the log for appending; past 4 MB the old one moves to activity.1.log.
    private static func openLog(_ url: URL) -> FileHandle? {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 4 << 20 {
            let previous = url.deletingPathExtension().appendingPathExtension("1.log")
            try? fm.removeItem(at: previous)
            try? fm.moveItem(at: url, to: previous)
        }
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        let handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        return handle
    }

    // MARK: Earnings

    private var earningsInterval: TimeInterval {
        guard preset == .kryptex, hasWallet else { return 600 }
        return !visibleSurfaces.isEmpty || intent == .mining ? 60 : 600
    }

    func refreshEarnings() async {
        guard environment.networking, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let isKryptex = preset == .kryptex
        let w = walletTrimmed
        let session = environment.urlSession
        // A failed fetch keeps the last figures; the next one is a minute away.
        guard let snap = isKryptex && !w.isEmpty
                ? try? await KryptexAPI.snapshot(wallet: w, session: session)
                : try? await KryptexAPI.networkSnapshot(session: session),
              w == walletTrimmed, isKryptex == (preset == .kryptex) else { return }   // or edited meanwhile
        kryptex = snap
        if isKryptex && !w.isEmpty { detectPayout(snap) }
    }

    /// Wallet or pool edits: debounce 1 s, then refresh.
    private func earningsInputsChanged() {
        guard environment.networking else { return }
        pendingRefresh?.cancel()
        kryptex = nil
        pendingRefresh = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.refreshEarnings()
        }
    }

    /// First 8 hex characters of SHA-256 of the wallet.
    private var walletKey: String {
        SHA256.hash(data: Data(walletTrimmed.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    func detectPayout(_ snap: KryptexAPI.Snapshot) {
        guard let paid = snap.payouts?.paid else { return }
        let key = walletKey
        let last = statsStore.lastPaid(walletKey: key)
        // Paid totals only grow; a lower one is a bad response, not a new baseline.
        if paid > (last ?? -.infinity) { statsStore.setLastPaid(paid, walletKey: key) }
        guard let last else { return }   // the first fetch sets a baseline
        guard paid > last + 1e-6 else { return }
        let amount = paid - last, t = Date()
        lastPayout = PayoutEvent(amount: amount, date: t)
        statsStore.lastPayout = (amount, t)
        log(.payout, "Payout received · \(Format.xtm(amount))", at: t)
        saveStores()
    }

    // MARK: Telemetry

    private func updateCadence() {
        // Stopped with nothing on screen: bookkeeping every 10 s, and no polling.
        let interval = hasActiveSession || !visibleSurfaces.isEmpty ? Self.tickInterval : 10
        if let old = ticker, old.timeInterval != interval {
            old.invalidate()
            ticker = makeTicker(every: interval)
        }
        guard let telemetry else { return }
        if hasActiveSession { telemetry.setInterval(2) }
        else if !visibleSurfaces.isEmpty { telemetry.setInterval(10) }
        else { telemetry.setInterval(nil) }
    }

    private func ingest(_ s: PowerSample) {
        powerSamples.append(s)
        if let f = powerSamples.first, s.time.timeIntervalSince(f.time) > 660 {
            powerSamples.removeAll { s.time.timeIntervalSince($0.time) > 600 }
        }
        refreshReadout()
    }

    /// Rebuilds `power` from the last 10 s of samples: readings only while mining.
    private func refreshReadout() {
        var r = power
        let mining = status == .mining
        let recent = powerSamples.filter { (powerSamples.last?.time ?? .distantPast).timeIntervalSince($0.time) <= 10 }
        func mean(_ k: KeyPath<PowerSample, Double?>) -> Double? {
            let v = recent.compactMap { $0[keyPath: k] }
            return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
        }
        r.gpuWatts = mining ? mean(\.gpuWatts) : nil
        r.gpuMHz = mining ? mean(\.gpuMHz) : nil
        r.joulesPerGraph = r.gpuWatts.flatMap { w in speed.flatMap { $0 > 0 ? w / $0 : nil } }
        if r != power { power = r }
    }

    // MARK: Navigation and visibility

    func installNavigation(openWindow: OpenWindowAction) {
        openWindowAction = openWindow
    }

    func showDashboard() {
        openWindowAction?(id: "dashboard")
        NSApp.activate()
    }

    func noteVisible(_ surface: UISurface, _ visible: Bool) {
        let wasEmpty = visibleSurfaces.isEmpty
        if visible { visibleSurfaces.insert(surface) } else { visibleSurfaces.remove(surface) }
        updateCadence()
        if visible && wasEmpty, environment.networking, !environment.isReadOnly,
           (kryptex.map { Date().timeIntervalSince($0.fetchedAt) > 60 } ?? true) {
            Task { await refreshEarnings() }
        }
    }

    // MARK: Demo

    /// Sets the demo's inputs; every derived value comes from the real code paths.
    private func loadDemo(_ f: DemoFixture, scenario: DemoScenario) {
        demoFixture = f
        demoRandom = SplitMix64(seed: UInt64(truncatingIfNeeded: scenario.profile.rawValue.hashValueStable))
        f.settings(self)
        now = scenario.now
        thermalState = f.thermal
        kryptex = f.kryptex
        for s in f.samples { historyStore.record(s) }
        statsStore.load(today: f.today)
        today = f.today
        lastSessionSpeed = f.lastSessionSpeed
        // Activity: model-level lines and raw Miner events, in time order.
        var items: [(Date, Int, () -> Void)] = []
        for (i, l) in f.logLines.enumerated() { items.append((l.0, i, { [unowned self] in self.log(l.1, l.2, at: l.0) })) }
        for (i, e) in f.events.enumerated() { items.append((e.0, 10_000 + i, { [unowned self] in self.apply(e.1, at: e.0, replay: true) })) }
        for item in items.sorted(by: { ($0.0, $0.1) < ($1.0, $1.1) }) { item.2() }
        // State.
        intent = f.intent
        status = f.status
        gpuMemory = f.gpuMemory
        session = f.session
        // Telemetry through the same averaging as live samples.
        powerSamples = f.powerSamples
        speed = status == .mining ? f.speed : nil
        lastSpeed = f.session == nil ? nil : f.speed
        refreshReadout()
        historyRevision += 1
    }

    /// Interactive --demo: a 2-s timer random-walks the speed and fires shares
    /// and cycles through the real event path. Nothing real is touched.
    private func startDemoDriver() {
        guard isDemo, demoDriver == nil else { return }
        demoNextShare = Date().addingTimeInterval(8)
        demoNextCycle = Date().addingTimeInterval(4)
        demoDriver = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.demoTick() }
        }
    }

    private func demoTick() {
        let t = Date()
        now = t
        guard status == .mining, let full = demoFixture?.speed else {
            historyRevision += 1
            return
        }
        let base = full * duty
        let current = speed ?? base
        let step = 1 + (demoRandom.nextUnit() - 0.5) * 0.06
        let next = min(base * 1.15, max(base * 0.85, current * step))
        speed = next
        lastSpeed = next
        demoGraphs += next * Self.tickInterval
        if var s = session {
            s.miningSeconds += Self.tickInterval
            s.graphs += Int(demoGraphs)
            demoGraphs -= Double(Int(demoGraphs))
            session = s
        }
        historyStore.record(HistorySample(time: t, speed: next))
        let target = session?.job?.difficulty ?? 48
        if t >= demoNextCycle {
            demoNextCycle = t.addingTimeInterval(6 + demoRandom.nextUnit() * 4)
            apply(.share(difficulty: 1 + UInt64(demoRandom.nextUnit() * Double(target - 1)), target: target, submitted: false),
                  at: t, replay: false)
        }
        if t >= demoNextShare {
            demoNextShare = t.addingTimeInterval(20 + demoRandom.nextUnit() * 10)
            let d = target + UInt64(demoRandom.nextUnit() * Double(target * 3))
            apply(.share(difficulty: d, target: target, submitted: true), at: t, replay: false)
            apply(.pool(.shareResult(accepted: true, error: nil)), at: t.addingTimeInterval(0.2), replay: false)
            session?.accepted += 1
        }
        refreshReadout()
        historyRevision += 1
    }

    /// Demo Start: preparing 1 s, connecting 0.5 s, then mining.
    private func simulateRun() {
        status = .preparingGPU
        gpuMemory = .reserving(hardware.solverBytes)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, self.intent == .mining else { return }
            self.status = .connecting(trouble: nil)
            self.gpuMemory = .inUse(self.hardware.solverBytes)
            try? await Task.sleep(for: .seconds(0.5))
            guard self.intent == .mining, case .connecting = self.status else { return }
            self.status = .mining
            self.speed = nil
            self.log(.connected, "Connected to the pool", at: Date())
            self.log(.loggedIn, "Logged in", at: Date())
        }
    }

    private func simulateStop() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.5))
            guard let self, self.status == .stopping else { return }
            self.status = .stopped
            self.gpuMemory = .released
            self.log(.memoryReleased, "Released \(Format.bytes(self.hardware.solverBytes)) of GPU memory", at: Date())
            self.finishSession()
        }
    }
}

/// Deterministic randomness for the demo.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// 0..<1
    mutating func nextUnit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

extension String {
    /// A hash that is the same on every run (String.hashValue is seeded per process).
    var hashValueStable: UInt64 {
        var h: UInt64 = 1469598103934665603
        for b in utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return h
    }
}
