import Foundation
import Testing
@testable import MacotaurApp

// MARK: Payout

@Test func payoutStates() {
    #expect(PayoutMath.state(total: 126.4, confirmed: 122.3, threshold: 200, maturation: 21600) == .progress)
    #expect(PayoutMath.state(total: 203, confirmed: 198.9, threshold: 200, maturation: 21600) == .dueSoon(maturesIn: 21600))
    #expect(PayoutMath.state(total: 205, confirmed: 201, threshold: 200, maturation: nil) == .due)
    #expect(PayoutMath.eta(remaining: 73.6, xtmPerDay: 0) == nil)
    #expect(PayoutMath.eta(remaining: 73.6, xtmPerDay: -1) == nil)
    let eta = PayoutMath.eta(remaining: 100, xtmPerDay: 400)!
    #expect(abs(eta - 21600) < 1e-6)
}

@Test func etaLadderBoundaries() {
    let h = 3600.0, d = 86400.0
    #expect(EtaFormat.long(59 * 60) == "less than an hour")
    #expect(EtaFormat.long(h) == "about 1 hour")
    #expect(EtaFormat.long(7 * h) == "about 7 hours")
    #expect(EtaFormat.long(19.9 * h) == "about 20 hours")
    #expect(EtaFormat.long(20 * h) == "about a day")
    #expect(EtaFormat.long(35.9 * h) == "about a day")
    #expect(EtaFormat.long(36 * h) == "about 2 days")
    #expect(EtaFormat.long(13.9 * d) == "about 14 days")
    #expect(EtaFormat.long(14 * d) == "about 2 weeks")
    #expect(EtaFormat.long(55 * d) == "about 8 weeks")
    #expect(EtaFormat.long(56 * d) == "about 2 months")
    #expect(EtaFormat.long(364 * d) == "about 12 months")
    #expect(EtaFormat.long(365 * d) == "more than a year")
    #expect(EtaFormat.short(30 * 60) == "< 1 hour")
    #expect(EtaFormat.short(7 * h) == "≈ 7 hours")
    #expect(EtaFormat.short(h) == "≈ 1 hour")
    #expect(EtaFormat.short(30 * h) == "≈ 1 day")
    #expect(EtaFormat.short(3 * d) == "≈ 3 days")
    #expect(EtaFormat.short(15 * d) == "≈ 2 weeks")
    #expect(EtaFormat.short(120 * d) == "≈ 4 months")
    #expect(EtaFormat.short(400 * d) == "> 1 year")
}

@Test func kryptexEstimates() {
    let pool = KryptexAPI.PoolInfo(netHashrate: 40_000, blockReward: 8_600, blockTime: 240, fee: 0.01, minpay: 200, height: 361_365)
    let snap = KryptexAPI.Snapshot(pool: pool)
    // ≈ 76.6 XTM a day per graph/s after the 1% fee
    #expect(abs(snap.expectedXTMPerDay(graphsPerSecond: 1)! - 76.63) < 0.01)
    #expect(abs(snap.networkXTMPerDay(graphsPerSecond: 1)! - 77.4) < 0.01)
    #expect(KryptexAPI.Snapshot().expectedXTMPerDay(graphsPerSecond: 1) == nil)
}

// MARK: Speed

@Test func speedMeterMeasuresThenTracks() {
    var m = SpeedMeter()
    let t0 = Date(timeIntervalSinceReferenceDate: 0)
    // 2 graphs/s, sampled every 2 s.
    for i in 0...4 { m.record(graphs: i * 4, miningSeconds: Double(i * 2), at: t0.addingTimeInterval(Double(i * 2))) }
    #expect(m.speed() == nil)                      // < 10 s
    for i in 5...60 { m.record(graphs: i * 4, miningSeconds: Double(i * 2), at: t0.addingTimeInterval(Double(i * 2))) }
    #expect(abs(m.speed()! - 2) < 1e-9)
    // A new Miner (counters restart) measures again.
    m.record(graphs: 1, miningSeconds: 1, at: t0.addingTimeInterval(200))
    #expect(m.speed() == nil)
}

@Test func speedMeterSlowMac() {
    var m = SpeedMeter()
    let t0 = Date(timeIntervalSinceReferenceDate: 0)
    // 0.5 graphs/s: needs 5 graphs (10 s) before reporting.
    for i in 0...100 { m.record(graphs: i, miningSeconds: Double(i * 2), at: t0.addingTimeInterval(Double(i * 2))) }
    #expect(abs(m.speed()! - 0.5) < 0.01)
}

