import Foundation
import MacotaurCore
import Network

// The real Tari block from tari-project/tari cuckaroo_pow.rs: its graph holds
// a known 42-cycle of difficulty 37.
let tariMiningHash = [UInt8](hex: "4dbfee3eb7b9a6a27d2a4a8d754eb77cc5493006945c1246e50e9beb4de5ffa5")!
let tariNonce: UInt64 = 0x9d589ed597ed42d0

/// A pool on localhost (ported from the core PoolTests) that serves one job
/// and verifies submitted shares the way a pool would. It can also drop every
/// connection, turn new ones away and reject logins.
final class MockPool: @unchecked Sendable {
    let listener: NWListener
    let queue = DispatchQueue(label: "mockpool")
    let jobLine: String
    // Confined to `queue`.
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var _submissions: [(nonce: UInt64, edges: [UInt64], valid: Bool)] = []
    private var _logins: [String] = []
    private var refusing = false
    private var rejectingLogins = false

    /// The real block as the job. xn is its full 8-byte nonce, so every graph
    /// the miner trims is that block's, and each one yields a valid share.
    convenience init() throws {
        try self.init(job: ["blob": tariMiningHash.hex, "job_id": "1", "height": 1,
                            "target": Stratum.targetHex(difficulty: 20), "xn": Stratum.nonceHex(tariNonce)])
    }

    init(job: [String: Any]) throws {
        listener = try NWListener(using: .tcp, on: .any)
        let r: [String: Any] = ["id": 1, "jsonrpc": "2.0", "error": NSNull(),
                                "result": ["id": "mock-session", "job": job, "status": "OK"]]
        jobLine = String(decoding: try JSONSerialization.data(withJSONObject: r), as: UTF8.self) + "\n"
        // Weak: a client's late callbacks can outlive the pool.
        listener.newConnectionHandler = { [weak self] c in
            guard let self, !refusing else { c.cancel(); return }
            let id = ObjectIdentifier(c)
            connections[id] = c
            c.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed, .cancelled: self?.connections[id] = nil
                default: break
                }
            }
            c.start(queue: queue)
            read(c, buffer: Data())
        }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.start(queue: queue)
        ready.wait()
    }

    var port: UInt16 { listener.port!.rawValue }
    var logins: [String] { queue.sync { _logins } }
    var submissions: [(nonce: UInt64, edges: [UInt64], valid: Bool)] { queue.sync { _submissions } }
    var openConnections: Int { queue.sync { connections.count } }

    /// Closes every open connection, as a pool restart would.
    func dropAll() {
        queue.sync {
            for c in connections.values { c.cancel() }
            connections.removeAll()
        }
    }

    /// While on, new connections are closed as soon as they arrive.
    func refuse(_ on: Bool) { queue.sync { refusing = on } }

    /// While on, logins get an error instead of a job.
    func rejectLogins(_ on: Bool) { queue.sync { rejectingLogins = on } }

    func shutDown() {
        dropAll()
        listener.cancel()
    }

    private func read(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = buffer + (data ?? Data())
            while let nl = buf.firstIndex(of: 10) {
                let line = buf[buf.startIndex..<nl]
                buf.removeSubrange(buf.startIndex...nl)
                handle(line, c)
            }
            // The client hung up: close our end too.
            if done || error != nil { c.cancel() } else { read(c, buffer: buf) }
        }
    }

    private func handle(_ line: Data, _ c: NWConnection) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let method = obj["method"] as? String, let p = obj["params"] as? [String: Any] else { return }
        if method == "login" {
            _logins.append(p["login"] as? String ?? "")
            if rejectingLogins {
                let reply: [String: Any] = ["id": 1, "jsonrpc": "2.0", "error": ["code": -1, "message": "invalid wallet"]]
                c.send(content: try! JSONSerialization.data(withJSONObject: reply) + Data([10]), completion: .idempotent)
            } else {
                c.send(content: Data(jobLine.utf8), completion: .idempotent)
            }
        } else if method == "submit" {
            let nonce = UInt64(p["nonce"] as! String, radix: 16)!
            let edges = (p["pow"] as! [Int]).map(UInt64.init)
            let keys = Tari.sipKeys(miningHash: tariMiningHash, nonce: nonce)
            let valid = (try? Cuckaroo.verify(edges, keys: keys)) != nil
                && Tari.powHash(edges).hex == p["result"] as? String
                && Tari.difficulty(nonces: edges) >= 20
            _submissions.append((nonce, edges, valid))
            let reply: [String: Any] = valid
                ? ["id": obj["id"]!, "jsonrpc": "2.0", "error": NSNull(), "result": ["status": "OK"]]
                : ["id": obj["id"]!, "jsonrpc": "2.0", "error": ["code": -1, "message": "invalid share"]]
            c.send(content: try! JSONSerialization.data(withJSONObject: reply) + Data([10]), completion: .idempotent)
        }
    }
}
