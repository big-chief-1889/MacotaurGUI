import Foundation
import Testing
@testable import MacotaurApp

// Response shapes from pool.kryptex.com; the wallet's balance is made up.
@Test func decodeKryptexResponses() throws {
    let balance: KryptexAPI.Balance = try #require(KryptexAPI.decode(Data(#"{"total":1.5,"unconfirmed":1.5,"confirmed":0.0,"threshold":200.0,"reached_pct":0.0,"last_active":0,"solo_effort":0,"maturation_time":21600.0,"banners":[]}"#.utf8)))
    #expect(balance.total == 1.5)
    #expect(balance.threshold == 200)
    #expect(balance.maturationTime == 21600)

    let pool: KryptexAPI.PoolInfo = try #require(KryptexAPI.decode(Data(#"{"miners":1320,"hashrate":20330.17,"net_hashrate":23394,"fee_type":"PROP","fee":0.01,"minpay":200.0,"height":361360,"block_time":480,"block_reward":10156.101627,"servers":[]}"#.utf8)))
    #expect(pool.netHashrate == 23394 && pool.blockTime == 480 && pool.fee == 0.01)

    let snap = KryptexAPI.Snapshot(balance: balance, payouts: nil, pool: pool, usdPerXTM: 0.0017111, fetchedAt: Date())
    // 1.6 g/s of 23394, 180 blocks/day of 10156 XTM, minus 1%: ~123.8 XTM/day
    let perDay = try #require(snap.expectedXTMPerDay(graphsPerSecond: 1.6))
    #expect(abs(perDay - 123.8) < 0.5)
}

/// Hits the live API. Set MACOTAUR_TEST_WALLET to a wallet that has mined on Kryptex.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MACOTAUR_TEST_WALLET"] != nil))
func liveKryptexSnapshot() async throws {
    let wallet = try #require(ProcessInfo.processInfo.environment["MACOTAUR_TEST_WALLET"])
    let s = try await KryptexAPI.snapshot(wallet: wallet)
    #expect(s.balance?.threshold != nil)
    #expect(s.pool?.netHashrate != nil)
    #expect(s.usdPerXTM != nil)
}
