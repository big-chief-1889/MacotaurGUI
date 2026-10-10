import Foundation
import MacotaurCore

// Demo data: plausible inputs for five kinds of Mac. The demo injects inputs
// only (hardware, history, telemetry, stats, raw events, status, settings);
// everything derived (earnings figures, activity collapsing) comes from the
// real code.
// Randomness is a SplitMix64 seeded by the profile name, so it's deterministic.

enum DemoProfile: String, CaseIterable, Sendable { case air, pro, mini, studio, m1 }

enum DemoState: String, CaseIterable, Sendable {
    case mining, stopped, firstRun, failed, luckyPool, preparing, reconnecting
}

struct DemoScenario {
    var profile: DemoProfile
    var state: DemoState
    var now: Date

    /// 2026-10-09 14:31:00 local.
    static let fixedNow: Date = {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 14, minute: 31)) ?? Date()
    }()

    init(profile: DemoProfile, state: DemoState, now: Date = DemoScenario.fixedNow) {
        self.profile = profile; self.state = state; self.now = now
    }

    static func `default`(_ p: DemoProfile) -> DemoScenario {
        DemoScenario(profile: p, state: .mining)
    }

    /// Interactive --demo: the same story, ending at the real time.
    static func interactive(_ p: DemoProfile) -> DemoScenario {
        var s = Self.default(p)
        let t = Date()
        s.now = Date(timeIntervalSinceReferenceDate: (t.timeIntervalSinceReferenceDate / 2).rounded(.down) * 2)
        return s
    }
}

struct DemoFixture {
    var hardware: HardwareProfile
    var settings: @MainActor (MiningModel) -> Void  // wallet, worker, pool, ui
    var kryptex: KryptexAPI.Snapshot
    var samples: [HistorySample]
    var powerSamples: [PowerSample]                 // fed through the same averaging as live telemetry
    var thermal: ProcessInfo.ThermalState
    var today: TodayStats
    var lastSessionSpeed: Double?
    var events: [(Date, Miner.Event)]               // replayed through the real activity/FIFO code
    var status: MiningModel.Status
    var intent: MiningModel.Intent
    var gpuMemory: GPUMemoryState
    var session: SessionStats?
    var logLines: [(Date, ActivityKind, String)]    // model-level activity (started, released…)
    var speed: Double?                              // the live speed now
}

enum DemoData {
    /// What the profile's Mac looks like and does.
    struct Spec {
        var chip: String, cores: Int, memoryGB: UInt64, limitGB: Double
        var speed: Double                           // steady g/s
        var coolSpeed: Double                       // at the start of a run, before any throttling (== speed if none)
        var mhz: Double?, gpuW: Double?             // nil: this Mac reports none
        var difficulty: UInt64
        var worker: String
        var region: MiningModel.KryptexRegion
    }

    static func spec(_ p: DemoProfile) -> Spec {
        switch p {
        case .air:
            Spec(chip: "Apple M5", cores: 10, memoryGB: 24, limitGB: 18, speed: 1.92, coolSpeed: 2.8,
                 mhz: 884, gpuW: 3.1, difficulty: 20, worker: "macbook", region: .global)
        case .pro:
            Spec(chip: "Apple M4 Pro", cores: 20, memoryGB: 48, limitGB: 36, speed: 5.21, coolSpeed: 5.21,
                 mhz: 1296, gpuW: 14.0, difficulty: 48, worker: "macbook", region: .europe)
        case .mini:
            Spec(chip: "Apple M4", cores: 10, memoryGB: 16, limitGB: 10.7, speed: 2.62, coolSpeed: 2.62,
                 mhz: 1450, gpuW: 7.5, difficulty: 24, worker: "mini", region: .global)
        case .studio:
            Spec(chip: "Apple M3 Ultra", cores: 80, memoryGB: 192, limitGB: 144, speed: 16.2, coolSpeed: 16.2,
                 mhz: 1338, gpuW: 58, difficulty: 160, worker: "studio", region: .global)
        case .m1:
            Spec(chip: "Apple M1", cores: 7, memoryGB: 8, limitGB: 5.0, speed: 0.58, coolSpeed: 0.58,
                 mhz: nil, gpuW: nil, difficulty: 20, worker: "m1", region: .global)
        }
    }

