import Combine
import CoreLocation
import Foundation

/// A point the user dropped on the map.
struct Waypoint: Identifiable, Hashable {
    let id = UUID()
    var coordinate: CLLocationCoordinate2D

    static func == (l: Waypoint, r: Waypoint) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

enum PlaybackState: Equatable {
    case idle
    case playing
    case paused
}

/// Drives simulated movement along the route at a chosen speed and pushes each
/// interpolated coordinate to the device through the `Sidecar`.
///
/// This is the part that makes us Lockito-equivalent: we own the interpolation,
/// so speed, pause, loop and GPS jitter are all under our control rather than
/// relying on the device's own GPX timing.
@MainActor
final class SimulationEngine: ObservableObject {
    @Published var waypoints: [Waypoint] = []
    @Published var speedKmh: Double = 50      // target ground speed
    @Published var loop: Bool = false
    @Published var jitterMetres: Double = 0   // 0 = perfectly smooth
    /// 随机偏移半径（米）：0 表示关闭随机；最大 1000 米。
    /// 大于 0 时，每次点「立即更新」会在选中位置该半径内随机取一个点。
    @Published var randomRadiusMetres: Double = 0
    /// 火星坐标纠偏：中国大陆地图显示的是 GCJ-02 坐标，模拟定位按
    /// WGS-84 原始坐标注入；开启后自动换算，消除几百米偏移。境外自动跳过。
    @Published var marsCorrection: Bool = true

    @Published private(set) var playback: PlaybackState = .idle
    /// 地图 / 搜索选中的待应用位置（尚未发送到设备）。
    @Published private(set) var selectedCoordinate: CLLocationCoordinate2D?
    /// 已应用到设备的位置。
    @Published private(set) var currentCoordinate: CLLocationCoordinate2D?
    /// 最近一次「立即更新」随机取到的点；未开启随机或尚未应用时为 nil。
    @Published private(set) var appliedRandomCoordinate: CLLocationCoordinate2D?
    @Published private(set) var progress: Double = 0 // 0...1 along the route

    private let sidecar: Sidecar
    private var timer: Timer?
    private var travelled: Double = 0          // metres along the route
    private let tick: TimeInterval = 1.0       // update cadence (s)
    private var jitterSeed: Double = 0

    /// 选中位置的反向地理编码结果（如「广东省 广州市 天河区 XX路」）。
    @Published private(set) var selectedPlaceName: String?
    private let geocoder = CLGeocoder()

    private enum Prefs {
        static let latKey = "lastAppliedLatitude"
        static let lonKey = "lastAppliedLongitude"
    }

    init(sidecar: Sidecar) {
        self.sidecar = sidecar
        // 启动时把上次「立即更新」的位置作为默认选中位置。
        let d = UserDefaults.standard
        if let lat = d.object(forKey: Prefs.latKey) as? Double,
           let lon = d.object(forKey: Prefs.lonKey) as? Double {
            selectedCoordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            if let restored = selectedCoordinate { reverseGeocode(restored) }
        }
    }

    deinit {
        timer?.invalidate()
    }

    var coordinates: [CLLocationCoordinate2D] { waypoints.map(\.coordinate) }
    var totalDistance: Double { Geo.pathLength(coordinates) }

    // MARK: - Editing

    func addWaypoint(_ c: CLLocationCoordinate2D) {
        waypoints.append(Waypoint(coordinate: c))
    }

    func clearRoute() {
        stop()
        waypoints.removeAll()
        currentCoordinate = nil
        progress = 0
    }

    // MARK: - 选择与应用

    /// 地图点击 / 搜索选择位置（只记录，不更新设备）。
    /// 开启随机偏移时，随机发生在点「立即更新」时，围绕这里选中的位置取点。
    func select(_ c: CLLocationCoordinate2D) {
        selectedCoordinate = c
        appliedRandomCoordinate = nil
        reverseGeocode(c)
    }

