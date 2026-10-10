import Foundation
import MacotaurCore
import Metal

/// This Mac, detected once at launch. Nothing is decided by model name.
struct HardwareProfile: Equatable, Sendable {
    var chipName: String                            // "Apple M5" (MTLDevice.name; "Apple GPU" if none)
    var gpuCores: Int?
    var solverBytes: UInt64                         // what MetalSolver() will allocate

    /// Cheap: creates an MTLDevice (no large allocation) and reads the
    /// IORegistry.
    static func detect() -> HardwareProfile {
        let device = MTLCreateSystemDefaultDevice()
        return HardwareProfile(
            chipName: device?.name ?? "Apple GPU",
            gpuCores: MetalSolver.gpuCoreCount(),
            solverBytes: UInt64(MetalSolver.memoryPlan(device: device).gpuMemoryBytes))
    }
}