    static func hardware(_ p: DemoProfile) -> HardwareProfile {
        let s = spec(p)
        let memory = s.memoryGB << 30, limit = UInt64(s.limitGB * Double(1 << 30))
        // The solver's own choice for a Mac this size (low-memory mode on 8 GB).
        let splits = MetalSolver.automaticSeedSplits(physicalMemory: memory, recommendedWorkingSet: limit)
        return HardwareProfile(chipName: s.chip, gpuCores: s.cores,
                               solverBytes: UInt64(MetalSolver.memoryPlan(seedSplits: splits, gpuCores: s.cores).gpuMemoryBytes))
    }

    /// A made-up address that passes the format check (not anyone's wallet).
    static func demoWallet(_ seed: String) -> String {
        var rng = SplitMix64(seed: seed.hashValueStable)
        let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
        return "12" + String((0..<89).map { _ in alphabet[Int(rng.next() % UInt64(alphabet.count))] })
    }

    // MARK: Timeline

    /// One stretch of the last 24 hours: mining, or mining with the pool out of reach.
    struct Span {
        var from: Date, to: Date
        var offline = false
    }

    /// The day's story per profile, in local clock times relative to `now`
    /// (14:31 in snapshots). `hot` and `warm` give thermal spans.
    struct Story {
        var spans: [Span]
        var warm: [Range<Date>] = []
        var hot: [Range<Date>] = []
        var sessionStart: Date?
        /// Runs whose speed starts at `coolSpeed` and decays (a Mac that throttles).
        var throttles = false

        func thermal(at t: Date) -> ProcessInfo.ThermalState {
            hot.contains { $0.contains(t) } ? .serious : warm.contains { $0.contains(t) } ? .fair : .nominal
        }
    }

    static func story(_ sc: DemoScenario) -> Story {
        let now = sc.now
        // A clock time today (or yesterday with day -1), kept at the same
        // distance from `now` as from 14:31 in the fixed story.
        func at(_ h: Int, _ m: Int, day: Int = 0) -> Date {
            now.addingTimeInterval(Double((day * 1440 + h * 60 + m) - (14 * 60 + 31)) * 60)
        }
        switch sc.profile {
        case .air:
            return Story(spans: [Span(from: at(19, 0, day: -1), to: at(1, 0))] + current(sc, from: at(8, 5)),
                         warm: [at(19, 20, day: -1)..<at(1, 0), at(8, 40)..<at(9, 30), at(10, 10)..<at(11, 10),
                                at(11, 50)..<at(14, 20), at(14, 26)..<now.addingTimeInterval(1)],
                         hot: [at(9, 30)..<at(10, 10), at(14, 20)..<at(14, 26)],
                         sessionStart: at(8, 5), throttles: true)
        case .pro:
            return Story(spans: [Span(from: at(14, 31, day: -1), to: at(0, 30)), Span(from: at(8, 0), to: at(12, 10))]
                            + current(sc, from: at(12, 17)),
                         warm: [at(10, 0)..<at(10, 42), at(14, 18)..<at(14, 24)], sessionStart: at(12, 17))
        case .mini:
            return Story(spans: [Span(from: at(18, 0, day: -1), to: at(23, 40, day: -1))] + current(sc, from: at(9, 12)),
                         sessionStart: at(9, 12))
        case .studio:
            return Story(spans: [Span(from: at(14, 31, day: -1), to: at(23, 0, day: -1))] + current(sc, from: at(6, 0)),
                         sessionStart: at(6, 0))
        case .m1:
            return Story(spans: [Span(from: at(20, 0, day: -1), to: at(23, 30, day: -1))] + current(sc, from: at(12, 30)),
                         sessionStart: at(12, 30))
        }
    }

    /// The current session's last stretch, by state.
    static func current(_ sc: DemoScenario, from: Date) -> [Span] {
        let now = sc.now.addingTimeInterval(1)
        switch sc.state {
        case .mining, .luckyPool:
            return [Span(from: from, to: now)]
        case .reconnecting:
            return [Span(from: from, to: sc.now.addingTimeInterval(-40)),
                    Span(from: sc.now.addingTimeInterval(-40), to: now, offline: true)]
        case .stopped, .failed:
            // Stopped at 12:10 (relative): the last session's end.
            let end = sc.now.addingTimeInterval(-(2 * 3600 + 21 * 60))
            return from < end ? [Span(from: from, to: end)] : []
        case .preparing, .firstRun:
            return []
        }
    }

