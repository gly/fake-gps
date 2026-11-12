import CoreLocation
import Foundation

/// Geodesy helpers for interpolating motion along a multi-point route.
///
/// Distances use the haversine formula; intermediate points are interpolated
/// linearly in lat/lon, which is accurate enough at the per-tick granularity we
/// move (tens of metres between updates).
enum Geo {
    static let earthRadius = 6_371_000.0 // metres

    static func radians(_ deg: Double) -> Double { deg * .pi / 180 }
    static func degrees(_ rad: Double) -> Double { rad * 180 / .pi }

    /// Great-circle distance between two coordinates, in metres.
    static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let dLat = radians(b.latitude - a.latitude)
        let dLon = radians(b.longitude - a.longitude)
        let lat1 = radians(a.latitude)
        let lat2 = radians(b.latitude)
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }

    /// Initial bearing from `a` to `b`, in degrees (0 = north, clockwise).
    static func bearing(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let lat1 = radians(a.latitude)
        let lat2 = radians(b.latitude)
        let dLon = radians(b.longitude - a.longitude)
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return (degrees(atan2(y, x)) + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Point a fraction `t` (0...1) of the way from `a` to `b`.
    static func interpolate(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, _ t: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: a.latitude + (b.latitude - a.latitude) * t,
            longitude: a.longitude + (b.longitude - a.longitude) * t
        )
    }

    /// Total length of a polyline in metres.
    static func pathLength(_ points: [CLLocationCoordinate2D]) -> Double {
        guard points.count > 1 else { return 0 }
        var total = 0.0
        for i in 0 ..< (points.count - 1) {
            total += distance(points[i], points[i + 1])
        }
        return total
    }

    /// Coordinate at arc-length `s` metres along the polyline (clamped to its ends).
    static func point(along points: [CLLocationCoordinate2D], at s: Double) -> CLLocationCoordinate2D? {
        guard let first = points.first else { return nil }
        guard points.count > 1 else { return first }
        if s <= 0 { return first }
        var remaining = s
        for i in 0 ..< (points.count - 1) {
            let segLen = distance(points[i], points[i + 1])
            if segLen == 0 {
                // Skip zero-length segments (duplicate waypoints).
                continue
            }
            if remaining <= segLen {
                return interpolate(points[i], points[i + 1], remaining / segLen)
            }
            remaining -= segLen
        }
        // Past the end — clamp to the last point.
        return points.last
    }

    // MARK: - 火星坐标（GCJ-02）换算

    /// 判断是否在中国大陆坐标加密范围内（粗略矩形）。
    static func isOutOfChina(_ c: CLLocationCoordinate2D) -> Bool {
        c.longitude < 72.004 || c.longitude > 137.8347
            || c.latitude < 0.8293 || c.latitude > 55.8271
    }

    /// WGS-84（GPS 原始坐标）→ GCJ-02（火星坐标）。国测局标准偏移算法。
    static func wgs84ToGcj02(_ c: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        if isOutOfChina(c) { return c }
        let a = 6_378_245.0
        let ee = 0.006_693_421_622_965_943_23
        let dLat = transformLat(x: c.longitude - 105.0, y: c.latitude - 35.0)
        let dLon = transformLon(x: c.longitude - 105.0, y: c.latitude - 35.0)
        let radLat = c.latitude / 180.0 * .pi
        var magic = sin(radLat)
        magic = 1 - ee * magic * magic
        let sqrtMagic = sqrt(magic)
        let dLat2 = (dLat * 180.0) / ((a * (1 - ee)) / (magic * sqrtMagic) * .pi)
        let dLon2 = (dLon * 180.0) / (a / sqrtMagic * cos(radLat) * .pi)
        return CLLocationCoordinate2D(latitude: c.latitude + dLat2, longitude: c.longitude + dLon2)
    }

    /// GCJ-02（火星坐标）→ WGS-84（GPS 原始坐标）。
    /// 反向迭代逼近，三次迭代误差已在厘米级以下。
    static func gcj02ToWgs84(_ c: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        var wgs = c
        for _ in 0 ..< 3 {
            let gcj = wgs84ToGcj02(wgs)
            wgs.latitude -= gcj.latitude - c.latitude
            wgs.longitude -= gcj.longitude - c.longitude
        }
        return wgs
    }

    private static func transformLat(x: Double, y: Double) -> Double {
        var ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        ret += (20.0 * sin(y * .pi) + 40.0 * sin(y / 3.0 * .pi)) * 2.0 / 3.0
        ret += (160.0 * sin(y / 12.0 * .pi) + 320.0 * sin(y * .pi / 30.0)) * 2.0 / 3.0
        return ret
    }

    private static func transformLon(x: Double, y: Double) -> Double {
        var ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        ret += (20.0 * sin(x * .pi) + 40.0 * sin(x / 3.0 * .pi)) * 2.0 / 3.0
        ret += (150.0 * sin(x / 12.0 * .pi) + 300.0 * sin(x / 30.0 * .pi)) * 2.0 / 3.0
        return ret
    }

    /// Apply a small random horizontal jitter (metres) to mimic real GPS noise.
    static func jitter(_ c: CLLocationCoordinate2D, metres: Double, seed: Double) -> CLLocationCoordinate2D {
        guard metres > 0 else { return c }
        // Deterministic-ish offset derived from seed so we don't import RNG state.
        let angle = (seed.truncatingRemainder(dividingBy: 1)) * 2 * .pi
        let r = metres * (0.5 + 0.5 * abs(sin(seed * 12.9898)))
        let dLat = (r * cos(angle)) / earthRadius
        let dLon = (r * sin(angle)) / (earthRadius * cos(radians(c.latitude)))
        return CLLocationCoordinate2D(
            latitude: c.latitude + degrees(dLat),
            longitude: c.longitude + degrees(dLon)
        )
    }

    /// 在 `c` 周围半径 `radius` 米内均匀随机取一个点（真随机，每次不同）。
    /// 用 `sqrt` 保证圆内均匀分布（避免集中在圆心附近）。
    static func randomOffset(_ c: CLLocationCoordinate2D, radius: Double) -> CLLocationCoordinate2D {
        guard radius > 0 else { return c }
        let r = radius * sqrt(Double.random(in: 0 ... 1))
        let angle = Double.random(in: 0 ..< (2 * .pi))
        let dLat = (r * cos(angle)) / earthRadius
        let dLon = (r * sin(angle)) / (earthRadius * cos(radians(c.latitude)))
        return CLLocationCoordinate2D(
            latitude: c.latitude + degrees(dLat),
            longitude: c.longitude + degrees(dLon)
        )
    }
}
