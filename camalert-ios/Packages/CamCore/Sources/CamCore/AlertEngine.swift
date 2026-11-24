import Foundation

/// How close a camera is when we speak. Same stages as the web app:
/// half a mile, a quarter mile, then "now".
public enum AlertStage: Int, CaseIterable, Comparable {
    case far = 0
    case near = 1
    case imminent = 2

    public var triggerMeters: Double {
        switch self {
        case .far: return 805       // half a mile
        case .near: return 402      // a quarter mile
        case .imminent: return 137  // about 150 yards
        }
    }

    public static func < (lhs: AlertStage, rhs: AlertStage) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct AlertEvent: Equatable {
    public let camera: SpeedCamera
    public let stage: AlertStage
    public let distance: Double
    public let speedMph: Double

    public init(camera: SpeedCamera, stage: AlertStage, distance: Double, speedMph: Double) {
        self.camera = camera
        self.stage = stage
        self.distance = distance
        self.speedMph = speedMph
    }

    /// True when the driver is clearly over the camera's limit.
    public var overLimit: Bool {
        guard let limit = camera.limitMph else { return false }
        return speedMph > Double(limit) + 2
    }

    private var label: String {
        camera.kind == .average ? "Average speed cameras" : "Speed camera"
    }

    private var limitSentence: String {
        guard let limit = camera.limitMph else { return "" }
        return " Limit \(limit)."
    }

    /// What the voice says.
    public var spokenText: String {
        let slow = overLimit ? "Slow down. " : ""
        switch stage {
        case .far:
            return "\(label) ahead in half a mile.\(limitSentence)"
        case .near:
            return "\(slow)\(label) in a quarter mile.\(limitSentence)"
        case .imminent:
            return "\(slow)\(label) now.\(limitSentence)"
        }
    }

    /// Short headline for banners (phone HUD and the CarPlay alert).
    public var title: String {
        switch stage {
        case .far: return "\(label) · ½ mi"
        case .near: return "\(label) · ¼ mi"
        case .imminent: return "\(label) NOW"
        }
    }

    public var subtitle: String {
        var parts: [String] = []
        if let limit = camera.limitMph { parts.append("Limit \(limit) mph") }
        if overLimit { parts.append("Slow down") }
        return parts.joined(separator: " · ")
    }
}

public struct UpcomingCamera: Equatable {
    public let camera: SpeedCamera
    public let distance: Double

    public init(camera: SpeedCamera, distance: Double) {
        self.camera = camera
        self.distance = distance
    }
}

public struct AlertResult {
    /// New alerts to speak/show right now (usually empty).
    public var events: [AlertEvent]
    /// The nearest camera ahead, for the HUD.
    public var next: UpcomingCamera?
    /// Where the fix sits on the route, when a route is set and the fix is on it.
    public var snap: RouteIndex.Snap?
}

/// Decides which cameras are "ahead" and when to alert.
///
/// - With a route: cameras within 25 m of the route line, by distance along the route.
/// - Without one (or when off route): cameras inside a forward cone from the GPS heading
///   (within 50 degrees, and within max(70 m, 30% of distance) sideways).
/// - Alerts only fire above 10 mph unless `passengerMode` is on.
public final class AlertEngine {
    public var cameras: [SpeedCamera] = []
    public var passengerMode = false
    /// 10 mph in metres per second.
    public var minSpeedMps = 4.47
    /// Beyond this distance from the route we fall back to the heading cone.
    public var offRouteTolerance = 120.0
    /// How long a camera stays "already announced" after its latest stage.
    public var memorySeconds: TimeInterval = 300

    private var route: RouteIndex?
    private var routeCameras: [RouteCamera] = []
    private var lastSegment: Int?
    private var fired: [Int64: (stage: AlertStage, at: Date)] = [:]

    public init() {}

    /// Set the active route and the cameras found along it (pass nil to clear).
    public func setRoute(_ route: RouteIndex?, cameras routeCameras: [RouteCamera]) {
        self.route = route
        self.routeCameras = route == nil ? [] : routeCameras
        self.lastSegment = nil
    }

    /// Forget what has been announced (call when a new trip starts).
    public func resetAnnounced() {
        fired.removeAll()
    }

    public func update(location: Coord, course: Double?, speedMps: Double, now: Date = Date()) -> AlertResult {
        let speed = max(0, speedMps)
        let speedMph = speed * 2.23694
        fired = fired.filter { now.timeIntervalSince($0.value.at) < memorySeconds }

        var candidates: [(camera: SpeedCamera, distance: Double)] = []
        var snapUsed: RouteIndex.Snap?

        if let r = route, let snap = currentSnap(location, r), snap.offRoute <= offRouteTolerance {
            snapUsed = snap
            lastSegment = snap.segment
            for rc in routeCameras {
                let d = rc.atMeters - snap.progress
                if d > -15 { candidates.append((rc.camera, max(d, 0))) }
            }
        } else {
            lastSegment = nil
            if let heading = course {
                let reach = AlertStage.far.triggerMeters + 60
                for cam in cameras {
                    let d = Geo.distance(location, cam.coord)
                    if d > reach { continue }
                    let diff = Geo.angleDiff(heading, Geo.bearing(from: location, to: cam.coord))
                    if diff > 50 { continue }
                    let sideways = d * sin(diff * .pi / 180)
                    if sideways > max(70, 0.3 * d) { continue }
                    candidates.append((cam, d))
                }
            }
        }

        candidates.sort { $0.distance < $1.distance }

        let moving = speed >= minSpeedMps || passengerMode
        var events: [AlertEvent] = []
        for c in candidates {
            guard moving, let stage = highestStage(for: c.distance) else { continue }
            if let previous = fired[c.camera.id], previous.stage >= stage { continue }
            fired[c.camera.id] = (stage, now)
            events.append(AlertEvent(camera: c.camera, stage: stage, distance: c.distance, speedMph: speedMph))
        }

        let next = candidates.first.map { UpcomingCamera(camera: $0.camera, distance: $0.distance) }
        return AlertResult(events: events, next: next, snap: snapUsed)
    }

    private func currentSnap(_ p: Coord, _ r: RouteIndex) -> RouteIndex.Snap? {
        if let seg = lastSegment, let s = r.snap(p, aroundSegment: seg), s.offRoute <= offRouteTolerance {
            return s
        }
        return r.snap(p)
    }

    /// The closest stage whose trigger distance we are inside.
    private func highestStage(for distance: Double) -> AlertStage? {
        for stage in AlertStage.allCases.reversed() where distance <= stage.triggerMeters {
            return stage
        }
        return nil
    }
}