    // MARK: Fixture

    static func fixture(_ sc: DemoScenario) -> DemoFixture {
        let p = sc.profile
        let s = spec(p)
        let now = sc.now
        var rng = SplitMix64(seed: (p.rawValue + sc.state.rawValue).hashValueStable)
        let hw = hardware(p)
        let firstRun = sc.state == .firstRun
        let st = story(sc)
        let wallet = demoWallet(p.rawValue)
        let poolHost = s.region.host

        // History samples every 2 s, and the shares found along the way.
        var samples: [HistorySample] = []
        var accepted: [Date] = []
        var noise = 0.0
        var sessionGraphs = 0.0, sessionMining = 0.0
        var todayExpected = 0.0
        let dayStart = Calendar.current.startOfDay(for: now)
        // Stopped and failed sessions ended at 12:10 (relative).
        let cutoff = sc.state == .stopped || sc.state == .failed ? now.addingTimeInterval(-(2 * 3600 + 21 * 60)) : now
        if !firstRun {
            for span in st.spans {
                var t = span.from
                while t < span.to && t <= cutoff {
                    if span.offline {
                        samples.append(HistorySample(time: t, speed: nil))
                    } else {
                        // Throttling Macs start fast and settle as they warm up.
                        let decay = st.throttles ? exp(-t.timeIntervalSince(span.from) / 900) : 0
                        noise = noise * 0.9 + (rng.nextUnit() - 0.5) * 0.02
                        let v = max(0.05, (s.speed + (s.coolSpeed - s.speed) * decay) * (1 + noise))
                        samples.append(HistorySample(time: t, speed: v))
                        let expected = v * 2 / 42 / Double(s.difficulty)
                        if rng.nextUnit() < expected * 1.08 { accepted.append(t) }
                        if let start = st.sessionStart, t >= start, sc.state != .stopped, sc.state != .failed {
                            sessionGraphs += v * 2; sessionMining += 2
                        }
                        if t >= dayStart { todayExpected += expected }
                    }
                    t.addTimeInterval(2)
                }
            }
        }
        let lastMined = samples.last { $0.speed != nil }
        // One rejected share in the session.
        var rejected: Date?
        if let start = st.sessionStart, let last = lastMined, last.time > start { rejected = last.time.addingTimeInterval(-1500) }

        // Kryptex with a balance, or pool figures only (no wallet yet, or another pool).
        let pool = KryptexAPI.PoolInfo(netHashrate: 40_000, blockReward: 8_600, blockTime: 240, fee: 0.01, minpay: 200)
        var kryptex = KryptexAPI.Snapshot(pool: pool, usdPerXTM: 0.0017, fetchedAt: now.addingTimeInterval(-60))
        if !firstRun && sc.state != .luckyPool {
            kryptex.balance = .init(total: 126.4, unconfirmed: 4.1, confirmed: 122.3, threshold: 200, maturationTime: 21600)
            kryptex.payouts = .init(paid: 400)
        }

        // Telemetry: the last 20 seconds at this profile's readings.
        var power: [PowerSample] = []
        let running = [.mining, .luckyPool, .reconnecting].contains(sc.state)
        for k in 0..<10 {
            var sample = PowerSample(time: now.addingTimeInterval(Double(k - 9) * 2), interval: 2)
            if running {
                sample.gpuWatts = s.gpuW.map { $0 * (1 + (rng.nextUnit() - 0.5) * 0.02) }
                sample.gpuMHz = s.mhz
            }
            power.append(sample)
        }

        var today = TodayStats(day: TodayStats.dayKey(now))
        if !firstRun {
            today.accepted = accepted.filter { $0 >= dayStart }.count
            today.rejected = rejected.map { $0 >= dayStart ? 1 : 0 } ?? 0
            today.expected = todayExpected
        }

        // Status, session and GPU memory by state.
        var status: MiningModel.Status = .mining
        var intent: MiningModel.Intent = .mining
        var gpu: GPUMemoryState = .inUse(hw.solverBytes)
        var lastSessionSpeed: Double?
        switch sc.state {
        case .mining, .luckyPool: break
        case .stopped:
            status = .stopped; intent = .stopped; gpu = .released
            lastSessionSpeed = s.speed * 0.99
        case .firstRun:
            status = .stopped; intent = .stopped; gpu = .released
        case .failed:
            status = .failed(.memory(bytes: hw.solverBytes)); intent = .stopped; gpu = .released
        case .preparing:
            status = .preparingGPU; gpu = .reserving(hw.solverBytes)
        case .reconnecting:
            status = .reconnecting
        }

        let job = Stratum.Job(id: "demo", miningHash: Array(repeating: 0, count: 32), difficulty: s.difficulty, height: 361_365)
        var session: SessionStats?
        let sessionStart: Date? = switch sc.state {
        case .preparing: now.addingTimeInterval(-2)
        case .stopped, .failed, .firstRun: nil
        default: st.sessionStart
        }
        if sc.state == .preparing {
            session = SessionStats(startedAt: now.addingTimeInterval(-2))   // nothing counted yet
        } else if let start = sessionStart {
            session = SessionStats(startedAt: start, miningSeconds: sessionMining,
                                   graphs: Int(sessionGraphs), accepted: accepted.filter { $0 >= start }.count,
                                   rejected: rejected.map { $0 >= start ? 1 : 0 } ?? 0, job: job)
        }

        // Activity: about 40 raw events and the model's own lines, in step
        // with the history above (events end where the session did).
        var lines: [(Date, ActivityKind, String)] = []
        var events: [(Date, Miner.Event)] = []
        let address = "\(poolHost):7040"
        let sizeText = Format.bytes(hw.solverBytes)
        func at(_ h: Int, _ m: Int) -> Date { now.addingTimeInterval(Double(h * 60 + m - (14 * 60 + 31)) * 60) }
        let stoppedAt = at(12, 10)
        func started(_ t: Date) {
            lines.append((t, .started, "Started mining on \(address) as \(s.worker)"))
            lines.append((t.addingTimeInterval(3), .gpuReady, "GPU ready: \(s.chip), \(s.cores)-core GPU · \(sizeText) reserved in 2.1 s"))
        }
        func stopped(_ t: Date) {
            lines.append((t, .stopped, "Stopped after 4 h 10 min · 58 accepted, 0 rejected"))
            lines.append((t.addingTimeInterval(1), .memoryReleased, "Released \(sizeText) of GPU memory"))
        }
        if !firstRun {
            // The session the script covers: the current one, or (stopped,
            // failed) the morning one that ended at 12:10.
            let ended = sc.state == .stopped || sc.state == .failed
            let scriptStart: Date? = ended ? (p == .pro ? at(8, 0) : st.sessionStart) : sc.state == .preparing ? nil : st.sessionStart
            let scriptEnd = ended ? stoppedAt : now
            if p == .pro {
                // The morning session, when this Mac got warm for a while.
                if !ended { started(at(8, 0)) }
                lines.append((at(10, 0), .thermal, "Heat: Warm"))
                lines.append((at(10, 42), .thermal, "Heat: Normal"))
                if !ended { stopped(stoppedAt) }
            }
            if p == .air {
                lines.append((at(9, 30), .thermal, "Heat: Hot"))
                lines.append((at(10, 10), .thermal, "Heat: Warm"))
                lines.append((at(14, 20), .thermal, "Heat: Hot"))
                lines.append((at(14, 26), .thermal, "Heat: Warm"))
            }
            if let ss = scriptStart, scriptEnd.timeIntervalSince(ss) > 600 {
                started(ss)
                events += script(start: ss.addingTimeInterval(4), now: scriptEnd, difficulty: s.difficulty, state: sc.state)
            }
            if ended { stopped(stoppedAt) }
            if sc.state == .failed {
                lines.append((now.addingTimeInterval(-60), .started, "Started mining on \(address) as \(s.worker)"))
                lines.append((now.addingTimeInterval(-57), .problem, "Couldn't start · Macotaur needs about \(sizeText) of GPU memory and macOS couldn't reserve it. Quit some apps and try again."))
            }
            if sc.state == .preparing {
                lines.append((now.addingTimeInterval(-2), .started, "Started mining on \(address) as \(s.worker)"))
            }
        }

        let liveSpeed: Double? = running || sc.state == .stopped ? lastMined?.speed : nil
        let settings: @MainActor (MiningModel) -> Void = { m in
            m.wallet = firstRun ? "" : wallet
            m.worker = s.worker
            m.preset = sc.state == .luckyPool ? .luckyPool : .kryptex
            m.kryptexRegion = s.region
            m.ui = UIState()
        }

        return DemoFixture(
            hardware: hw, settings: settings, kryptex: kryptex, samples: samples,
            powerSamples: power, thermal: samples.last.map { st.thermal(at: $0.time) } ?? .nominal,
            today: today, lastSessionSpeed: lastSessionSpeed,
            events: events, status: status, intent: intent, gpuMemory: gpu, session: session,
            logLines: lines, speed: liveSpeed)
    }

