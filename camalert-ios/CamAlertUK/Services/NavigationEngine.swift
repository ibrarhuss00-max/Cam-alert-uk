import Foundation
import CoreLocation
import MapKit
import Combine
import CamCore

struct RecentPlace: Codable, Equatable {
    let name: String
    let subtitle: String
    let lat: Double
    let lon: Double

    var mapItem: MKMapItem {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon)))
        item.name = name
        return item
    }
}

/// The one brain shared by the iPhone screen and the CarPlay screen.
/// Everything here runs on the main thread.
final class NavigationEngine: ObservableObject {
    static let shared = NavigationEngine()

    enum Mode {
        case idle
        case preview
        case navigating
    }

    // MARK: published state

    @Published private(set) var mode: Mode = .idle
    @Published private(set) var location: CLLocation?
    @Published private(set) var speedMph = 0.0
    @Published private(set) var nearbyCameras: [SpeedCamera] = []
    @Published private(set) var routes: [PlannedRoute] = []
    @Published private(set) var selectedRouteID: UUID?
    @Published private(set) var destination: MKMapItem?
    @Published private(set) var nextCamera: UpcomingCamera?
    @Published private(set) var lastAlert: AlertEvent?
    @Published private(set) var nextInstruction = ""
    @Published private(set) var nextInstructionDistance = 0.0
    @Published private(set) var remainingDistance = 0.0
    @Published private(set) var remainingTime = 0.0
    @Published private(set) var status: String?
    @Published private(set) var isDemo = false
    @Published private(set) var recents: [RecentPlace] = []
    @Published private(set) var gpsDenied = false

    // Saved settings
    @Published var voiceEnabled: Bool {
        didSet {
            UserDefaults.standard.set(voiceEnabled, forKey: "voice")
            speech.enabled = voiceEnabled
        }
    }
    @Published var avoidTolls: Bool {
        didSet { UserDefaults.standard.set(avoidTolls, forKey: "avoidTolls") }
    }
    @Published var passengerMode: Bool {
        didSet {
            UserDefaults.standard.set(passengerMode, forKey: "passenger")
            alerts.passengerMode = passengerMode
        }
    }

    // Events for CarPlay
    let alertSubject = PassthroughSubject<AlertEvent, Never>()
    let guidanceSubject = PassthroughSubject<Void, Never>()
    let arrivalSubject = PassthroughSubject<Void, Never>()
    let rerouteSubject = PassthroughSubject<Void, Never>()

    // MARK: internals

    private(set) var activeRoute: PlannedRoute?
    private(set) var nextStepIndex = -1

    private let alerts = AlertEngine()
    private let store = CameraStore.shared
    private let speech = SpeechService.shared
    private let locationService = LocationService.shared

    private var started = false
    private var lastCoord: Coord?
    private var lastCellCheck: (coord: Coord, at: Date)?
    private var lastNearbyRefresh = Date.distantPast
    private var navSegment: Int?
    private var offRouteCount = 0
    private var lastReroute = Date.distantPast
    private var announced: [Int: Int] = [:]
    private var demoTimer: Timer?
    private var demoDistance = 0.0

    private init() {
        let d = UserDefaults.standard
        voiceEnabled = d.object(forKey: "voice") as? Bool ?? true
        avoidTolls = d.bool(forKey: "avoidTolls")
        passengerMode = d.bool(forKey: "passenger")
        speech.enabled = voiceEnabled
        alerts.passengerMode = passengerMode
        recents = loadRecents()
    }

    var selectedRoute: PlannedRoute? {
        routes.first { $0.id == selectedRouteID }
    }

    // MARK: start

    func start() {
        guard !started else { return }
        started = true
        locationService.onLocation = { [weak self] loc in
            DispatchQueue.main.async { self?.receive(loc) }
        }
        locationService.onAuthChange = { [weak self] status in
            DispatchQueue.main.async { self?.gpsDenied = (status == .denied || status == .restricted) }
        }
        locationService.start()
    }

    private func receive(_ loc: CLLocation) {
        if isDemo { return }
        handle(loc)
    }

    // MARK: every GPS fix

    private func handle(_ loc: CLLocation) {
        location = loc
        let speedMps = max(0, loc.speed)
        speedMph = speedMps * 2.23694
        let course: Double? = (loc.course >= 0 && speedMps > 1.5) ? loc.course : nil
        let c = Coord(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude)
        lastCoord = c

        let result = alerts.update(location: c, course: course, speedMps: speedMps)
        nextCamera = result.next
        for event in result.events { fire(event) }

        if mode == .navigating { updateGuidance(snap: result.snap) }
        ensureCameraCells(near: c)
        refreshNearby(c, force: false)
    }

