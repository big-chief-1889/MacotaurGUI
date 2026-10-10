import Foundation

/// One tick of a mining session (2 s). `speed` is nil while it is still being
/// measured or the pool is out of reach. Stopped time records nothing.
struct HistorySample: Sendable {
    var time: Date
    var speed: Double?
}

/// Recent speed, behind the averages and estimates: raw 2-s ticks for 15
/// minutes and 2-minute totals for 24 hours. The totals persist
/// (history-v1.json); a nil URL keeps everything in memory. Files from older
/// versions carry more fields, which are ignored.
final class HistoryStore: @unchecked Sendable {
    struct Bucket: Codable, Sendable {
        var start: Date
        var first: Date
        var last: Date
        var weight = 0.0                            // seconds recorded
        var speedSum = 0.0                          // Σ speed · seconds
    }

    private struct Tick { var time: Date; var speed: Double?; var weight: Double }

    struct Persisted: Codable {
        var version = 1
        var buckets: [Bucket]
    }

    private let url: URL?
    private let lock = NSLock()
    private var ticks: [Tick] = []
    private var buckets: [Bucket] = []
    private var lastTime: Date?

    static let tick: TimeInterval = 2
    static let bucket: TimeInterval = 120

    /// nil = memory only (demo, tests, snapshot).
    init(url: URL?) {
        self.url = url
        guard let url, let data = try? Data(contentsOf: url) else { return }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        guard let p = try? d.decode(Persisted.self, from: data), p.version == 1 else { return }
        buckets = p.buckets
        lastTime = buckets.last?.last
    }

    func record(_ s: HistorySample) {
        lock.withLock {
            var w = Self.tick
            if let l = lastTime {
                let gap = s.time.timeIntervalSince(l)
                if gap > 0 && gap <= 5 { w = gap }
                if gap <= 0 { return }  // out of order
            }
            lastTime = s.time
            ticks.append(Tick(time: s.time, speed: s.speed, weight: w))
            // Prune in batches (a minute at a time) so recording stays O(1).
            if let f = ticks.first, s.time.timeIntervalSince(f.time) > 1020,
               let keep = ticks.firstIndex(where: { s.time.timeIntervalSince($0.time) <= 960 }) {
                ticks.removeFirst(keep)
            }

            let t = s.time.timeIntervalSinceReferenceDate
            let start = Date(timeIntervalSinceReferenceDate: (t / Self.bucket).rounded(.down) * Self.bucket)
            if buckets.last?.start != start { buckets.append(Bucket(start: start, first: s.time, last: s.time)) }
            let i = buckets.count - 1
            buckets[i].last = max(buckets[i].last, s.time)
            buckets[i].weight += w
            buckets[i].speedSum += (s.speed ?? 0) * w
            let keep = 86400 + 2 * Self.bucket
            if let f = buckets.first, s.time.timeIntervalSince(f.start) > keep + 10 * Self.bucket,
               let first = buckets.firstIndex(where: { s.time.timeIntervalSince($0.start) <= keep }) {
                buckets.removeFirst(first)
            }
        }
    }

    // MARK: Queries

    /// Mining-time mean speed over the trailing window (15 minutes at most).
    func meanSpeed(over seconds: TimeInterval, now: Date) -> Double? {
        let (sum, weight) = lock.withLock { speedTotals(over: seconds, now: now) }
        return weight > 0 ? sum / weight : nil
    }

    /// Seconds of mining (with a speed reading) in the trailing window (15 minutes at most).
    func miningSeconds(over seconds: TimeInterval, now: Date) -> Double {
        lock.withLock { speedTotals(over: seconds, now: now).weight }
    }

    private func speedTotals(over seconds: TimeInterval, now: Date) -> (sum: Double, weight: Double) {
        let from = now.addingTimeInterval(-seconds)
        var sum = 0.0, w = 0.0
        for t in ticks where t.time > from {
            if let v = t.speed { sum += v * t.weight; w += t.weight }
        }
        return (sum, w)
    }

    /// Graphs per second over wall-clock time since the first sample of the
    /// last 24 hours, stops counted as zero; nil with less than 2 hours
    /// recorded (a short test run hours ago isn't a pace).
    func recentPace(now: Date) -> Double? {
        lock.withLock {
            let from = now.addingTimeInterval(-86400)
            let recent = buckets.filter { $0.last > from && $0.start <= now }
            guard let first = recent.first else { return nil }
            let t0 = max(from, first.first.addingTimeInterval(-Self.tick))
            let span = now.timeIntervalSince(t0)
            guard span >= 7200, recent.reduce(0, { $0 + $1.weight }) >= 7200 else { return nil }
            return recent.reduce(0) { $0 + $1.speedSum } / span
        }
    }

    func save() throws {
        guard let url else { return }
        let p: Persisted = lock.withLock {
            if let l = lastTime { buckets.removeAll { l.timeIntervalSince($0.start) > 86400 + 2 * Self.bucket } }
            return Persisted(buckets: buckets)
        }
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        let data = try e.encode(p)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
