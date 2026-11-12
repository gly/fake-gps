import Combine
import Foundation

/// A device reported by the Python sidecar.
struct DeviceInfo: Identifiable, Hashable, Codable {
    var udid: String
    var name: String?
    /// 手机上自定义的名称（lockdown 的 DeviceName，如「Leo 的 iPhone」）。
    var deviceName: String?
    var productType: String?
    var productVersion: String?

    var id: String { udid }

    /// 营销型号名（如 iPhone15,2 -> iPhone 14 Pro）；未知型号回退到原始标识符。
    var modelName: String {
        guard let t = productType else { return "iPhone" }
        return Self.friendlyModelNames[t] ?? "iPhone (\(t))"
    }

    var display: String {
        "\(modelName) · iOS \(productVersion ?? "?")"
    }

    static let friendlyModelNames: [String: String] = [
        "iPhone10,2": "iPhone XS", "iPhone10,5": "iPhone XS",
        "iPhone10,3": "iPhone XS Max", "iPhone10,6": "iPhone XS Max",
        "iPhone11,8": "iPhone XR",
        "iPhone12,1": "iPhone 11 Pro", "iPhone12,3": "iPhone 11 Pro Max",
        "iPhone12,5": "iPhone 11 Pro Max",
        "iPhone12,8": "iPhone SE（第二代）",
        "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12",
        "iPhone13,3": "iPhone 12 Pro", "iPhone13,4": "iPhone 12 Pro Max",
        "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max",
        "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13",
        "iPhone14,6": "iPhone SE（第三代）",
        "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus",
        "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
        "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus",
        "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
        "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus",
        "iPhone17,5": "iPhone 16 Pro", "iPhone17,6": "iPhone 16 Pro Max",
        "iPhone17,7": "iPhone 16e",
    ]

    enum CodingKeys: String, CodingKey {
        case udid, name, deviceName
        case productType = "product_type"
        case productVersion = "product_version"
    }
}

enum SidecarState: Equatable {
    case stopped
    case launching
    case ready(DeviceInfo)
    case failed(String)

    var isReady: Bool { if case .ready = self { return true }; return false }
}

/// Manages the lifetime of the `gpsd_helper.py` sidecar process and the
/// newline-delimited JSON protocol spoken over its stdin/stdout pipes.
@MainActor
final class Sidecar: ObservableObject {
    @Published private(set) var state: SidecarState = .stopped
    @Published private(set) var lastError: String?
    /// ID of the most recent command the device acknowledged with `ok`.
    @Published private(set) var lastAcknowledgedID: Int?

    /// Executable to launch and the leading args (e.g. the frozen runtime with
    /// ["sidecar"], or python with [scriptPath]).
    var executableURL: URL
    var argsPrefix: [String]

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutBuffer = Data()
    private var messageID = 0

    init(executableURL: URL, argsPrefix: [String]) {
        self.executableURL = executableURL
        self.argsPrefix = argsPrefix
    }

    // MARK: - Lifecycle

    func start(udid: String? = nil) {
        stop()
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            state = .failed("Runtime not found at \(executableURL.path).")
            return
        }

        state = .launching
        lastError = nil