    private func fire(_ event: AlertEvent) {
        lastAlert = event
        alertSubject.send(event)
        speech.say(event.spokenText, interrupt: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 7) { [weak self] in
            if self?.lastAlert == event { self?.lastAlert = nil }
        }
    }

    // MARK: camera data

    private func ensureCameraCells(near c: Coord) {
        let now = Date()
        if let last = lastCellCheck, now.timeIntervalSince(last.at) < 30, Geo.distance(last.coord, c) < 2_000 {
            return
        }
        lastCellCheck = (c, now)
        let keys = store.cells(near: c, radiusMeters: 12_000)
        useCachedCameras(near: c)
        store.load(keys) { [weak self] gotNew in
            guard gotNew, let self = self, let here = self.lastCoord else { return }
            self.useCachedCameras(near: here)
        }
    }

    private func useCachedCameras(near c: Coord) {
        var keys = Set(store.cells(near: c, radiusMeters: 12_000))
        for r in routes { keys.formUnion(store.cells(along: r.index.points)) }
        alerts.cameras = store.cameras(in: Array(keys))
        refreshNearby(c, force: true)
    }

    private func refreshNearby(_ c: Coord, force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastNearbyRefresh) > 5 else { return }
        lastNearbyRefresh = now

        var list = alerts.cameras
            .filter { Geo.distance($0.coord, c) < 15_000 }
            .sorted { Geo.distance($0.coord, c) < Geo.distance($1.coord, c) }
        list = Array(list.prefix(150))
        if let r = selectedRoute ?? activeRoute {
            var seen = Set(list.map { $0.id })
            for rc in r.cameras where !seen.contains(rc.camera.id) {
                seen.insert(rc.camera.id)
                list.append(rc.camera)
            }
        }
        if Set(list.map { $0.id }) != Set(nearbyCameras.map { $0.id }) {
            nearbyCameras = list
        }
    }

    /// Load camera data along some routes and work out which cameras sit on each.
    private func loadCamerasForRoutes(_ list: [PlannedRoute], then done: @escaping () -> Void) {
        var keys = Set<CameraStore.Key>()
        for r in list { keys.formUnion(store.cells(along: r.index.points)) }
        let keyList = Array(keys)
        store.load(keyList) { [weak self] _ in
            guard let self = self else { return }
            let cams = self.store.cameras(in: keyList)
            self.computeRouteCameras(list, cams: cams, then: done)
        }
    }

    private func computeRouteCameras(_ list: [PlannedRoute], cams: [SpeedCamera], then done: @escaping () -> Void) {
        let group = DispatchGroup()
        for r in list {
            group.enter()
            let idx = r.index
            DispatchQueue.global(qos: .userInitiated).async {
                let found = idx.cameras(from: cams)
                DispatchQueue.main.async {
                    r.cameras = found
                    r.camerasReady = true
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            self.tagRoutes()
            if let c = self.lastCoord { self.refreshNearby(c, force: true) }
            self.objectWillChange.send()
            done()
        }
    }

    private func tagRoutes() {
        for r in routes { r.tags = [] }
        guard let fastest = routes.first else { return }
        fastest.tags.append("FASTEST")
        if routes.count > 1, routes.allSatisfy({ $0.camerasReady }) {
            let most = routes.map { $0.cameras.count }.max() ?? 0
            if let fewest = routes.min(by: { $0.cameras.count < $1.cameras.count }), fewest.cameras.count < most {
                fewest.tags.append("FEWEST CAMERAS")
            }
        }
        for r in routes where r.hasTolls { r.tags.append("TOLL") }
    }

    // MARK: search and planning

    func search(_ text: String, completion: @escaping ([MKMapItem]) -> Void) {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        if let l = location {
            request.region = MKCoordinateRegion(center: l.coordinate, latitudinalMeters: 80_000, longitudinalMeters: 80_000)
        }
        request.resultTypes = [.address, .pointOfInterest]
        MKLocalSearch(request: request).start { response, _ in
            DispatchQueue.main.async { completion(response?.mapItems ?? []) }
        }
    }

    /// Ask Apple Maps for routes and show them as a preview. With `waitForCameras`, the
    /// completion is held back (up to 10 s) until camera counts are ready; CarPlay uses
    /// this because its route list can't change once shown.
    func plan(to item: MKMapItem, waitForCameras: Bool = false, completion: (([PlannedRoute]) -> Void)? = nil) {
        guard let loc = location else {
            status = "Waiting for GPS…"
            completion?([])
            return
        }
        status = "Finding routes…"
        requestRoutes(to: item, from: loc.coordinate) { [weak self] planned in
            guard let self = self else { return }
            guard !planned.isEmpty else {
                self.status = "No route found"
                completion?([])
                return
            }
            self.status = nil
            self.destination = item
            self.routes = planned
            self.selectedRouteID = planned[0].id
            self.mode = .preview

            var finished = false
            let finish: () -> Void = {
                if !finished {
                    finished = true
                    completion?(planned)
                }
            }
            if waitForCameras {
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { finish() }
            } else {
                finish()
            }
            self.loadCamerasForRoutes(planned) { finish() }
        }
    }

    private func requestRoutes(to item: MKMapItem, from coordinate: CLLocationCoordinate2D,
                               completion: @escaping ([PlannedRoute]) -> Void) {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        request.destination = item
        request.transportType = .automobile
        request.requestsAlternateRoutes = true
        request.tollPreference = avoidTolls ? .avoid : .any
        MKDirections(request: request).calculate { response, _ in
            DispatchQueue.main.async {
                guard let response = response else {
                    completion([])
                    return
                }
                let planned = response.routes
                    .map { PlannedRoute(route: $0) }
                    .sorted { $0.travelTime < $1.travelTime }
                completion(planned)
            }
        }
    }

    func select(route: PlannedRoute) {
        selectedRouteID = route.id
        if let c = lastCoord { refreshNearby(c, force: true) }
    }

    func cancel() {
        stopNavigation()
    }

    // MARK: navigation

    func startNavigation(route: PlannedRoute? = nil) {
        guard let r = route ?? selectedRoute else { return }
        activeRoute = r
        selectedRouteID = r.id
        mode = .navigating
        announced.removeAll()
        offRouteCount = 0
        navSegment = nil
        nextStepIndex = -1
        alerts.resetAnnounced()
        alerts.setRoute(r.index, cameras: r.cameras)
        if let d = destination { remember(d) }

        if r.camerasReady {
            speech.say("Route started. \(cameraSentence(r.cameras.count))", interrupt: false)
        } else {
            speech.say("Route started.", interrupt: false)
            loadCamerasForRoutes([r]) { [weak self] in
                guard let self = self, self.activeRoute?.id == r.id else { return }
                self.alerts.setRoute(r.index, cameras: r.cameras)
            }
        }
        updateGuidance(snap: nil)
    }

    private func cameraSentence(_ n: Int) -> String {
        switch n {
        case 0: return "No speed cameras on this route."
        case 1: return "One speed camera on this route."
        default: return "\(n) speed cameras on this route."
        }
    }

    func stopNavigation() {
        stopDemo()
        mode = .idle
        routes = []
        selectedRouteID = nil
        destination = nil
        activeRoute = nil
        nextStepIndex = -1
        nextInstruction = ""
        nextInstructionDistance = 0
        remainingDistance = 0
        remainingTime = 0
        alerts.setRoute(nil, cameras: [])
        if let c = lastCoord { refreshNearby(c, force: true) }
    }

    private func updateGuidance(snap: RouteIndex.Snap?) {
        guard mode == .navigating, let r = activeRoute, let loc = location else { return }
        let c = Coord(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude)

        var s = snap
        if s == nil {
            s = r.index.snap(c, aroundSegment: navSegment)
            if s == nil || (s?.offRoute ?? 0) > 100 { s = r.index.snap(c) }
        }
        guard let here = s else { return }
        navSegment = here.segment

        if here.offRoute > 80 { offRouteCount += 1 } else { offRouteCount = 0 }
        if offRouteCount >= 4 {
            reroute()
            return
        }

        let total = r.index.length
        let remaining = max(0, total - here.progress)
        remainingDistance = remaining
        remainingTime = total > 0 ? r.travelTime * remaining / total : 0

        if let k = r.steps.firstIndex(where: { $0.startsAt > here.progress + 8 }) {
            let step = r.steps[k]
            let d = step.startsAt - here.progress
            nextStepIndex = k
            nextInstruction = step.instruction
            nextInstructionDistance = d
            announce(step: k, text: step.instruction, distance: d)
        } else {
            nextStepIndex = -1
            nextInstruction = "Continue to your destination"
            nextInstructionDistance = remaining
        }

        if remaining < 35 {
            arrive()
            return
        }
        guidanceSubject.send()
    }

    /// Spoken turn prompts at about half a mile, 300 yards, and at the turn.
    private func announce(step k: Int, text: String, distance d: Double) {
        var mask = announced[k] ?? 0
        let lowered = text.prefix(1).lowercased() + text.dropFirst()
        if d <= 60, mask & 4 == 0 {
            mask |= 7
            speech.say(text, interrupt: false)
        } else if d <= 275, d > 60, mask & 2 == 0 {
            mask |= 3
            speech.say("In 300 yards, \(lowered)", interrupt: false)
        } else if d <= 805, d > 275, mask & 1 == 0 {
            mask |= 1
            speech.say("In half a mile, \(lowered)", interrupt: false)
        }
        announced[k] = mask
    }

    private func arrive() {
        speech.say("You have arrived.", interrupt: false)
        arrivalSubject.send()
        stopNavigation()
    }

    private func reroute() {
        let now = Date()
        guard now.timeIntervalSince(lastReroute) > 15, let dest = destination, let loc = location else { return }
        lastReroute = now
        offRouteCount = 0
        speech.say("Rerouting.", interrupt: false)
        requestRoutes(to: dest, from: loc.coordinate) { [weak self] planned in
            guard let self = self, self.mode == .navigating, let best = planned.first else { return }
            self.routes = planned
            self.selectedRouteID = best.id
            self.activeRoute = best
            self.navSegment = nil
            self.announced.removeAll()
            self.nextStepIndex = -1
            self.alerts.setRoute(nil, cameras: [])
            self.loadCamerasForRoutes([best]) { [weak self] in
                guard let self = self, self.activeRoute?.id == best.id else { return }
                self.alerts.setRoute(best.index, cameras: best.cameras)
            }
            self.rerouteSubject.send()
            self.updateGuidance(snap: nil)
        }
    }

    /// The next few turns, with distance from the current position (used by CarPlay).
    func upcomingSteps(limit: Int) -> [(instruction: String, distance: Double)] {
        guard let r = activeRoute, nextStepIndex >= 0 else { return [] }
        let progress = r.index.length - remainingDistance
        var out: [(instruction: String, distance: Double)] = []
        let end = min(r.steps.count, nextStepIndex + limit)
        for k in nextStepIndex..<end {
            out.append((r.steps[k].instruction, max(0, r.steps[k].startsAt - progress)))
        }
        return out
    }

    // MARK: demo drive

    /// Drives the chosen route with a simulated GPS so you can see and hear the alerts
    /// without leaving the house (also handy in the CarPlay simulator).
    func startDemo(speedMps: Double = 22) {
        if mode != .navigating { startNavigation() }
        guard mode == .navigating, activeRoute != nil else { return }
        stopDemo()
        isDemo = true
        demoDistance = 0
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self, self.isDemo, let r = self.activeRoute else { return }
            self.demoDistance += speedMps * 0.5
            guard let p = r.index.position(at: self.demoDistance) else { return }
            let fix = CLLocation(coordinate: CLLocationCoordinate2D(latitude: p.coord.lat, longitude: p.coord.lon),
                                 altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
                                 course: p.bearing, speed: speedMps, timestamp: Date())
            self.handle(fix)
        }
        RunLoop.main.add(timer, forMode: .common)
        demoTimer = timer
    }

    func stopDemo() {
        demoTimer?.invalidate()
        demoTimer = nil
        isDemo = false
    }

    // MARK: recents

    private func remember(_ item: MKMapItem) {
        let c = item.placemark.coordinate
        let place = RecentPlace(name: item.name ?? "Destination", subtitle: item.placemark.title ?? "",
                                lat: c.latitude, lon: c.longitude)
        var list = recents.filter { $0.name != place.name || abs($0.lat - place.lat) > 0.0005 }
        list.insert(place, at: 0)
        recents = Array(list.prefix(8))
        if let data = try? JSONEncoder().encode(recents) {
            UserDefaults.standard.set(data, forKey: "recents")
        }
    }

    private func loadRecents() -> [RecentPlace] {
        guard let data = UserDefaults.standard.data(forKey: "recents"),
              let list = try? JSONDecoder().decode([RecentPlace].self, from: data) else { return [] }
        return list
    }
}