// MARK: History

@Test func historyPaceCountsStops() {
    let store = HistoryStore(url: nil)
    let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    // 24 hours of 2-s samples at 2 graphs/s, with a stop from hour 10 to 12.
    var t = start
    let end = start.addingTimeInterval(86400)
    while t < end {
        let h = t.timeIntervalSince(start) / 3600
        if !(h >= 10 && h < 12) { store.record(HistorySample(time: t, speed: 2)) }
        t.addTimeInterval(2)
    }
    // Recent pace counts the 2-hour stop as zero.
    let pace = store.recentPace(now: end)!
    #expect(abs(pace - 2 * 22 / 24) < 0.02)
    #expect(abs(store.meanSpeed(over: 600, now: end)! - 2) < 1e-9)
    #expect((590...600).contains(store.miningSeconds(over: 600, now: end)))
}

// A one-minute try hours ago is no pace to project a payout from.
@Test func recentPaceNeedsTwoHoursRecorded() {
    let store = HistoryStore(url: nil)
    let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let t1 = t0.addingTimeInterval(3 * 3600)
    for i in 0..<30 { store.record(HistorySample(time: t0.addingTimeInterval(Double(i * 2)), speed: 5)) }
    for i in 0..<300 { store.record(HistorySample(time: t1.addingTimeInterval(Double(i * 2)), speed: 5)) }
    #expect(store.recentPace(now: t1.addingTimeInterval(600)) == nil)
}

// Time with the pool out of reach is recorded, but not as mining.
@Test func historyOfflineTimeIsNotMining() {
    let store = HistoryStore(url: nil)
    let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    func record(_ ticks: Range<Int>, speed: Double?) {
        for i in ticks { store.record(HistorySample(time: t0.addingTimeInterval(Double(i * 2)), speed: speed)) }
    }
    record(0..<200, speed: 1.5)
    record(200..<300, speed: nil)
    // The last minute had no mining; the last 15 had 400 s of it.
    var now = t0.addingTimeInterval(598)
    #expect(store.miningSeconds(over: 60, now: now) == 0 && store.meanSpeed(over: 60, now: now) == nil)
    #expect(abs(store.miningSeconds(over: 900, now: now) - 400) < 1e-9)
    record(300..<450, speed: 1.5)
    now = t0.addingTimeInterval(898)
    #expect(abs(store.meanSpeed(over: 900, now: now)! - 1.5) < 1e-9)
    #expect(abs(store.miningSeconds(over: 900, now: now) - 700) < 1e-9)
}

@Test func historyPersistsTheDay() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "macotaur-history-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let a = HistoryStore(url: url)
    for i in 0..<4500 { a.record(HistorySample(time: t0.addingTimeInterval(Double(i * 2)), speed: 3)) }
    try a.save()
    let b = HistoryStore(url: url)
    let now = t0.addingTimeInterval(9000)
    #expect(abs(b.recentPace(now: now)! - 3) < 0.01)
    #expect(b.meanSpeed(over: 900, now: now) == nil)          // raw ticks aren't persisted
}

// A history file from a version that drew a chart (and, before that, could
// pause mining) still loads: its extra fields are ignored.
@Test func historyReadsAnOlderFile() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "macotaur-history-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let t0 = 1_790_000_040.0
    func bucket(_ i: Int, mining: Double, paused: Double) -> String {
        let start = t0 + Double(i) * 120
        let speeds = mining > 0 ? #","minSpeed":2.9,"maxSpeed":3.1"# : ""
        return #"{"start":\#(start),"duration":120,"first":\#(start),"last":\#(start + 118),"weight":120,"mining":\#(mining),"#
            + #""paused":\#(paused),"offline":0,"speedWeight":\#(mining),"speedSum":\#(mining * 3)\#(speeds),"maxThermal":0,"#
            + #""levels":{"full":\#(mining)},"wattsSum":0,"wattsWeight":0,"titles":{"On battery power":\#(paused)}}"#
    }
    // Three hours, the third half hour of them paused.
    let buckets = (0..<90).map { i in (30..<45).contains(i) ? bucket(i, mining: 0, paused: 120) : bucket(i, mining: 120, paused: 0) }
    let share = #"{"id":"\#(UUID().uuidString)","time":\#(t0 + 60),"difficulty":84,"target":20,"result":"accepted","y":0}"#
    let rate = #"{"time":\#(t0 + 60),"rate":2.9,"matched":true}"#
    let old = #"{"version":1,"buckets":[\#(buckets.joined(separator: ","))],"shares":[\#(share)],"pool":[\#(rate)]}"#
    try Data(old.utf8).write(to: url)

    let now = Date(timeIntervalSince1970: t0 + 10800)
    let store = HistoryStore(url: url)
    #expect(abs(store.recentPace(now: now)! - 2.5) < 0.01)
    // Saving drops the old fields and keeps the rest.
    try store.save()
    let saved = try String(contentsOf: url, encoding: .utf8)
    for gone in ["paused", "titles", "levels", "maxThermal", "shares", "pool"] { #expect(!saved.contains(gone), "\(gone)") }
    #expect(abs(HistoryStore(url: url).recentPace(now: now)! - 2.5) < 0.01)
}

