import Foundation

/// A camera that sits on a planned route, with how far along the route it is.
public struct RouteCamera: Hashable {
    public let camera: SpeedCamera
    public let atMeters: Double

    public init(camera: SpeedCamera, atMeters: Double) {
        self.camera = camera
        self.atMeters = atMeters
    }
}

/// A route polyline with cumulative distances, so a GPS fix can be turned into
/// "metres travelled along the route".
public struct RouteIndex {
    public let points: [Coord]
    /// cumulative[i] = metres from the start to points[i]
    public let cumulative: [Double]

    public var length: Double { cumulative.last ?? 0 }

    public init(points: [Coord]) {
        var pts: [Coord] = []
        for p in points {
            if let last = pts.last, Geo.distance(last, p) < 0.5 { continue }
            pts.append(p)
        }
        var cum: [Double] = []
        var acc = 0.0
        for i in 0..<pts.count {
            if i > 0 { acc += Geo.distance(pts[i - 1], pts[i]) }
            cum.append(acc)
        }
        self.points = pts
        self.cumulative = cum
    }

    public struct Snap {
        /// Metres along the route.
        public let progress: Double
        /// How far the fix is from the route line, in metres.
        public let offRoute: Double
        /// Index of the segment (points[segment] ... points[segment + 1]).
        public let segment: Int
    }

    /// Snap a position onto the route. With `aroundSegment`, only a window of segments
    /// is searched, which is fast and keeps the result from jumping on loops.
    public func snap(_ p: Coord, aroundSegment seg: Int? = nil, back: Int = 5, forward: Int = 80) -> Snap? {
        guard points.count >= 2 else { return nil }
        let lastSeg = points.count - 2
        var lo = 0
        var hi = lastSeg
        if let s = seg {
            lo = max(0, s - back)
            hi = min(lastSeg, s + forward)
        }
        if lo > hi { return nil }
        var best: Snap?
        var bestDistance = Double.infinity
        for i in lo...hi {
            let r = Geo.project(p, onto: points[i], points[i + 1])
            if r.distance < bestDistance {
                bestDistance = r.distance
                let segLength = cumulative[i + 1] - cumulative[i]
                best = Snap(progress: cumulative[i] + segLength * r.t, offRoute: r.distance, segment: i)
            }
        }
        return best
    }

    /// The position and heading at `meters` along the route (used by the demo drive).
    public func position(at meters: Double) -> (coord: Coord, bearing: Double)? {
        guard points.count >= 2 else { return nil }
        let m = max(0, min(meters, length))
        var lo = 0
        var hi = points.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if cumulative[mid] <= m { lo = mid } else { hi = mid }
        }
        let segLength = cumulative[hi] - cumulative[lo]
        let t = segLength > 0 ? (m - cumulative[lo]) / segLength : 0
        let a = points[lo]
        let b = points[hi]
        let c = Coord(lat: a.lat + (b.lat - a.lat) * t, lon: a.lon + (b.lon - a.lon) * t)
        return (c, Geo.bearing(from: a, to: b))
    }

    /// Cameras within `tolerance` metres of the route line, ordered along the route.
    /// Cameras closer than 20 m to the previous one along the route are merged.
    public func cameras(from cams: [SpeedCamera], tolerance: Double = 25) -> [RouteCamera] {
        guard points.count >= 2 else { return [] }
        let latTol = tolerance / 111_000.0 * 1.5
        var found: [RouteCamera] = []
        for cam in cams {
            let cosLat = max(0.2, cos(cam.coord.lat * .pi / 180))
            let lonTol = latTol / cosLat
            var best = Double.infinity
            var bestAt = 0.0
            for i in 0..<(points.count - 1) {
                let a = points[i]
                let b = points[i + 1]
                if cam.coord.lat < min(a.lat, b.lat) - latTol || cam.coord.lat > max(a.lat, b.lat) + latTol { continue }
                if cam.coord.lon < min(a.lon, b.lon) - lonTol || cam.coord.lon > max(a.lon, b.lon) + lonTol { continue }
                let r = Geo.project(cam.coord, onto: a, b)
                if r.distance < best {
                    best = r.distance
                    bestAt = cumulative[i] + (cumulative[i + 1] - cumulative[i]) * r.t
                }
            }
            if best <= tolerance {
                found.append(RouteCamera(camera: cam, atMeters: bestAt))
            }
        }
        found.sort { $0.atMeters < $1.atMeters }
        var merged: [RouteCamera] = []
        for rc in found {
            if let last = merged.last, rc.atMeters - last.atMeters < 20 { continue }
            merged.append(rc)
        }
        return merged
    }
}
