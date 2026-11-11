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
    }

    private var mapArea: some View {
        MapView(
            waypoints: engine.waypoints,
            currentCoordinate: engine.currentCoordinate,
            controller: mapController,
            onTap: handleTap
        )
        .overlay(alignment: .top) { searchOverlay }
        .overlay(alignment: .bottomTrailing) { locateButton }
    }

    /// 地图右下角的「回到当前位置」按钮。
    private var locateButton: some View {
        Button {
            searchFocused = false  // 点击地图区域 = 取消搜索聚焦
            mapController.locateCurrentLocation()
        } label: {
            Image(systemName: "location.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .background(.regularMaterial, in: Circle())
        .overlay(Circle().strokeBorder(.quaternary))
        .padding(12)
        .help("定位到当前位置")
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
        engine.teleport(to: coord)
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
                statusRow(ok: true, label: dev.display)
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

            Text("点击地图或搜索地址，将设备瞬间传送到该位置。")
                .font(.caption).foregroundStyle(.secondary)

            Toggle("选中位置 100 米内随机", isOn: $engine.randomOffset)

            if engine.randomOffset {
                Text("已开启：每次传送会在选中位置 100 米范围内随机取一个点。")
                    .font(.caption).foregroundStyle(.secondary)
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
        engine.teleport(to: c)
    }

    private func statusRow(ok: Bool, label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .red)
            Text(label).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private extension SidecarState {
    var isFailed: Bool { if case .failed = self { return true }; return false }
}
