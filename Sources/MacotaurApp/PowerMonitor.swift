import CMacotaurPower
import Foundation

/// Telemetry sources this Mac has (see CMacotaurPower.h).
struct PowerCapabilities: OptionSet, Sendable, Hashable {
    let rawValue: UInt32
    init(rawValue: UInt32) { self.rawValue = rawValue }
    static let gpuEnergy = PowerCapabilities(rawValue: UInt32(MP_GPU_ENERGY))
    static let gpuPMP = PowerCapabilities(rawValue: UInt32(MP_GPU_PMP))
    static let gpuStates = PowerCapabilities(rawValue: UInt32(MP_GPU_STATES))
    static let gpuClock = PowerCapabilities(rawValue: UInt32(MP_GPU_CLOCK))
    static let powerZone = PowerCapabilities(rawValue: UInt32(MP_POWER_ZONE))
    static let dramBandwidth = PowerCapabilities(rawValue: UInt32(MP_DRAM_BW))
    static let systemPower = PowerCapabilities(rawValue: UInt32(MP_SYSTEM_POWER))
    static let fans = PowerCapabilities(rawValue: UInt32(MP_FANS))
    static let processEnergy = PowerCapabilities(rawValue: UInt32(MP_PROCESS_CPU))

    var names: [String] {
        let all: [(PowerCapabilities, String)] = [
            (.gpuEnergy, "gpuEnergy"), (.gpuPMP, "gpuPMP"), (.gpuStates, "gpuStates"), (.gpuClock, "gpuClock"),
            (.powerZone, "powerZone"), (.dramBandwidth, "dramBandwidth"), (.systemPower, "systemPower"),
            (.fans, "fans"), (.processEnergy, "processEnergy"),
        ]
        return all.filter { contains($0.0) }.map(\.1)
    }
}

/// One reading: rates over `interval` (since the previous sample), or
/// instantaneous values (system watts, fans). nil = unavailable.
struct PowerSample: Sendable, Equatable {
    var time: Date
    var interval: TimeInterval
    var gpuWatts: Double?
    var gpuBusy: Double?
    var gpuMHz: Double?
    var gpuMaxMHz: Double?
    var dramGBps: Double?
    var systemWatts: Double?
    var processWatts: Double?
    var fanRPM: [Double]
    var fanCount: Int?           // nil unknown, 0 none

    init(time: Date = Date(), interval: TimeInterval = 0) {
        self.time = time
        self.interval = interval
        fanRPM = []
    }
}

/// Reads GPU power, clock, DRAM traffic, whole-Mac power, fans and this
/// process's CPU energy. Opens lazily and never throws: missing sources are
/// simply absent from `capabilities` and nil in samples. Use from one queue.
final class PowerMonitor: @unchecked Sendable {
    private var meter: OpaquePointer?
    private var opened = false

    init() {}

    deinit { if let meter { mp_close(meter) } }

    private func open() {
        guard !opened else { return }
        opened = true
        meter = mp_open()
    }

    /// Sources found, after liveness checks (a dead counter drops out).
    var capabilities: PowerCapabilities {
        open()
        return PowerCapabilities(rawValue: mp_capabilities(meter))
    }

    /// Delta since the previous call (or since the monitor opened).
    func sample() -> PowerSample {
        open()
        var s = MPSample()
        mp_sample(meter, &s)
        let now = Date()
        func value(_ x: Double) -> Double? { x.isFinite ? x : nil }
        let seconds = s.seconds
        let fans = withUnsafeBytes(of: s.fan_rpm) { Array($0.bindMemory(to: Double.self)) }
        let fanCount: Int? = s.fan_count < 0 ? nil : Int(s.fan_count)
        var out = PowerSample(time: now, interval: seconds)
        out.gpuWatts = seconds > 0 ? value(s.gpu_joules).map { $0 / seconds } : nil
        out.gpuBusy = value(s.gpu_busy)
        out.gpuMHz = value(s.gpu_mhz)
        out.gpuMaxMHz = value(s.gpu_max_mhz)
        out.dramGBps = seconds > 0 ? value(s.dram_gb).map { $0 / seconds } : nil
        out.systemWatts = value(s.system_watts)
        out.processWatts = seconds > 0 ? value(s.process_cpu_joules).map { $0 / seconds } : nil
        out.fanRPM = Array(fans.prefix(min(4, max(0, fanCount ?? 0)))).compactMap(value)
        out.fanCount = fanCount
        return out
    }

    /// A one-line description of the sources (for `--power-debug`).
    var debugDescription: String {
        open()
        var buffer = [CChar](repeating: 0, count: 1024)
        let n = Int(mp_describe(meter, &buffer, Int32(buffer.count)))
        return String(decoding: buffer.prefix(max(0, n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Quick SMC read of the fan count: nil unknown, 0 none.
    static func fanCount() -> Int? {
        let n = mp_fan_count()
        return n < 0 ? nil : Int(n)
    }
}
