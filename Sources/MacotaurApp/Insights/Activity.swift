import Foundation

enum ActivityKind: String, Codable, Sendable, CaseIterable {
    case started, gpuReady, connected, loggedIn, newJob, shareSubmitted, shareAccepted,
         shareRejected, shareStale, cycle, loginFailed, disconnected, thermal, memoryReleased,
         payout, stopped, problem, info
}

/// What a collapsible entry summarizes.
enum ActivityPayload: Equatable, Sendable {
    case jobs(heights: ClosedRange<UInt64>, difficulties: ClosedRange<UInt64>)
    case cycles(best: UInt64, target: UInt64)
    case disconnect(reason: String)
}

struct ActivityEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    var time: Date
    var kind: ActivityKind
    var text: String
    var count: Int
    var payload: ActivityPayload?

    init(id: UUID = UUID(), time: Date, kind: ActivityKind, text: String, count: Int = 1, payload: ActivityPayload? = nil) {
        self.id = id; self.time = time; self.kind = kind; self.text = text
        self.count = count; self.payload = payload
    }
}

/// The activity list, collapsed as entries arrive: consecutive new jobs and
/// consecutive below-difficulty cycles merge into the newest entry, and so do
/// identical disconnects within 2 minutes (with only reconnects between).
struct ActivityLog: Sendable {
    private(set) var entries: [ActivityEntry] = []   // oldest → newest
    var capacity: Int

    static let disconnectWindow: TimeInterval = 120

    init(capacity: Int = 1000) { self.capacity = capacity }

    @discardableResult
    mutating func append(_ kind: ActivityKind, _ text: String, at time: Date) -> UUID {
        insert(ActivityEntry(time: time, kind: kind, text: text))
    }

    @discardableResult
    mutating func appendJob(height: UInt64, difficulty: UInt64, at time: Date) -> UUID {
        if let i = entries.indices.last, entries[i].kind == .newJob,
           case .jobs(let h, let d)? = entries[i].payload {
            let heights = min(h.lowerBound, height)...max(h.upperBound, height)
            let diffs = min(d.lowerBound, difficulty)...max(d.upperBound, difficulty)
            entries[i].count += 1
            entries[i].time = time
            entries[i].payload = .jobs(heights: heights, difficulties: diffs)
            entries[i].text = Self.jobsText(count: entries[i].count, heights: heights, difficulties: diffs)
            return entries[i].id
        }
        return insert(ActivityEntry(time: time, kind: .newJob, text: Self.jobsText(count: 1, heights: height...height, difficulties: difficulty...difficulty),
                                    payload: .jobs(heights: height...height, difficulties: difficulty...difficulty)))
    }

    @discardableResult
    mutating func appendCycle(difficulty: UInt64, target: UInt64, at time: Date) -> UUID {
        if let i = entries.indices.last, entries[i].kind == .cycle, case .cycles(let best, _)? = entries[i].payload {
            let b = max(best, difficulty)
            entries[i].count += 1
            entries[i].time = time
            entries[i].payload = .cycles(best: b, target: target)
            entries[i].text = Self.cyclesText(count: entries[i].count, best: b, target: target)
            return entries[i].id
        }
        return insert(ActivityEntry(time: time, kind: .cycle, text: Self.cyclesText(count: 1, best: difficulty, target: target),
                                    payload: .cycles(best: difficulty, target: target)))
    }

    @discardableResult
    mutating func appendDisconnect(reason: String, retryDelay: TimeInterval, at time: Date) -> UUID {
        // The latest disconnect with the same reason, with only reconnects after it.
        var j = entries.count - 1
        while j >= 0 && entries[j].kind == .connected { j -= 1 }
        if j >= 0, entries[j].kind == .disconnected, case .disconnect(let r)? = entries[j].payload, r == reason,
           time.timeIntervalSince(entries[j].time) <= Self.disconnectWindow {
            var e = entries.remove(at: j)
            e.count += 1
            e.time = time
            e.text = "Disconnected \(e.count) times · \(reason)"
            entries.append(e)
            return e.id
        }
        let delay = Int(retryDelay.rounded())
        return insert(ActivityEntry(time: time, kind: .disconnected, text: "Disconnected · \(reason). Reconnecting in \(delay) s",
                                    payload: .disconnect(reason: reason)))
    }

    /// Rewrites an entry in place (a submitted share gets its result).
    mutating func update(id: UUID, kind: ActivityKind, text: String) {
        guard let i = entries.lastIndex(where: { $0.id == id }) else { return }
        entries[i].kind = kind
        entries[i].text = text
    }

    @discardableResult
    private mutating func insert(_ e: ActivityEntry) -> UUID {
        entries.append(e)
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        return e.id
    }

    static func jobsText(count: Int, heights: ClosedRange<UInt64>, difficulties: ClosedRange<UInt64>) -> String {
        let d = difficulties.lowerBound == difficulties.upperBound
            ? difficulties.lowerBound.formatted() : "\(difficulties.lowerBound.formatted())–\(difficulties.upperBound.formatted())"
        if count == 1 { return "New job · height \(heights.lowerBound.formatted()) · difficulty \(d)" }
        let h = heights.lowerBound == heights.upperBound
            ? "height \(heights.lowerBound.formatted())" : "heights \(heights.lowerBound.formatted())–\(heights.upperBound.formatted())"
        return "\(count) new jobs · \(h) · difficulty \(d)"
    }

    static func cyclesText(count: Int, best: UInt64, target: UInt64) -> String {
        if count == 1 { return "42-cycle · difficulty \(best.formatted()) (needs \(target.formatted()))" }
        return "\(count) cycles below share difficulty · best \(best.formatted()) (needs \(target.formatted()))"
    }
}
