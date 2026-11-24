import Foundation
import MapKit
import CamCore

struct PlannedStep {
    let instruction: String
    /// Metres along the route where this manoeuvre happens.
    let startsAt: Double
}

/// One route option from Apple Maps, with its turn list and the cameras on it.
final class PlannedRoute: Identifiable {
    let id = UUID()
    let mkRoute: MKRoute
    let index: RouteIndex
    let steps: [PlannedStep]

    /// Filled in once camera data for the route's area has loaded.
    var cameras: [RouteCamera] = []
    var camerasReady = false
    var tags: [String] = []

    init(route: MKRoute) {
        mkRoute = route

        let poly = route.polyline
        var coords = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: poly.pointCount)
        poly.getCoordinates(&coords, range: NSRange(location: 0, length: poly.pointCount))
        let idx = RouteIndex(points: coords.map { Coord(lat: $0.latitude, lon: $0.longitude) })
        index = idx

        // Each MapKit step's polyline starts where its instruction applies.
        var built: [PlannedStep] = []
        var segment: Int?
        for s in route.steps where !s.instructions.isEmpty {
            let sp = s.polyline
            guard sp.pointCount > 0 else { continue }
            let first = sp.points()[0].coordinate
            let c = Coord(lat: first.latitude, lon: first.longitude)
            if let snap = idx.snap(c, aroundSegment: segment, back: 0, forward: 1_000_000) {
                segment = snap.segment
                built.append(PlannedStep(instruction: s.instructions, startsAt: snap.progress))
            }
        }
        steps = built
    }

    var polyline: MKPolyline { mkRoute.polyline }
    var travelTime: TimeInterval { mkRoute.expectedTravelTime }
    var distance: CLLocationDistance { mkRoute.distance }
    var hasTolls: Bool { mkRoute.hasTolls }

    var cameraText: String {
        if !camerasReady { return "Checking cameras…" }
        return cameras.count == 1 ? "1 camera" : "\(cameras.count) cameras"
    }

    /// "42 min · 23 mi" (CarPlay route list).
    var summaryLine: String { "\(Fmt.duration(travelTime)) · \(Fmt.distance(distance))" }

    /// "3 cameras · Toll"
    var detailLine: String { "\(cameraText) · \(hasTolls ? "Toll" : "No toll")" }
}
