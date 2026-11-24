import Foundation

public enum CameraKind: String, Codable {
    case fixed
    case average
}

public struct SpeedCamera: Codable, Hashable, Identifiable {
    public let id: Int64
    public let coord: Coord
    /// Enforced limit in mph, if OpenStreetMap has it.
    public let limitMph: Int?
    public let kind: CameraKind

    public init(id: Int64, coord: Coord, limitMph: Int?, kind: CameraKind) {
        self.id = id
        self.coord = coord
        self.limitMph = limitMph
        self.kind = kind
    }
}

/// OpenStreetMap / Overpass helpers.
public enum Overpass {
    /// Query for fixed and average-speed cameras inside a bounding box.
    public static func query(south: Double, west: Double, north: Double, east: Double) -> String {
        let bbox = "\(south),\(west),\(north),\(east)"
        return """
        [out:json][timeout:25];
        (
          node["highway"="speed_camera"](\(bbox));
          node["enforcement"~"^(maxspeed|average_speed)$"](\(bbox));
        );
        out body;
        """
    }

    private struct Response: Decodable {
        let elements: [Element]
    }

    private struct Element: Decodable {
        let id: Int64
        let lat: Double?
        let lon: Double?
        let center: Center?
        let tags: [String: String]?

        struct Center: Decodable {
            let lat: Double
            let lon: Double
        }
    }

    /// Parse an Overpass JSON reply into cameras. Cameras within `mergeMeters` of each
    /// other are treated as one (OSM often maps the same camera twice).
    public static func parse(_ data: Data, mergeMeters: Double = 12) throws -> [SpeedCamera] {
        let response = try JSONDecoder().decode(Response.self, from: data)
        var cams: [SpeedCamera] = []
        for e in response.elements {
            let la = e.lat ?? e.center?.lat
            let lo = e.lon ?? e.center?.lon
            guard let lat = la, let lon = lo else { continue }
            let tags = e.tags ?? [:]
            let kind: CameraKind = tags["enforcement"] == "average_speed" ? .average : .fixed
            let raw = tags["maxspeed"] ?? tags["maxspeed:forward"]
            let cam = SpeedCamera(id: e.id, coord: Coord(lat: lat, lon: lon),
                                  limitMph: parseLimitMph(raw), kind: kind)
            let duplicate = cams.contains { Geo.distance($0.coord, cam.coord) < mergeMeters }
            if !duplicate { cams.append(cam) }
        }
        return cams
    }

    /// "40 mph" -> 40. A bare number is km/h in OSM, so it is converted to mph and
    /// rounded to the nearest 5.
    public static func parseLimitMph(_ raw: String?) -> Int? {
        guard let raw = raw?.lowercased() else { return nil }
        let isMph = raw.contains("mph")
        let firstNumber = raw.split(whereSeparator: { !$0.isNumber }).first
        guard let token = firstNumber, let n = Int(token), n > 0 else { return nil }
        if isMph { return n }
        let mph = Double(n) * 0.621371
        return Int((mph / 5).rounded()) * 5
    }
}
