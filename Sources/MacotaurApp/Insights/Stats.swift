import Foundation

struct TodayStats: Codable, Equatable, Sendable {
    var day: String                          // yyyy-MM-dd, local
    var accepted = 0, rejected = 0
    var expected = 0.0                       // shares, from the graphs solved
    init(day: String) { self.day = day }

    /// The local day key, "2026-10-09".
    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

/// Today's shares, the last payout seen per wallet and the last session's
/// speed. Persists to stats-v1.json; a nil URL keeps it in memory. Files from
/// older versions carry more fields, which are ignored.
final class StatsStore: @unchecked Sendable {
    struct SessionRecord: Codable, Equatable { var averageSpeed: Double }
    struct Persisted: Codable {
        var version = 1
        var today: TodayStats
        var lastPaid: [String: Double]
        var lastSession: SessionRecord?
        var lastPayoutAmount: Double?
        var lastPayoutDate: Date?
    }

    private let url: URL?
    private let lock = NSLock()
    private var calendar: Calendar
    private var _today: TodayStats
    private var paid: [String: Double] = [:]
    private var session: SessionRecord?
    private var payoutAmount: Double?
    private var payoutDate: Date?

    init(url: URL?, now: Date, calendar: Calendar = .current) {
        self.url = url
        self.calendar = calendar
        _today = TodayStats(day: TodayStats.dayKey(now, calendar: calendar))
        if let url, let data = try? Data(contentsOf: url) {
            let d = JSONDecoder()
            d.dateDecodingStrategy = .secondsSince1970
            if let p = try? d.decode(Persisted.self, from: data), p.version == 1 {
                _today = p.today
                paid = p.lastPaid
                session = p.lastSession
                payoutAmount = p.lastPayoutAmount
                payoutDate = p.lastPayoutDate
            }
        }
        rollOver(now: now)
    }

    var today: TodayStats { lock.withLock { _today } }

    /// Starts a new day at local midnight.
    func rollOver(now: Date) {
        lock.withLock { rollOverLocked(now) }
    }

    private func rollOverLocked(_ now: Date) {
        let key = TodayStats.dayKey(now, calendar: calendar)
        if _today.day != key { _today = TodayStats(day: key) }
    }

    func addExpected(_ shares: Double, now: Date) {
        lock.withLock {
            rollOverLocked(now)
            _today.expected += shares
        }
    }

    func addShare(accepted: Bool, now: Date) {
        lock.withLock {
            rollOverLocked(now)
            if accepted { _today.accepted += 1 } else { _today.rejected += 1 }
        }
    }

    func lastPaid(walletKey: String) -> Double? { lock.withLock { paid[walletKey] } }

    func setLastPaid(_ v: Double, walletKey: String) { lock.withLock { paid[walletKey] = v } }

    /// The last session's average speed.
    var lastSessionSpeed: Double? {
        get { lock.withLock { session?.averageSpeed } }
        set { lock.withLock { session = newValue.map(SessionRecord.init) } }
    }

    /// The most recent payout seen.
    var lastPayout: (amount: Double, date: Date)? {
        get { lock.withLock { payoutAmount.flatMap { a in payoutDate.map { (a, $0) } } } }
        set { lock.withLock { payoutAmount = newValue?.amount; payoutDate = newValue?.date } }
    }

    /// Replace today's totals (demo fixtures).
    func load(today: TodayStats) {
        lock.withLock { _today = today }
    }

    func save() throws {
        guard let url else { return }
        let p = lock.withLock {
            Persisted(today: _today, lastPaid: paid, lastSession: session,
                      lastPayoutAmount: payoutAmount, lastPayoutDate: payoutDate)
        }
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        let data = try e.encode(p)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
