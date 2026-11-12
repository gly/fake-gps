import AppKit
import CoreLocation
import MapKit
import SwiftUI

/// A MapKit map that lets the user click to drop route waypoints, renders the
/// route polyline, and shows a live marker at the simulated position.
struct MapView: NSViewRepresentable {
    var waypoints: [Waypoint]
    /// 地图上显示的主标记（当前选中的位置）。
    var markerCoordinate: CLLocationCoordinate2D?
    var controller: MapController
    /// Called with the map coordinate the user clicked.
    var onTap: (CLLocationCoordinate2D) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> MKMapView {
        let map = NoFirstResponderMapView()
        map.delegate = context.coordinator
        map.showsZoomControls = true
        map.showsCompass = true
        map.showsPitchControl = true
        map.isZoomEnabled = true
        map.isScrollEnabled = true
        map.isRotateEnabled = true
        map.isPitchEnabled = true
        // Single-click drops a waypoint. We add a double-click recognizer and
        // make the single-click require it to fail, so that double-click-to-zoom
        // (handled by MapKit internally) does NOT also drop a waypoint.
        let click = NSClickGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleClick(_:))
        )
        click.numberOfClicksRequired = 1
        click.delaysPrimaryMouseButtonEvents = false

        let doubleClick = NSClickGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleClick(_:))
        )
        doubleClick.numberOfClicksRequired = 2
        doubleClick.delaysPrimaryMouseButtonEvents = false
        click.shouldRequireFailure(of: doubleClick)

        map.addGestureRecognizer(click)
        map.addGestureRecognizer(doubleClick)
        context.coordinator.mapView = map
        context.coordinator.bindController()
        // 默认区域：中国大陆全景；拿到 Mac 当前位置后会自动居中过去。
        map.setRegion(
            MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 34.5, longitude: 108.0),
                span: MKCoordinateSpan(latitudeDelta: 28, longitudeDelta: 28)
            ),
            animated: false
        )
        context.coordinator.startLocation()
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.sync(waypoints: waypoints, current: markerCoordinate)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate, CLLocationManagerDelegate {
        var parent: MapView
        weak var mapView: MKMapView?
        private var routeOverlay: MKPolyline?
        private let currentAnnotation = MKPointAnnotation()
        private var hasCurrent = false
        private let locationManager = CLLocationManager()
        private var centeredOnUser = false

        init(_ parent: MapView) {
            self.parent = parent
            currentAnnotation.title = "选中位置"
        }

        /// Expose map commands to SwiftUI through the shared MapController.
        func bindController() {
            let controller = parent.controller
            controller.recenter = { [weak self] coord, meters in
                guard let map = self?.mapView else { return }
                map.setRegion(
                    MKCoordinateRegion(center: coord, latitudinalMeters: meters, longitudinalMeters: meters),
                    animated: true
                )
            }
            controller.zoomBy = { [weak self] factor in
                guard let map = self?.mapView else { return }
                var region = map.region
                region.span = MKCoordinateSpan(
                    latitudeDelta: min(120, max(0.0008, region.span.latitudeDelta * factor)),
                    longitudeDelta: min(120, max(0.0008, region.span.longitudeDelta * factor))
                )
                map.setRegion(region, animated: true)
            }
            controller.currentCenter = { [weak self] in self?.mapView?.region.center }
        }

        @objc func handleClick(_ gr: NSClickGestureRecognizer) {
            guard let map = mapView else { return }
            let point = gr.location(in: map)
            let coord = map.convert(point, toCoordinateFrom: map)
            parent.onTap(coord)
        }

        // MARK: - Mac 当前定位

        /// 请求 Mac 的当前位置：授权后第一次拿到定位就把地图居中过去，
        /// 并显示系统自带的蓝点标记。未授权时地图保持默认的中国全境视图。
        func startLocation() {
            locationManager.delegate = self
            locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            locationManager.requestWhenInUseAuthorization()
            locationManager.startUpdatingLocation()
        }

        func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
            guard let map = mapView, let loc = locations.last else { return }
            map.showsUserLocation = true
            guard !centeredOnUser else { return }
            centeredOnUser = true
            map.setRegion(
                MKCoordinateRegion(
                    center: loc.coordinate,
                    latitudinalMeters: 2_000,
                    longitudinalMeters: 2_000
                ),
                animated: true
            )
        }

        /// No-op: lets MapKit's built-in double-click-to-zoom handle the gesture.
        @objc func handleDoubleClick(_ gr: NSClickGestureRecognizer) {}

        func sync(waypoints: [Waypoint], current: CLLocationCoordinate2D?) {
            guard let map = mapView else { return }

            // Waypoint pins: rebuild only the numbered waypoint annotations.
            let existing = map.annotations.compactMap { $0 as? WaypointAnnotation }
            map.removeAnnotations(existing)
            for (i, wp) in waypoints.enumerated() {
                let a = WaypointAnnotation()
                a.coordinate = wp.coordinate
                a.title = "\(i + 1)"
                map.addAnnotation(a)
            }

            // Route polyline.
            if let old = routeOverlay { map.removeOverlay(old) }
            if waypoints.count >= 2 {
                let line = MKPolyline(coordinates: waypoints.map(\.coordinate), count: waypoints.count)
                map.addOverlay(line)
                routeOverlay = line
            } else {
                routeOverlay = nil
            }

            // Live simulated-position marker.
            if let current {
                currentAnnotation.coordinate = current
                if !hasCurrent {
                    map.addAnnotation(currentAnnotation)
                    hasCurrent = true
                }
            } else if hasCurrent {
                map.removeAnnotation(currentAnnotation)
                hasCurrent = false
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let line = overlay as? MKPolyline {
                let r = MKPolylineRenderer(polyline: line)
                r.strokeColor = .systemBlue
                r.lineWidth = 4
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation === currentAnnotation {
                let id = "current"
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView
                    ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
                v.annotation = annotation
                v.markerTintColor = .systemGreen
                v.glyphImage = NSImage(systemSymbolName: "location.fill", accessibilityDescription: nil)
                v.displayPriority = .required
                return v
            }
            if annotation is WaypointAnnotation {
                let id = "wp"
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView
                    ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
                v.annotation = annotation
                v.markerTintColor = .systemBlue
                v.glyphText = (annotation as? WaypointAnnotation)?.title ?? ""
                return v
            }
            return nil
        }
    }
}

/// Distinguishes user-placed waypoints from the live position marker.
final class WaypointAnnotation: MKPointAnnotation {}

/// MKMapView 会抢夺第一响应者（键盘焦点），导致窗口里的 SwiftUI 输入框
/// 无法输入。禁用它接受焦点的能力，键盘焦点留给搜索框。
final class NoFirstResponderMapView: MKMapView {
    override var acceptsFirstResponder: Bool { false }
}
