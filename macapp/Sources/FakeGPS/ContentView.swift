import AppKit
import CoreLocation
import MapKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var config: AppConfig
    @EnvironmentObject var sidecar: Sidecar
    @EnvironmentObject var engine: SimulationEngine
    @EnvironmentObject var tunnel: TunnelManager

    @StateObject private var mapController = MapController()
    @StateObject private var search = PlaceSearch()
    /// 搜索框焦点：点击地图等其它区域时置为 false 取消聚焦。
    @FocusState private var searchFocused: Bool
    /// 已发送但尚未收到设备回执的「立即更新」指令。
    @State private var pendingApplyID: Int?
    @State private var applyNotice: ApplyNotice?
    @State private var noticeTask: Task<Void, Never>?

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 300, idealWidth: 330, maxWidth: 420)
            mapArea
                .frame(minWidth: 480, minHeight: 480)
        }
        .frame(minWidth: 880, minHeight: 560)
        .overlay {
            if !sidecar.state.isReady {
                ZStack {
                    // 遮罩只是视觉效果，必须允许点击穿透，否则会挡住地图和搜索框。
                    Rectangle().fill(.black.opacity(0.25)).ignoresSafeArea()
                        .allowsHitTesting(false)
                    OnboardingView()
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: sidecar.state.isReady)
        .onChange(of: sidecar.lastAcknowledgedID) { _, ack in
            // 只有「立即更新」那一笔设备的回执才算成功；播放路线时的回调忽略。
            guard let ack, ack == pendingApplyID else { return }
            pendingApplyID = nil
            if let offset = engine.appliedRandomDistance {
                showNotice(.success(String(format: "已更新设备位置（随机偏移 %.0f 米）", offset)))
            } else {
                showNotice(.success("已更新设备位置"))
            }
        }
        .onChange(of: sidecar.state) { _, state in
            if case .failed = state { pendingApplyID = nil }
        }
        .onChange(of: searchFocused) { _, focused in
            // 从其它应用切回来点击搜索框时，系统可能并未真正激活本应用
            // （macOS 14+ 协作激活会拒绝后台应用的立即激活请求），
            // 光标显示了但键盘事件仍发给之前的应用。
            // 立即激活一次，稍等片刻再补一次，确保键盘路由到本窗口。
            if focused {
                NSApp.activate(ignoringOtherApps: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
    }

    private var mapArea: some View {
        MapView(
            waypoints: engine.waypoints,
            markerCoordinate: engine.appliedRandomCoordinate ?? engine.selectedCoordinate,
            controller: mapController,
            onTap: handleTap
        )
        .overlay(alignment: .top) { searchOverlay }
    }

    // MARK: - 搜索栏

    private var searchOverlay: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索地址或地点…", text: $search.query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { search.run(near: mapController.currentCenter?()) }
                    .onChange(of: search.query) { _, _ in search.run(near: mapController.currentCenter?()) }
                if search.isSearching {
                    ProgressView().controlSize(.small)
                } else if !search.query.isEmpty {
                    Button { search.clear() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))

            if !search.results.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(search.results.prefix(8).enumerated()), id: \.offset) { _, item in
                        Button { choose(item) } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.displayTitle).fontWeight(.medium)
                                Text(item.displaySubtitle).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 5).padding(.horizontal, 8)
                        Divider()
                    }
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: 360)
        .padding(10)
    }

    private func choose(_ item: MKMapItem) {
        let coord = item.coordinate
        mapController.center(on: coord, meters: 1_200)
        engine.select(coord)
        searchFocused = false  // 选中结果后取消聚焦
        search.clear()
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                connectionSection
                Divider()
                teleportSection
                Divider()
                statusFooter
            }
            .padding(16)
        }
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("设备").font(.headline)

            statusRow(
                ok: tunnel.isUp,
                label: tunnel.isUp ? "隧道守护进程运行中" : "隧道守护进程未运行"
            )
            if !tunnel.isUp {
                Button("启动隧道（需要管理员）…") { tunnel.startTunneld() }
                Text("需要输入你的密码。请保持 iPhone 已连接并开启开发者模式。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            switch sidecar.state {
            case .stopped:
                Button("连接") { sidecar.start() }
                    .disabled(!tunnel.isUp || !config.isValid)
            case .launching:
                HStack { ProgressView().controlSize(.small); Text("连接中…") }
            case let .ready(dev):
                statusRow(ok: true, label: "设备已连接")
                VStack(alignment: .leading, spacing: 3) {
                    Text(dev.modelName).font(.body.weight(.medium))
                    if let n = dev.deviceName {
                        Text("名称：\(n)").font(.caption).foregroundStyle(.secondary)
                    }
                    if let v = dev.productVersion {
                        Text("iOS \(v)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button("断开连接") { engine.stop(); sidecar.stop() }
            case let .failed(msg):
                statusRow(ok: false, label: "连接失败")
                Text(msg).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                Button("重试") { sidecar.start() }.disabled(!tunnel.isUp)
            }

            if !config.isValid {
                Text("未找到运行时：\(config.locationDescription)")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var teleportSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("传送").font(.headline)

            Text("点击地图或搜索选择位置，然后点「立即更新」应用到设备。")
                .font(.caption).foregroundStyle(.secondary)

            Toggle("选中位置 100 米内随机", isOn: $engine.randomOffset)

            if engine.randomOffset {
                Text("已开启：每次点「立即更新」会在选中位置 100 米范围内随机取一个点。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Toggle("火星坐标纠偏（中国大陆）", isOn: $engine.marsCorrection)
            if engine.marsCorrection {
                Text("已开启：中国大陆地图使用 GCJ-02 火星坐标，会自动换算成 WGS-84 原始坐标再下发，消除几百米偏移。境外位置自动跳过。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let c = engine.selectedCoordinate {
                Text(String(format: "已选择：%.6f, %.6f", c.latitude, c.longitude))
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }

            if let r = engine.appliedRandomCoordinate {
                Text(
                    String(
                        format: "已随机：%.6f, %.6f（距选中点 %.0f 米）",
                        r.latitude, r.longitude, engine.appliedRandomDistance ?? 0
                    )
                )
                .font(.caption.monospaced()).foregroundStyle(.green)
            }

            Button {
                guard let id = engine.applySelected() else {
                    showNotice(.failure("更新失败：设备连接已断开"))
                    return
                }
                pendingApplyID = id
            } label: {
                Label("立即更新", systemImage: "arrow.up.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(engine.selectedCoordinate == nil || !sidecar.state.isReady)

            if let applyNotice {
                noticeRow(applyNotice)
                    .transition(.opacity)
            }

            if engine.selectedCoordinate != nil && !sidecar.state.isReady {
                Text("连接设备后才能更新位置。")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var statusFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let c = engine.currentCoordinate {
                Text(String(format: "当前：%.6f, %.6f", c.latitude, c.longitude))
                    .font(.caption.monospaced())
            }
            if let err = sidecar.lastError, !sidecar.state.isFailed {
                Text(err).font(.caption).foregroundStyle(.orange)
            }
            if sidecar.state.isReady {
                Button("重置设备位置") { sidecar.clearLocation(); engine.stop() }
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Helpers

    private func handleTap(_ c: CLLocationCoordinate2D) {
        searchFocused = false  // 点击地图 = 取消搜索聚焦
        engine.select(c)
    }

    /// 显示一条自动消失的提示（成功为绿色，失败为橙色）。
    private func showNotice(_ notice: ApplyNotice) {
        noticeTask?.cancel()
        withAnimation(.easeInOut(duration: 0.15)) { applyNotice = notice }
        noticeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) { applyNotice = nil }
        }
    }

    @ViewBuilder
    private func noticeRow(_ notice: ApplyNotice) -> some View {
        switch notice {
        case let .success(text):
            Label(text, systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case let .failure(text):
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
        }
    }

    private func statusRow(ok: Bool, label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .red)
            Text(label).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private enum ApplyNotice: Equatable {
    case success(String)
    case failure(String)
}

private extension SidecarState {
    var isFailed: Bool { if case .failed = self { return true }; return false }
}
