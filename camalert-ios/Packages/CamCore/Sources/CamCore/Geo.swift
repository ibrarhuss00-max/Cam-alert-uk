import Foundation

/// A plain latitude/longitude pair (degrees). Kept independent of CoreLocation so the
/// core logic builds and tests anywhere.
public struct Coord: Equatable, Hashable, Codable {
    public var lat: Double
    public var lon: Double

    public init(lat: Double, lon: Double) {
        self.lat = lat
        self.lon = lon
    }
}

public enum Geo {
    public static let earthRadius = 6_371_000.0

    @inline(__always) static func rad(_ degrees: Double) -> Double { degrees * .pi / 180 }
    @inline(__always) static func deg(_ radians: Double) -> Double { radians * 180 / .pi }

    /// Great-circle distance in metres (haversine).
    public static func distance(_ a: Coord, _ b: Coord) -> Double {
        let dLat = rad(b.lat - a.lat)
        let dLon = rad(b.lon - a.lon)
        let s = sin(dLat / 2) * sin(dLat / 2)
            + cos(rad(a.lat)) * cos(rad(b.lat)) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * asin(min(1, s.squareRoot()))
    }

    /// Initial bearing from a to b in degrees, 0..<360 (0 = north, 90 = east).
    public static func bearing(from a: Coord, to b: Coord) -> Double {
        let p1 = rad(a.lat)
        let p2 = rad(b.lat)
        let dl = rad(b.lon - a.lon)
        let y = sin(dl) * cos(p2)
        let x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
        let t = deg(atan2(y, x))
        return (t + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Smallest angle between two bearings, 0...180.
    public static func angleDiff(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return d > 180 ? 360 - d : d
    }

    /// The point `meters` away from `a` along `bearing` degrees.
    public static func destination(from a: Coord, bearing: Double, meters: Double) -> Coord {
        let d = meters / earthRadius
        let br = rad(bearing)
        let lat1 = rad(a.lat)
        let lon1 = rad(a.lon)
        let lat2 = asin(sin(lat1) * cos(d) + cos(lat1) * sin(d) * cos(br))
        let lon2 = lon1 + atan2(sin(br) * sin(d) * cos(lat1), cos(d) - sin(lat1) * sin(lat2))
        return Coord(lat: deg(lat2), lon: deg(lon2))
    }

    /// Distance from `p` to the segment a-b (metres) and where along the segment the
    /// closest point lies (t in 0...1). Uses a local flat approximation, which is
    /// accurate to well under a metre over road-segment lengths.
    public static func project(_ p: Coord, onto a: Coord, _ b: Coord) -> (distance: Double, t: Double) {
        let kx = cos(rad(a.lat)) * earthRadius
        let ky = earthRadius
        let px = rad(p.lon - a.lon) * kx
        let py = rad(p.lat - a.lat) * ky
        let bx = rad(b.lon - a.lon) * kx
        let by = rad(b.lat - a.lat) * ky
        let len2 = bx * bx + by * by
        var t = len2 > 0 ? (px * bx + py * by) / len2 : 0
        t = max(0, min(1, t))
        let dx = px - bx * t
        let dy = py - by * t
        return ((dx * dx + dy * dy).squareRoot(), t)
    }
}
