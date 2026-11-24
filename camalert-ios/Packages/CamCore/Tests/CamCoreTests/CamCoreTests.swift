import XCTest
@testable import CamCore

final class CamCoreTests: XCTestCase {
    private let start = Coord(lat: 52.0, lon: -1.0)

    // MARK: helpers

    /// A point `along` metres north of `start`, `east` metres to the east.
    private func point(north along: Double, east: Double = 0) -> Coord {
        let p = Geo.destination(from: start, bearing: 0, meters: along)
        return east == 0 ? p : Geo.destination(from: p, bearing: 90, meters: east)
    }

    private func northRoute(lengthMeters: Double = 5000) -> RouteIndex {
        var pts: [Coord] = []
        var m = 0.0
        while m <= lengthMeters {
            pts.append(point(north: m))
            m += 500
        }
        return RouteIndex(points: pts)
    }

    private func camera(_ id: Int64, north: Double, east: Double = 0, limit: Int? = 40) -> SpeedCamera {
        SpeedCamera(id: id, coord: point(north: north, east: east), limitMph: limit, kind: .fixed)
    }

    /// Drive north at `speed` m/s, one fix per second, from `from` to `to` metres.
    private func drive(_ engine: AlertEngine, from: Double, to: Double, speed: Double = 15) -> [AlertEvent] {
        var events: [AlertEvent] = []
        var pos = from
        var t = 0.0
        while pos <= to {
            let r = engine.update(location: point(north: pos), course: 0, speedMps: speed,
                                  now: Date(timeIntervalSince1970: 1_000 + t))
            events.append(contentsOf: r.events)
            pos += speed
            t += 1
        }
        return events
    }

    // MARK: geometry

    func testDistanceLondonToBirmingham() {
        let d = Geo.distance(Coord(lat: 51.5074, lon: -0.1278), Coord(lat: 52.4862, lon: -1.8904))
        XCTAssertEqual(d, 162_496, accuracy: 100)
    }

    func testBearingDueEast() {
        XCTAssertEqual(Geo.bearing(from: Coord(lat: 0, lon: 0), to: Coord(lat: 0, lon: 1)), 90, accuracy: 0.001)
    }

    func testAngleDiffWrapsAroundNorth() {
        XCTAssertEqual(Geo.angleDiff(350, 10), 20, accuracy: 0.0001)
        XCTAssertEqual(Geo.angleDiff(0, 180), 180, accuracy: 0.0001)
    }

    func testDestinationRoundTrip() {
        let b = Geo.destination(from: start, bearing: 45, meters: 1000)
        XCTAssertEqual(Geo.distance(start, b), 1000, accuracy: 0.5)
        XCTAssertEqual(Geo.bearing(from: start, to: b), 45, accuracy: 0.1)
    }

    // MARK: OpenStreetMap parsing

    func testParseLimit() {
        XCTAssertEqual(Overpass.parseLimitMph("40 mph"), 40)
        XCTAssertEqual(Overpass.parseLimitMph("30 mph"), 30)
        XCTAssertEqual(Overpass.parseLimitMph("48"), 30)      // 48 km/h
        XCTAssertEqual(Overpass.parseLimitMph("50;60"), 30)   // first value, km/h
        XCTAssertNil(Overpass.parseLimitMph("national_speed_limit"))
        XCTAssertNil(Overpass.parseLimitMph(nil))
    }

    func testParseOverpassMergesDuplicatesAndReadsKinds() throws {
        let json = """
        {"elements":[
          {"type":"node","id":1,"lat":52.0,"lon":-1.0,"tags":{"highway":"speed_camera","maxspeed":"40 mph"}},
          {"type":"node","id":2,"lat":52.00002,"lon":-1.0,"tags":{"highway":"speed_camera"}},
          {"type":"node","id":3,"lat":52.1,"lon":-1.1,"tags":{"enforcement":"average_speed","maxspeed":"50 mph"}}
        ]}
        """
        let cams = try Overpass.parse(Data(json.utf8))
        XCTAssertEqual(cams.count, 2)
        XCTAssertEqual(cams[0].limitMph, 40)
        XCTAssertEqual(cams[0].kind, .fixed)
        XCTAssertEqual(cams[1].kind, .average)
        XCTAssertEqual(cams[1].limitMph, 50)
    }

    // MARK: route index

