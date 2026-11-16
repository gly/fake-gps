import Combine
import Foundation

/// Tracks and (optionally) launches the privileged `tunneld` daemon.
///
/// `tunneld` is what creates the per-device RemoteXPC tunnel and auto-mounts the
/// Developer Disk Image. It must run as root, so we can only *start* it via an
/// authenticated `osascript` prompt; we poll its HTTP endpoint to know if it's up.
@MainActor
final class TunnelManager: ObservableObject {
    @Published private(set) var isUp = false
    /// 已点过「启动隧道」但迟迟未就绪时，展示 tunneld 日志尾部帮助定位原因。
    @Published private(set) var startFailure: String?

    private var pollTimer: Timer?
    /// 点「启动隧道」后等待隧道就绪的截止时间；到时仍未就绪则展示日志。
    private var startWaitDeadline: Date?
    /// Returns (executablePath, args) for launching the tunnel daemon.
    let tunneldCommand: () -> (path: String, args: [String])

    init(tunneldCommand: @escaping () -> (path: String, args: [String])) {
        self.tunneldCommand = tunneldCommand
        startPolling()
    }

    private func startPolling() {
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
        Task { await poll() }
    }

    private func poll() async {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:49151")!)
        req.timeoutInterval = 1.0
        let up: Bool
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            up = (resp as? HTTPURLResponse) != nil
        } catch {
            up = false
        }
        if up != isUp {
            isUp = up
            if up { startFailure = nil }
        }
        // 已发起启动但超过等待期仍未就绪：读取日志尾部，让用户看到失败原因。
        if !up, let deadline = startWaitDeadline, Date() >= deadline {
            startFailure = Self.readLogTail()
        }
    }

    /// 读取 tunneld 日志尾部（启动失败原因会写在这里）。
    static func readLogTail(maxLines: Int = 10) -> String? {
        guard let content = try? String(contentsOfFile: logPath, encoding: .utf8) else {
            return nil
        }
        let tail = content.split(separator: "\n").suffix(maxLines).joined(separator: "\n")
        return tail.isEmpty ? nil : String(tail.suffix(800))
    }

    /// Launch tunneld with administrator privileges. Shows the macOS auth dialog.
    /// Runs detached so it keeps managing tunnels after this call returns.
    static let logPath = "/tmp/ios-fake-gps-tunneld.log"

    func startTunneld() {
        let (path, args) = tunneldCommand()
        startFailure = nil
        startWaitDeadline = Date().addingTimeInterval(15)
        let quotedArgs = args.map { Self.shellQuote($0) }.joined(separator: " ")
        // Fully detach the daemon so it survives the privileged osascript session
        // ending. `nohup` fails here ("can't detach from console" — no tty), and
        // a plain `&` child can be reaped with the session, so we use perl's
        // setsid to start a brand-new session, then exec the daemon. Output goes
        // to a log file; `&` returns control to osascript immediately.
        let inner = "/usr/bin/perl -MPOSIX -e 'setsid or exit 1; exec @ARGV' "
            + "\(Self.shellQuote(path)) \(quotedArgs)"
        let shell = "\(inner) </dev/null >\(Self.logPath) 2>&1 &"
        // Escape for embedding inside an AppleScript "do shell script" string:
        // backslashes first, then double quotes.
        let escaped = shell
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        try? proc.run()
    }

    /// Quote a string for safe use as a shell argument (POSIX single-quote style).
    /// Wraps in single quotes and escapes any embedded single quotes as `'\''`.
    private static func shellQuote(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    deinit {
        pollTimer?.invalidate()
    }
}
