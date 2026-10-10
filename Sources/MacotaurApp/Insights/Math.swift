import Foundation

// MARK: Speed

/// Graphs per second from cumulative counts, smoothed over a time window that
/// adapts to the speed: about 50 s at 0.5 graphs/s, 20 s at 16 graphs/s
/// (W = clamp(25 / speed, 20 s, 90 s) of mining time).
struct SpeedMeter: Sendable {
    struct Record { var graphs: Int; var seconds: Double }
    private var records: [Record] = []
    private var base: Record?
    private var last: Double?

    static let minimumGraphs = 5
    static let minimumSeconds: Double = 10

    init() {}

    mutating func reset() { self = SpeedMeter() }

    /// Record cumulative graphs and mining seconds (counters that go
    /// backwards mean a new run and reset the meter).
    mutating func record(graphs: Int, miningSeconds: Double, at: Date) {
        if let l = records.last, graphs < l.graphs || miningSeconds < l.seconds { reset() }
        let r = Record(graphs: graphs, seconds: miningSeconds)
        if base == nil { base = r }
        records.append(r)
        while records.count > 2, miningSeconds - records[1].seconds >= 95 { records.removeFirst() }
        last = compute()
    }

    /// nil while measuring: fewer than 5 graphs or 10 s since the (re)start.
    func speed() -> Double? { last }

    private func compute() -> Double? {
        guard let base, let now = records.last else { return nil }
        let graphs = now.graphs - base.graphs, seconds = now.seconds - base.seconds
        guard graphs >= Self.minimumGraphs, seconds >= Self.minimumSeconds else { return nil }
        let reference = last ?? Double(graphs) / seconds
        let window = min(90, max(20, 25 / max(reference, 0.01)))
        let from = records.last { now.seconds - $0.seconds >= window } ?? records.first!
        let dt = now.seconds - from.seconds
        guard dt > 0 else { return reference }
        return Double(now.graphs - from.graphs) / dt
    }
}

// MARK: Payout

enum PayoutMath {
    enum State: Equatable, Sendable { case progress, dueSoon(maturesIn: TimeInterval?), due }

    /// Due once the confirmed balance reaches the threshold; due soon when the
    /// total does but part of it is still maturing.
    static func state(total: Double, confirmed: Double, threshold: Double, maturation: TimeInterval?) -> State {
        if confirmed >= threshold { return .due }
        if total >= threshold { return .dueSoon(maturesIn: maturation) }
        return .progress
    }

    /// Seconds to earn `remaining` XTM; nil without a positive rate.
    static func eta(remaining: Double, xtmPerDay: Double) -> TimeInterval? {
        guard xtmPerDay > 0, xtmPerDay.isFinite else { return nil }
        return max(0, remaining) / xtmPerDay * 86400
    }
}

// MARK: Time to payout copy

/// The ETA ladders used in Macotaur's copy ("about 7 hours" / "≈ 7 hours").
enum EtaFormat {
    static let hour: TimeInterval = 3600, day: TimeInterval = 86400

    static func long(_ seconds: TimeInterval) -> String {
        let h = seconds / hour, d = seconds / day
        switch seconds {
        case ..<hour: return "less than an hour"
        case ..<(20 * hour): return plural(max(1, Int(h.rounded())), "hour", prefix: "about")
        case ..<(36 * hour): return "about a day"
        case ..<(14 * day): return plural(max(2, Int(d.rounded())), "day", prefix: "about")
        case ..<(56 * day): return plural(max(2, Int((d / 7).rounded())), "week", prefix: "about")
        case ..<(365 * day): return plural(max(2, Int((d / 30.44).rounded())), "month", prefix: "about")
        default: return "more than a year"
        }
    }

    static func short(_ seconds: TimeInterval) -> String {
        let h = seconds / hour, d = seconds / day
        switch seconds {
        case ..<hour: return "< 1 hour"
        case ..<(20 * hour): return plural(max(1, Int(h.rounded())), "hour", prefix: "≈")
        case ..<(36 * hour): return "≈ 1 day"
        case ..<(14 * day): return plural(max(2, Int(d.rounded())), "day", prefix: "≈")
        case ..<(56 * day): return plural(max(2, Int((d / 7).rounded())), "week", prefix: "≈")
        case ..<(365 * day): return plural(max(2, Int((d / 30.44).rounded())), "month", prefix: "≈")
        default: return "> 1 year"
        }
    }

    static func plural(_ n: Int, _ unit: String, prefix: String) -> String {
        "\(prefix) \(n) \(unit)\(n == 1 ? "" : "s")"
    }
}