    func testCamerasOnRouteKeepsOnlyThoseNearTheLine() {
        let route = northRoute()
        let on = camera(1, north: 2000, east: 10)
        let off = camera(2, north: 3000, east: 200)
        let found = route.cameras(from: [on, off])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.camera.id, 1)
        XCTAssertEqual(found.first?.atMeters ?? 0, 2000, accuracy: 3)
    }

    func testSnapReportsProgressAndOffsetFromRoute() {
        let route = northRoute()
        let snap = route.snap(point(north: 1234, east: 30))
        XCTAssertNotNil(snap)
        XCTAssertEqual(snap?.progress ?? 0, 1234, accuracy: 3)
        XCTAssertEqual(snap?.offRoute ?? 0, 30, accuracy: 2)
    }

    func testPositionAlongRoute() {
        let route = northRoute()
        let p = route.position(at: 2500)
        XCTAssertNotNil(p)
        XCTAssertEqual(Geo.distance(p!.coord, point(north: 2500)), 0, accuracy: 1)
        XCTAssertEqual(p!.bearing, 0, accuracy: 0.5)
    }

    // MARK: alerts

    func testHeadingModeFiresEachStageOnce() {
        let engine = AlertEngine()
        engine.cameras = [camera(7, north: 2000)]
        let events = drive(engine, from: 0, to: 2100)
        XCTAssertEqual(events.map { $0.stage }, [.far, .near, .imminent])
        for e in events {
            XCTAssertLessThanOrEqual(e.distance, e.stage.triggerMeters)
            XCTAssertEqual(e.camera.id, 7)
        }
    }

    func testCameraBesideTheRoadIsIgnoredInHeadingMode() {
        let engine = AlertEngine()
        engine.cameras = [camera(1, north: 300, east: 200)]
        let r = engine.update(location: start, course: 0, speedMps: 15)
        XCTAssertTrue(r.events.isEmpty)
        XCTAssertNil(r.next)
    }

    func testCameraBehindIsIgnored() {
        let engine = AlertEngine()
        engine.cameras = [camera(1, north: -300)]
        let r = engine.update(location: start, course: 0, speedMps: 15)
        XCTAssertTrue(r.events.isEmpty)
    }

    func testNoAlertsBelowTenMphUnlessPassenger() {
        let engine = AlertEngine()
        engine.cameras = [camera(1, north: 300)]
        XCTAssertTrue(engine.update(location: start, course: 0, speedMps: 2).events.isEmpty)

        let passenger = AlertEngine()
        passenger.cameras = [camera(1, north: 300)]
        passenger.passengerMode = true
        XCTAssertFalse(passenger.update(location: start, course: 0, speedMps: 2).events.isEmpty)
    }

    func testRouteModeAlertsOnlyForCamerasOnTheRoute() {
        let engine = AlertEngine()
        let route = northRoute()
        let on = camera(1, north: 2000, east: 5)
        let off = camera(2, north: 3000, east: 200)
        engine.cameras = [on, off]
        engine.setRoute(route, cameras: route.cameras(from: [on, off]))
        let events = drive(engine, from: 0, to: 3100)
        XCTAssertEqual(events.map { $0.stage }, [.far, .near, .imminent])
        XCTAssertTrue(events.allSatisfy { $0.camera.id == 1 })
    }

    func testRouteModeReportsSnapAndNextCamera() {
        let engine = AlertEngine()
        let route = northRoute()
        let cam = camera(1, north: 2000)
        engine.setRoute(route, cameras: route.cameras(from: [cam]))
        let r = engine.update(location: point(north: 500), course: 0, speedMps: 15)
        XCTAssertNotNil(r.snap)
        XCTAssertEqual(r.next?.distance ?? 0, 1500, accuracy: 5)
    }

    func testFirstSeenCloseUpSkipsEarlierStages() {
        let engine = AlertEngine()
        engine.cameras = [camera(1, north: 100)]
        let r = engine.update(location: start, course: 0, speedMps: 15)
        XCTAssertEqual(r.events.map { $0.stage }, [.imminent])
    }

    // MARK: wording

    func testSpokenText() {
        let cam = camera(1, north: 0, limit: 40)
        XCTAssertEqual(AlertEvent(camera: cam, stage: .far, distance: 800, speedMph: 35).spokenText,
                       "Speed camera ahead in half a mile. Limit 40.")
        XCTAssertEqual(AlertEvent(camera: cam, stage: .imminent, distance: 100, speedMph: 35).spokenText,
                       "Speed camera now. Limit 40.")
        XCTAssertEqual(AlertEvent(camera: cam, stage: .near, distance: 400, speedMph: 49).spokenText,
                       "Slow down. Speed camera in a quarter mile. Limit 40.")
    }
}
