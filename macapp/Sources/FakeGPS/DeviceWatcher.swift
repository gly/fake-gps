import Combine
import Foundation

/// Polls the runtime's `usbmux` mode to detect whether an iPhone is plugged in,
/// independently of the developer tunnel. Used by the onboarding checklist so it
/// can tell the user "iPhone detected" before anything else is set up.
///
/// Uses exponential backoff: polls every 3 s initially, slows to every 30 s
/// when the device count is stable, and resets to fast polling on any change.
@MainActor
final class DeviceWatcher: ObservableObject {
    @Published private(set) var deviceCount = 0

    var hasDevice: Bool { deviceCount > 0 }

    private let launch: () -> (executable: URL, args: [String])
    private var timer: Timer?
    private var polling = false
    private var pollInterval: TimeInterval = 3.0
    private let minInterval: TimeInterval = 3.0
    private let maxInterval: TimeInterval = 30.0
    private var stableCount = 0  // how many consecutive polls returned the same count

    init(launch: @escaping () -> (executable: URL, args: [String])) {
        self.launch = launch
        scheduleNextPoll(delay: 0)
    }

    private func scheduleNextPoll(delay: TimeInterval) {
        timer?.invalidate()
        let t = Timer(timeInterval: max(0.01, delay), repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func poll() async {
        guard !polling else { return }
        polling = true
        defer { polling = false }

        let (exe, args) = launch()
        guard FileManager.default.isExecutableFile(atPath: exe.path) else {
            scheduleNextPoll(delay: pollInterval)
            return
        }

        let count: Int? = await Task.detached {
            let proc = Process()
            proc.executableURL = exe
            proc.arguments = args
            let out = Pipe()
            proc.standardOutput = out
            proc.standardError = Pipe()
            do { try proc.run() } catch { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let devices = obj["devices"] as? [[String: Any]]
            else { return nil }
            return devices.count
        }.value

        if let count {
            if count != deviceCount {
                deviceCount = count
                // Device count changed — reset to fast polling.
                pollInterval = minInterval
                stableCount = 0
            } else {
                stableCount += 1
                // After 3 stable polls, start backing off.
                if stableCount >= 3 {
                    pollInterval = min(pollInterval * 1.5, maxInterval)
                }
            }
        }
        scheduleNextPoll(delay: pollInterval)
    }

    deinit {
        timer?.invalidate()
    }
}