// A file that isn't a history at all reads as an empty one.
@Test func historyIgnoresAnUnreadableFile() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "macotaur-history-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    for junk in ["", "not json", #"{"version":2,"buckets":[]}"#, #"{"version":1,"buckets":[{"start":0}]}"#] {
        try Data(junk.utf8).write(to: url)
        let store = HistoryStore(url: url)
        #expect(store.recentPace(now: Date()) == nil)
        store.record(HistorySample(time: Date(), speed: 2))
        #expect(store.meanSpeed(over: 60, now: Date()) == 2)
    }
}

// MARK: Activity

@Test func activityCollapsing() {
    var log = ActivityLog()
    let t0 = Date(timeIntervalSinceReferenceDate: 0)
    log.append(.connected, "Connected to the pool", at: t0)
    for i in 0..<7 { log.appendJob(height: 361_365 + UInt64(i), difficulty: 20, at: t0.addingTimeInterval(Double(i))) }
    #expect(log.entries.count == 2)
    #expect(log.entries[1].count == 7)
    #expect(log.entries[1].text.hasPrefix("7 new jobs · heights "))
    #expect(log.entries[1].text.hasSuffix("· difficulty 20"))
    #expect(log.entries[1].time == t0.addingTimeInterval(6))
    log.appendJob(height: 361_372, difficulty: 24, at: t0.addingTimeInterval(7))
    #expect(log.entries[1].text.hasSuffix("· difficulty 20–24"))

    log.appendCycle(difficulty: 7, target: 20, at: t0.addingTimeInterval(10))
    #expect(log.entries.last?.text == "42-cycle · difficulty 7 (needs 20)")
    log.appendCycle(difficulty: 9, target: 20, at: t0.addingTimeInterval(11))
    log.appendCycle(difficulty: 3, target: 20, at: t0.addingTimeInterval(12))
    #expect(log.entries.last?.text == "3 cycles below share difficulty · best 9 (needs 20)")
    #expect(log.entries.count == 3)

    // A different kind in between starts a new run.
    log.append(.shareAccepted, "Share accepted · difficulty 84 (needs 20)", at: t0.addingTimeInterval(13))
    log.appendCycle(difficulty: 5, target: 20, at: t0.addingTimeInterval(14))
    #expect(log.entries.count == 5 && log.entries.last?.count == 1)

    // Identical disconnects within 2 minutes merge, across reconnects.
    log.appendDisconnect(reason: "connection failed", retryDelay: 5, at: t0.addingTimeInterval(20))
    #expect(log.entries.last?.text == "Disconnected · connection failed. Reconnecting in 5 s")
    log.append(.connected, "Connected to the pool", at: t0.addingTimeInterval(25))
    log.appendDisconnect(reason: "connection failed", retryDelay: 5, at: t0.addingTimeInterval(26))
    #expect(log.entries.last?.text == "Disconnected 2 times · connection failed")
    #expect(log.entries.filter { $0.kind == .disconnected }.count == 1)
    log.appendDisconnect(reason: "connection failed", retryDelay: 5, at: t0.addingTimeInterval(400))
    #expect(log.entries.filter { $0.kind == .disconnected }.count == 2)
    log.appendDisconnect(reason: "pool closed the connection", retryDelay: 5, at: t0.addingTimeInterval(401))
    #expect(log.entries.filter { $0.kind == .disconnected }.count == 3)
}

