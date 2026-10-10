import Foundation

// What the dashboard and Settings show, worded here once.
extension MiningModel {

    // MARK: Status

    var isMeasuringSpeed: Bool { status == .mining && speed == nil }

    var heat: HeatLevel { HeatLevel(thermalState) }

    /// One word for the state: "Mining", "Stopping", "Ready"…
    var statusWord: String {
        switch status {
        case .stopped: hasWallet ? "Ready" : "Not set up"
        case .preparingGPU: "Preparing"
        case .connecting: "Connecting"
        case .mining: "Mining"
        case .reconnecting: "Reconnecting"
        case .stopping: "Stopping"
        case .failed: "Error"
        }
    }

    /// The toolbar subtitle: "Mining · 5.21 graphs/s", "Reconnecting…", "Stopped"…
    var windowSubtitle: String {
        let base: String = switch status {
        case .stopped: hasWallet ? "Stopped" : "Add a wallet to start"
        case .preparingGPU: "Preparing the GPU…"
        case .connecting: "Connecting…"
        case .mining: speed.map { "Mining · \(Format.rate($0)) graphs/s" } ?? "Mining · measuring speed"
        case .reconnecting: "Reconnecting…"
        case .stopping: "Stopping…"
        case .failed(let p): p.title
        }
        return isDemo ? "Demo · sample data · \(base)" : base
    }

    /// "5.21" "16.4" "–.––" (measuring) "—" (no value).
    var speedText: String {
        switch status {
        case .mining: speed.map(Format.rate) ?? "–.––"
        case .reconnecting, .stopping: lastSpeed.map(Format.rate) ?? "—"
        default: "—"
        }
    }

    /// The line under the speed.
    var speedCaption: String {
        switch status {
        case .stopped:
            if !hasWallet { return "Add your Tari wallet to start." }
            if let v = lastSessionSpeed { return "Last session averaged \(Format.rate(v)) graphs/s." }
            return "Press Start to begin."
        case .preparingGPU: return "This takes a few seconds."
        case .connecting(let trouble):
            return trouble ?? "Logging in as wallet\(endpoint?.separator ?? "/")\(workerName)"
        case .mining:
            if !isMeasuringSpeed, let avg = historyStore.meanSpeed(over: 900, now: now) {
                return "Average \(Format.rate(avg)) over the last 15 min"
            }
            return "Measuring speed…"
        case .reconnecting: return "The GPU rests until the pool is back. Retrying every 5 seconds."
        case .stopping: return lastSpeed == nil ? "" : "Stopping…"   // else the headline says it
        case .failed(let p): return p.detail
        }
    }

    // MARK: Earnings (status line; nil when there is nothing to show)

    /// "61 shares", against the count expected from the graphs solved.
    var sharesFigure: Figure {
        let t = today
        var help: String
        if t.expected > 0 {
            let n = t.expected < 10 ? t.expected.formatted(.number.precision(.fractionLength(1)))
                : Int(t.expected.rounded()).formatted()
            help = "≈ \(n) expected"
        } else {
            help = "today"
        }
        if t.rejected > 0 { help += " · \(t.rejected) rejected" }
        return Figure(text: t.accepted == 1 ? "1 share" : "\(t.accepted) shares", help: help)
    }

    /// The 10-minute mining-time mean (with at least a minute of mining), else the live speed.
    private var estimateSpeed: Double? {
        _ = historyRevision
        if historyStore.miningSeconds(over: 600, now: now) >= 60, let v = historyStore.meanSpeed(over: 600, now: now) { return v }
        return speed
    }

    /// "≈ 399 XTM/day" at the recent speed, while a session is connected or reconnecting.
    var perDayFigure: Figure? {
        switch status {
        case .mining, .reconnecting: break
        default: return nil
        }
        let isKryptex = preset == .kryptex
        guard let v = estimateSpeed, let snap = kryptex,
              let xtm = isKryptex ? snap.expectedXTMPerDay(graphsPerSecond: v) : snap.networkXTMPerDay(graphsPerSecond: v)
        else { return nil }
        let usd = snap.usdPerXTM.map { " (≈ \(Format.usd(xtm * $0)))" } ?? ""
        let source = isKryptex ? "from Kryptex's network figures" : "from Kryptex's network figures, before your pool's fee"
        return Figure(text: "≈ \(Format.xtm(xtm))/day",
                      help: "≈ \(Format.xtm(xtm)) a day\(usd) at \(Format.rate(v)) graphs/s (the last 10 minutes of mining), \(source). Actual pay varies with pool luck.")
    }

    /// Kryptex only: "≈ 7 hours", "63%", "Due soon", "Due".
    var payoutFigure: Figure? {
        _ = historyRevision
        guard preset == .kryptex, hasWallet, let snap = kryptex, let b = snap.balance, let total = b.total else { return nil }
        let unconfirmed = b.unconfirmed ?? 0
        let confirmed = b.confirmed ?? max(0, total - unconfirmed)
        let threshold = b.threshold ?? snap.pool?.minpay ?? 200
        var value: String, help: String
        switch PayoutMath.state(total: total, confirmed: confirmed, threshold: threshold, maturation: b.maturationTime) {
        case .progress:
            let fraction = threshold > 0 ? min(1, total / threshold) : 0
            value = Format.percent(fraction)
            help = "to \(Format.xtm(threshold))"
            if intent == .mining, let (pace, basis) = payoutPace,
               let perDay = snap.expectedXTMPerDay(graphsPerSecond: pace),
               let eta = PayoutMath.eta(remaining: threshold - total, xtmPerDay: perDay) {
                let long = EtaFormat.long(eta)
                value = EtaFormat.short(eta)
                help = "\(long.prefix(1).uppercased() + long.dropFirst()) \(basis) (around \(Format.clock(now.addingTimeInterval(eta))))."
                return Figure(text: value, help: help)
            }
        case .dueSoon(let matures):
            value = "Due soon"
            help = "Once \(Format.xtm(unconfirmed)) matures" + (matures.map { " (about \(Format.duration($0)))" } ?? "")
        case .due:
            value = "Due"
            help = "Kryptex pays out in batches"
        }
        if let last = lastPayout, now.timeIntervalSince(last.date) < 86400 {
            help = "Paid \(Format.xtm(last.amount)) at \(Format.clock(last.date))"
        }
        return Figure(text: value, help: help)
    }

    /// Kryptex only: what the pool holds for this wallet, and what it has paid out.
    var poolBalance: Figure? {
        guard preset == .kryptex, hasWallet, let snap = kryptex, let total = snap.balance?.total else { return nil }
        let threshold = snap.balance?.threshold ?? snap.pool?.minpay ?? 200
        var parts = ["\(Format.percent(threshold > 0 ? min(1, total / threshold) : 0)) of the \(Format.xtm(threshold)) payout"]
        if let paid = snap.payouts?.paid, paid > 0 { parts.append("\(Format.xtm(paid)) paid out") }
        if let usd = snap.usdPerXTM { parts.append("≈ \(Format.usd(total * usd))") }
        return Figure(text: Format.xtm(total), help: parts.joined(separator: " · "))
    }

    /// The speed the payout estimate assumes: the last day's pace with stops
    /// counted, else the last 10 minutes of mining.
    private var payoutPace: (graphsPerSecond: Double, basis: String)? {
        if let r = historyStore.recentPace(now: now), r > 0 { return (r, "at your recent pace") }
        if status == .mining || status == .reconnecting, historyStore.miningSeconds(over: 600, now: now) >= 60,
           let v = historyStore.meanSpeed(over: 600, now: now) {
            return (v, "at this speed")
        }
        return nil
    }
}