    /// About 40 raw pool and solver events across the session; collapsing
    /// turns them into a run of 7 new jobs, a run of 3 cycles, a rejected
    /// share and a disconnect.
    static func script(start: Date, now: Date, difficulty d: UInt64, state: DemoState) -> [(Date, Miner.Event)] {
        var ev: [(Date, Miner.Event)] = []
        var height: UInt64 = 361_350
        func job(_ t: Date) {
            ev.append((t, .pool(.newJob(Stratum.Job(id: "\(height)", miningHash: Array(repeating: 0, count: 32), difficulty: d, height: height)))))
            height += 1
        }
        func share(_ t: Date, _ diff: UInt64, ok: Bool = true, why: String? = nil) {
            ev.append((t, .share(difficulty: diff, target: d, submitted: true)))
            ev.append((t.addingTimeInterval(0.3), .pool(.shareResult(accepted: ok, error: why))))
        }
        let span = now.timeIntervalSince(start)
        func at(_ fraction: Double) -> Date { start.addingTimeInterval(span * fraction) }
        ev.append((start, .pool(.connected)))
        ev.append((start.addingTimeInterval(1), .pool(.loggedIn(session: "demo"))))
        job(start.addingTimeInterval(1))
        share(at(0.06), d * 7 / 4)
        ev.append((at(0.08), .share(difficulty: d / 3 + 1, target: d, submitted: false)))
        job(at(0.10))
        share(at(0.12), d * 3)
        share(at(0.30), d * 5 / 2)
        job(at(0.44))
        share(at(0.46), d + 4, ok: false, why: "Low difficulty share")
        ev.append((at(0.50), .pool(.disconnected("pool closed the connection"))))
        ev.append((at(0.50).addingTimeInterval(5), .pool(.connected)))
        ev.append((at(0.50).addingTimeInterval(6), .pool(.loggedIn(session: "demo"))))
        job(at(0.50).addingTimeInterval(6))
        share(at(0.55), d * 2)
        share(at(0.62), d * 9 / 2)
        ev.append((at(0.64), .stale(difficulty: d * 2, target: d)))
        share(at(0.68), d * 11 / 4)
        // Seven new jobs in a row, then three cycles below difficulty, then a share.
        let tail = min(span * 0.25, 32 * 60)
        let tailStart = now.addingTimeInterval(-tail)
        for k in 0..<7 { job(tailStart.addingTimeInterval(tail * 0.8 * Double(k) / 7)) }
        for (k, diff) in [d / 3 + 1, d / 2 - 1, d / 7 + 1].enumerated() {
            ev.append((now.addingTimeInterval(-tail * 0.18 + Double(k) * tail * 0.03), .share(difficulty: diff, target: d, submitted: false)))
        }
        if state == .reconnecting {
            ev.append((now.addingTimeInterval(-40), .pool(.disconnected("pool closed the connection"))))
            ev.append((now.addingTimeInterval(-35), .pool(.disconnected("pool closed the connection"))))
        } else {
            share(now.addingTimeInterval(-120), d * 7 / 4)
        }
        return ev.filter { $0.0 <= now }
    }
}