@Test func activityUpdateKeepsTheEntry() {
    var log = ActivityLog()
    let t = Date(timeIntervalSinceReferenceDate: 0)
    let id = log.append(.shareSubmitted, "Found a share · difficulty 84 (needs 20)", at: t)
    log.update(id: id, kind: .shareAccepted, text: "Share accepted · difficulty 84 (needs 20)")
    #expect(log.entries.count == 1 && log.entries[0].kind == .shareAccepted && log.entries[0].time == t)
    #expect(!log.entries[0].kind.isProblem && ActivityKind.shareRejected.isProblem)
}

// MARK: Stats

@Test func statsRollOverAndPersist() throws {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let t0 = cal.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 23, minute: 50))!
    let url = FileManager.default.temporaryDirectory.appending(path: "macotaur-stats-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let s = StatsStore(url: url, now: t0, calendar: cal)
    s.addExpected(0.1, now: t0)
    s.addShare(accepted: true, now: t0)
    s.addShare(accepted: false, now: t0)
    #expect(s.today.day == "2026-10-09" && s.today.accepted == 1 && s.today.rejected == 1 && s.today.expected == 0.1)
    s.addShare(accepted: true, now: t0.addingTimeInterval(900))
    #expect(s.today.day == "2026-10-10" && s.today.accepted == 1 && s.today.expected == 0)
    s.setLastPaid(400, walletKey: "abcd1234")
    s.lastSessionSpeed = 5.18
    s.lastPayout = (201.5, t0)
    try s.save()
    let r = StatsStore(url: url, now: t0.addingTimeInterval(1000), calendar: cal)
    #expect(r.lastPaid(walletKey: "abcd1234") == 400)
    #expect(r.lastSessionSpeed == 5.18 && r.lastPayout?.amount == 201.5)
    #expect(r.today.day == "2026-10-10" && r.today.accepted == 1)
}

// A stats file from a version that kept more totals (per-day and lifetime
// counts, the speed at each power mode) still loads.
@Test func statsReadsAnOlderFile() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "macotaur-stats-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let old = #"{"version":1,"today":{"day":"2026-10-09","accepted":7,"rejected":1,"stale":2,"graphs":900,"cycles":21,"expected":6.5,"miningSeconds":400,"energyWh":1.5,"bestDifficulty":310},"lifetime":{"graphs":5000,"cycles":119,"accepted":40,"rejected":2,"stale":3,"miningSeconds":9000,"energyWh":30,"bestDifficulty":900},"modes":{"2026-10-09":{"full":{"seconds":1200,"graphs":2400,"joules":3600,"joulesSeconds":1200,"joulesGraphs":2400}}},"lastPaid":{"abcd1234":400},"lastSession":{"averageSpeed":2.1,"duration":3600,"endedAt":781000000,"accepted":9}}"#
    try Data(old.utf8).write(to: url)
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 12))!
    let s = StatsStore(url: url, now: now, calendar: cal)
    #expect(s.today.accepted == 7 && s.today.rejected == 1 && s.today.expected == 6.5)
    #expect(s.lastPaid(walletKey: "abcd1234") == 400 && s.lastSessionSpeed == 2.1)
    // Saving drops the old fields and keeps the rest.
    try s.save()
    let saved = try String(contentsOf: url, encoding: .utf8)
    for gone in ["modes", "lifetime", "energyWh"] { #expect(!saved.contains(gone), "\(gone)") }
    let r = StatsStore(url: url, now: now, calendar: cal)
    #expect(r.today.accepted == 7 && r.lastPaid(walletKey: "abcd1234") == 400 && r.lastSessionSpeed == 2.1)
}

// MARK: Telemetry (this Mac)

@Test func powerMonitorDegradesGracefully() {
    let m = PowerMonitor()
    let caps = m.capabilities
    let s = m.sample()
    // Whatever this Mac has, readings are either nil or sane.
    if let w = s.gpuWatts { #expect(w >= 0 && w < 2000) }
    if let b = s.gpuBusy { #expect(b >= 0 && b <= 1) }
    if let mhz = s.gpuMHz { #expect(caps.contains(.gpuClock) && mhz > 0 && mhz < 4000) }
    if let w = s.systemWatts { #expect(w >= 0 && w < 2000) }
    if s.fanCount == nil || s.fanCount == 0 { #expect(s.fanRPM.isEmpty) }
    #expect(!m.debugDescription.isEmpty)
}
