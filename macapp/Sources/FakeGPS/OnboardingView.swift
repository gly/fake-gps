import SwiftUI

/// A guided checklist shown until the app is connected to a device. It detects
/// each prerequisite live (iPhone plugged in, tunnel running) and offers the
/// action for the current step — so a new user never has to read the docs.
///
/// The Python engine is bundled inside the app, so there is nothing to download;
/// the only steps are the ones macOS/Apple require a human to do.
struct OnboardingView: View {
    @EnvironmentObject var config: AppConfig
    @EnvironmentObject var sidecar: Sidecar
    @EnvironmentObject var tunnel: TunnelManager
    @EnvironmentObject var devices: DeviceWatcher

    private var engineReady: Bool { config.isValid }
    private var deviceReady: Bool { devices.hasDevice }
    private var tunnelReady: Bool { tunnel.isUp }
    private var canConnect: Bool { engineReady && tunnelReady }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                step(
                    n: 1, done: engineReady,
                    title: "引擎就绪",
                    detail: engineReady
                        ? "所需的一切都已内置在应用中。"
                        : "运行时缺失：\(config.locationDescription)。"
                )
                step(
                    n: 2, done: deviceReady,
                    title: deviceReady ? "已检测到 iPhone" : "连接你的 iPhone",
                    detail: deviceReady
                        ? "已发现连接的设备。"
                        : "用 USB 数据线连接手机并点按「信任」，然后在 设置 ▸ 隐私与安全性 ▸ 开发者模式 中打开开发者模式。"
                ) {
                    if !deviceReady {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("等待设备接入…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                step(
                    n: 3, done: tunnelReady,
                    title: "启动安全隧道",
                    detail: tunnelReady
                        ? "隧道守护进程正在运行。"
                        : "向设备建立开发者隧道，需要输入一次密码。"
                ) {
                    if !tunnelReady {
                        Button("启动隧道（需要管理员）…") { tunnel.startTunneld() }
                            .disabled(!engineReady)
                    }
                }
                step(
                    n: 4, done: false, isFinal: true,
                    title: "连接",
                    detail: "将应用与设备链接，即可开始模拟定位。"
                ) {
                    connectControl
                }
            }
            .padding(20)
        }
        .frame(width: 460)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.quaternary))
        .shadow(radius: 30)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "location.fill.viewfinder")
                .font(.system(size: 30))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("设置 iOS Fake GPS").font(.title3.bold())
                Text("几步简单操作即可开始。").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }

    @ViewBuilder
    private var connectControl: some View {
        switch sidecar.state {
        case .launching:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("连接中…") }
        case let .failed(msg):
            VStack(alignment: .leading, spacing: 6) {
                Text(msg).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Button("重试") { sidecar.start() }.disabled(!canConnect)
            }
        default:
            Button("连接") { sidecar.start() }
                .buttonStyle(.borderedProminent)
                .disabled(!canConnect)
        }
    }

    @ViewBuilder
    private func step(
        n: Int, done: Bool, isFinal: Bool = false,
        title: String, detail: String,
        @ViewBuilder action: () -> some View = { EmptyView() }
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(done ? Color.green : Color.secondary.opacity(0.25))
                    .frame(width: 26, height: 26)
                if done {
                    Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
                } else {
                    Text("\(n)").font(.caption.bold()).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                action()
            }
            Spacer(minLength: 0)
        }
    }
}