        let proc = Process()
        proc.executableURL = executableURL
        var args = argsPrefix
        if let udid { args += ["--udid", udid] }
        proc.arguments = args

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            guard let self else { return }
            Task { @MainActor in self.ingest(data) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let s = String(data: data, encoding: .utf8), !s.isEmpty {
                FileHandle.standardError.write(Data(s.utf8))
            }
        }
        proc.terminationHandler = { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.handleTermination() }
        }

        do {
            try proc.run()
        } catch {
            state = .failed("Could not launch sidecar: \(error.localizedDescription)")
            return
        }
        process = proc
        stdinPipe = inPipe
    }

    func stop() {
        if let proc = process, proc.isRunning {
            // Reset the device to real GPS first, then ask the helper to quit.
            // Don't SIGTERM immediately — that races the clear.
            let sentClear = send(["cmd": "clear"])
            send(["cmd": "quit"])
            // Delay closing stdin so the sidecar has time to read the clear command.
            // If we close the pipe immediately, the sidecar may not have read the
            // commands yet, leaving the device at the fake location.
            let pipeToClose = stdinPipe
            let closeDelay: Double = sentClear ? 0.15 : 0
            DispatchQueue.global().asyncAfter(deadline: .now() + closeDelay) {
                try? pipeToClose?.fileHandleForWriting.close()
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if proc.isRunning { proc.terminate() }
            }
        }
        resetState()
    }

    /// Blocking cleanup used on app termination: clear the location and wait
    /// (bounded) for the helper to exit, so quitting always restores real GPS.
    func shutdownBlocking() {
        guard let proc = process, proc.isRunning else { return }
        let sentClear = send(["cmd": "clear"])
        send(["cmd": "quit"])
        // Give the sidecar a moment to process the clear command before closing
        // the pipe, so the device location is actually restored.
        if sentClear { usleep(150_000) }
        try? stdinPipe?.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(2)
        while proc.isRunning && Date() < deadline { usleep(50_000) }
        if proc.isRunning { proc.terminate() }
        resetState()
    }

    private func resetState() {
        process = nil
        stdinPipe = nil
        stdoutBuffer.removeAll()
        // Reset any non-stopped state back to stopped so the UI always returns
        // to a clean state after disconnect / stop.
        if state != .stopped { state = .stopped }
    }

    private func handleTermination() {
        process = nil
        stdinPipe = nil
        if state.isReady || state == .launching {
            state = .stopped
        }
    }

    // MARK: - Commands

    /// Send a coordinate to the device. Returns the command ID to match against
    /// `lastAcknowledgedID`, or nil if the helper isn't running.
    @discardableResult
    func setLocation(_ lat: Double, _ lon: Double) -> Int? {
        messageID += 1
        let id = messageID
        return send(["cmd": "set", "lat": lat, "lon": lon, "id": id]) ? id : nil
    }

    @discardableResult
    func clearLocation() -> Int? {
        messageID += 1
        let id = messageID
        return send(["cmd": "clear", "id": id]) ? id : nil
    }

    /// Send a JSON command to the sidecar over stdin. Returns `true` if the
    /// message was actually written, `false` if the process/pipe is gone.
    @discardableResult
    private func send(_ obj: [String: Any]) -> Bool {
        guard let pipe = stdinPipe,
              let data = try? JSONSerialization.data(withJSONObject: obj),
              process?.isRunning == true else { return false }
        var line = data
        line.append(0x0A) // newline
        pipe.fileHandleForWriting.write(line)
        return true
    }

    // MARK: - Incoming NDJSON

    private func ingest(_ data: Data) {
        stdoutBuffer.append(data)
        while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer[stdoutBuffer.startIndex ..< nl]
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex ... nl)
            guard !lineData.isEmpty else { continue }
            handleEvent(lineData)
        }
    }

    private func handleEvent(_ lineData: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let event = obj["event"] as? String else { return }

        switch event {
        case "ready", "reconnected":
            // A (re)established device connection clears any stale error text.
            lastError = nil
            if let devObj = obj["device"],
               let devData = try? JSONSerialization.data(withJSONObject: devObj),
               let dev = try? JSONDecoder().decode(DeviceInfo.self, from: devData) {
                state = .ready(dev)
            } else {
                state = .ready(DeviceInfo(udid: "?", name: "Device", productType: nil, productVersion: nil))
            }
        case "error":
            let msg = obj["message"] as? String ?? "unknown error"
            lastError = msg
            if (obj["fatal"] as? Bool) == true {
                state = .failed(msg)
            }
        case "ok":
            if let id = obj["id"] as? Int {
                lastAcknowledgedID = id
                // The link is healthy again; drop any transient reconnect text.
                lastError = nil
            }
        case "pong", "devices", "bye":
            break
        default:
            break
        }
    }
}
