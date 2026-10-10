import Foundation

/// Samples PowerMonitor on a utility queue and delivers readings on the main
/// actor. Every 2 s during a session, every 10 s while stopped with a
/// Macotaur window visible, otherwise off. Never constructed in demo mode.
@MainActor final class Telemetry {
    private let onSample: @MainActor (PowerSample) -> Void
    private let queue = DispatchQueue(label: "macotaur.telemetry", qos: .utility)
    private let box = MonitorBox()
    private var timer: DispatchSourceTimer?
    private var interval: TimeInterval?

    /// The monitor lives on `queue` only.
    final class MonitorBox: @unchecked Sendable { var monitor: PowerMonitor? }

    init(onSample: @escaping @MainActor (PowerSample) -> Void) {
        self.onSample = onSample
    }

    /// nil = off.
    func setInterval(_ seconds: TimeInterval?) {
        guard seconds != interval else { return }
        interval = seconds
        timer?.cancel()
        timer = nil
        guard let seconds else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + min(seconds, 1), repeating: seconds, leeway: .milliseconds(200))
        let box = box
        // @Sendable so the handler isn't inferred main-actor isolated: it runs on `queue`.
        t.setEventHandler { @Sendable [weak self] in
            guard let monitor = box.monitor else {
                // The first reading is only a baseline; the next one is a real delta.
                let m = PowerMonitor()
                _ = m.sample()
                box.monitor = m
                return
            }
            let sample = monitor.sample()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.onSample(sample) }
            }
        }
        t.resume()
        timer = t
    }
}
