import Foundation

/// Watches macOS's thermal state (the Heat reading), live only.
@MainActor final class SystemMonitor {
    private(set) var thermal = ProcessInfo.processInfo.thermalState

    private let onChange: @MainActor () -> Void
    private var observer: NSObjectProtocol?

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
    }

    func start() {
        guard observer == nil else { return }
        // Posted on whatever thread noticed the change; `queue: .main` brings
        // the handler back to the main actor.
        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.thermal = ProcessInfo.processInfo.thermalState
                self.onChange()
            }
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
}