    /// 反向地理编码：把选中坐标换成具体位置名，供侧边栏展示。
    /// 传入的就是地图显示坐标（GCJ-02），与 CLGeocoder 的期望一致。
    private func reverseGeocode(_ c: CLLocationCoordinate2D) {
        geocoder.cancelGeocode()
        selectedPlaceName = nil
        let location = CLLocation(latitude: c.latitude, longitude: c.longitude)
        geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, _ in
            guard let pm = placemarks?.first else { return }
            var parts: [String] = []
            if let admin = pm.administrativeArea { parts.append(admin) }
            if let locality = pm.locality, locality != pm.administrativeArea { parts.append(locality) }
            if let sub = pm.subLocality { parts.append(sub) }
            if let name = pm.name { parts.append(name) }
            let text = parts.joined(separator: " ")
            Task { @MainActor [weak self] in
                self?.selectedPlaceName = text.isEmpty ? nil : text
            }
        }
    }

    /// 「立即更新」：把当前选中的位置应用到设备，并持久化供下次启动默认使用。
    /// 开启随机偏移时，这一刻才在选中位置周围随机取点，结果由
    /// `appliedRandomCoordinate` 公布给界面。
    /// 开启火星坐标纠偏时，中国大陆内的位置会先从 GCJ-02 换算成
    /// WGS-84 再下发，否则设备上会偏移几百米。
    /// 返回指令 ID，调用方可据此等待设备的 `ok` 回执；发送失败时返回 nil。
    @discardableResult
    func applySelected() -> Int? {
        guard let anchor = selectedCoordinate, sidecar.state.isReady else { return nil }
        // 随机偏移在 GCJ 坐标系内进行，与地图显示一致
        let chosen = randomRadiusMetres > 0
            ? Geo.randomOffset(anchor, radius: randomRadiusMetres)
            : anchor
        // 地图选中的是 GCJ-02（火星坐标）；模拟定位按 WGS-84 原始坐标注入，
        // 需要先换算，否则设备上会偏移几百米。境外位置无需换算。
        let target = (marsCorrection && !Geo.isOutOfChina(chosen))
            ? Geo.gcj02ToWgs84(chosen)
            : chosen
        guard let id = sidecar.setLocation(target.latitude, target.longitude) else { return nil }
        currentCoordinate = target
        appliedRandomCoordinate = randomRadiusMetres > 0 ? chosen : nil
        // 持久化保存地图显示坐标（GCJ-02），下次启动标记位置不变。
        let d = UserDefaults.standard
        d.set(chosen.latitude, forKey: Prefs.latKey)
        d.set(chosen.longitude, forKey: Prefs.lonKey)
        return id
    }

    /// 最近一次随机取点与选中位置之间的距离（米）；未随机应用时为 nil。
    var appliedRandomDistance: Double? {
        guard let anchor = selectedCoordinate, let random = appliedRandomCoordinate else {
            return nil
        }
        return Geo.distance(anchor, random)
    }

    // MARK: - Route playback

    func play() {
        guard sidecar.state.isReady else { return }
        guard coordinates.count >= 2 else {
            // A single point behaves like selecting it.
            if let only = coordinates.first { select(only) }
            return
        }
        if playback == .idle { travelled = 0 }
        playback = .playing
        scheduleTimer()
        step() // fire immediately so motion starts without a 1s delay
    }

    func pause() {
        guard playback == .playing else { return }
        playback = .paused
        timer?.invalidate()
        timer = nil
    }

    func stop() {
        playback = .idle
        travelled = 0
        progress = 0
        timer?.invalidate()
        timer = nil
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: tick, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.step() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func step() {
        let total = totalDistance
        guard total > 0 else { stop(); return }

        let speedMps = speedKmh * 1000 / 3600
        travelled += speedMps * tick

        if travelled >= total {
            if loop {
                travelled = travelled.truncatingRemainder(dividingBy: total)
            } else {
                travelled = total
                emitCurrent(total: total)
                stop()
                return
            }
        }
        emitCurrent(total: total)
    }

    private func emitCurrent(total: Double) {
        guard var c = Geo.point(along: coordinates, at: travelled) else { return }
        if jitterMetres > 0 {
            jitterSeed += 0.37
            c = Geo.jitter(c, metres: jitterMetres, seed: jitterSeed)
        }
        currentCoordinate = c
        progress = total == 0 ? 0 : min(1, travelled / total)
        sidecar.setLocation(c.latitude, c.longitude)
    }

    // MARK: - Readouts

    var estimatedDurationSeconds: Double {
        let speedMps = speedKmh * 1000 / 3600
        return speedMps > 0 ? totalDistance / speedMps : 0
    }
}
