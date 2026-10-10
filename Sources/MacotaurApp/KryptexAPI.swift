import Foundation

/// Read-only Kryptex pool stats for a wallet. These are the public JSON
/// endpoints behind pool.kryptex.com/xtm-c29/miner/stats/WALLET (undocumented,
/// so every field is optional and decoding is lenient).
enum KryptexAPI {
    static let base = URL(string: "https://pool.kryptex.com")!
    static let coin = "xtm-c29"

    struct Balance: Decodable, Sendable {
        var total: Double?
        var unconfirmed: Double?
        var confirmed: Double?
        var threshold: Double?
        /// Seconds before new rewards mature (become confirmed).
        var maturationTime: Double?

        init(total: Double? = nil, unconfirmed: Double? = nil, confirmed: Double? = nil,
                    threshold: Double? = nil, maturationTime: Double? = nil) {
            self.total = total; self.unconfirmed = unconfirmed; self.confirmed = confirmed
            self.threshold = threshold; self.maturationTime = maturationTime
        }
    }

    struct PayoutStats: Decodable, Sendable {
        var paid: Double?
        var unpaid: Double?

        init(paid: Double? = nil, unpaid: Double? = nil) { self.paid = paid; self.unpaid = unpaid }
    }

    struct PoolInfo: Decodable, Sendable {
        /// Graphs/s, the same unit as the miner's speed.
        var netHashrate: Double?
        var hashrate: Double?
        var blockReward: Double?
        var blockTime: Double?
        var fee: Double?
        var minpay: Double?
        var height: Int?

        init(netHashrate: Double? = nil, hashrate: Double? = nil, blockReward: Double? = nil, blockTime: Double? = nil,
                    fee: Double? = nil, minpay: Double? = nil, height: Int? = nil) {
            self.netHashrate = netHashrate; self.hashrate = hashrate; self.blockReward = blockReward
            self.blockTime = blockTime; self.fee = fee; self.minpay = minpay; self.height = height
        }
    }

    struct Snapshot: Sendable {
        var balance: Balance?
        var payouts: PayoutStats?
        var pool: PoolInfo?
        var usdPerXTM: Double?
        var fetchedAt: Date

        init(balance: Balance? = nil, payouts: PayoutStats? = nil, pool: PoolInfo? = nil,
                    usdPerXTM: Double? = nil, fetchedAt: Date = Date()) {
            self.balance = balance; self.payouts = payouts; self.pool = pool
            self.usdPerXTM = usdPerXTM; self.fetchedAt = fetchedAt
        }

        /// Expected XTM/day for a miner at `graphsPerSecond`: its share of the
        /// network rate times C29's daily block rewards, minus the pool fee.
        func expectedXTMPerDay(graphsPerSecond: Double) -> Double? {
            guard let gross = networkXTMPerDay(graphsPerSecond: graphsPerSecond) else { return nil }
            return gross * (1 - (pool?.fee ?? 0))
        }

        /// The same estimate before any pool fee (for pools other than Kryptex).
        func networkXTMPerDay(graphsPerSecond: Double) -> Double? {
            guard let p = pool, let net = p.netHashrate, net > 0, let reward = p.blockReward,
                  let blockTime = p.blockTime, blockTime > 0 else { return nil }
            return graphsPerSecond / net * (86400 / blockTime) * reward
        }
    }

    /// Fetch everything in parallel; individual failures leave that part nil.
    /// Throws only if nothing at all could be fetched.
    static func snapshot(wallet: String, session: URLSession = .shared) async throws -> Snapshot {
        let w = wallet.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty, w.allSatisfy({ $0.isLetter || $0.isNumber }) else { throw URLError(.badURL) }
        async let balance: Balance? = get("\(coin)/api/v1/miner/balance/\(w)", session)
        async let payouts: PayoutStats? = get("\(coin)/api/v1/miner/payouts/\(w)/stats", session)
        async let pool: PoolInfo? = get("\(coin)/api/v1/pool/info", session)
        async let rates: Rates? = get("api/v1/rates", session)
        let s = await Snapshot(balance: balance, payouts: payouts, pool: pool, usdPerXTM: rates?.crypto?["XTM"],
                               fetchedAt: Date())
        if s.balance == nil && s.pool == nil { throw URLError(.cannotLoadFromNetwork) }
        return s
    }

    /// Pool info and the USD rate only (no wallet sent): enough for XTM/day
    /// estimates with any pool. Throws if neither could be fetched.
    static func networkSnapshot(session: URLSession = .shared) async throws -> Snapshot {
        async let pool: PoolInfo? = get("\(coin)/api/v1/pool/info", session)
        async let rates: Rates? = get("api/v1/rates", session)
        let s = await Snapshot(pool: pool, usdPerXTM: rates?.crypto?["XTM"], fetchedAt: Date())
        if s.pool == nil && s.usdPerXTM == nil { throw URLError(.cannotLoadFromNetwork) }
        return s
    }

    struct Rates: Decodable { var crypto: [String: Double]? }

    static func get<T: Decodable>(_ path: String, _ session: URLSession) async -> T? {
        var req = URLRequest(url: base.appending(path: path))
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return decode(data)
    }

    static func decode<T: Decodable>(_ data: Data) -> T? {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try? d.decode(T.self, from: data)
    }
}
