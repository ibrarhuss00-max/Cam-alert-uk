import Foundation
import CamCore

/// Downloads speed cameras from OpenStreetMap (Overpass) in map "cells" and caches them
/// on disk for 7 days. Stale cells are still used when offline.
final class CameraStore {
    static let shared = CameraStore()

    struct Key: Hashable {
        let i: Int
        let j: Int
    }

    private struct Cell: Codable {
        let fetched: Date
        let cameras: [SpeedCamera]
    }

    private final class Request {
        var remaining: Set<Key>
        var gotAny = false
        let completion: (Bool) -> Void

        init(remaining: Set<Key>, completion: @escaping (Bool) -> Void) {
            self.remaining = remaining
            self.completion = completion
        }
    }

    private static let latStep = 0.2
    private static let lonStep = 0.3
    private let ttl: TimeInterval = 7 * 24 * 3600

    /// Public Overpass servers, tried in order.
    private let endpoints = [
        "https://overpass-api.de/api/interpreter",
        "https://overpass.kumi.systems/api/interpreter"
    ]

    private let lock = NSLock()
    private var memory: [Key: Cell] = [:]
    private var inflight = Set<Key>()
    private var failedAt: [Key: Date] = [:]
    private var requests: [Request] = []
    private var queue: [Key] = []
    private var running = false
    private let directory: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("cameras", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: cells

    static func key(for c: Coord) -> Key {
        Key(i: Int(floor(c.lat / latStep)), j: Int(floor(c.lon / lonStep)))
    }

    private func bounds(_ k: Key) -> (s: Double, w: Double, n: Double, e: Double) {
        let s = Double(k.i) * CameraStore.latStep
        let w = Double(k.j) * CameraStore.lonStep
        return (s, w, s + CameraStore.latStep, w + CameraStore.lonStep)
    }

    /// Cells covering a circle around a point.
    func cells(near c: Coord, radiusMeters r: Double) -> [Key] {
        let dLat = r / 111_000.0
        let dLon = r / (111_000.0 * max(0.2, cos(c.lat * .pi / 180)))
        let lo = CameraStore.key(for: Coord(lat: c.lat - dLat, lon: c.lon - dLon))
        let hi = CameraStore.key(for: Coord(lat: c.lat + dLat, lon: c.lon + dLon))
        var out: [Key] = []
        for i in lo.i...hi.i {
            for j in lo.j...hi.j {
                out.append(Key(i: i, j: j))
            }
        }
        return out
    }

    /// Cells a route passes through.
    func cells(along points: [Coord]) -> [Key] {
        var set = Set<Key>()
        var previous: Coord?
        for p in points {
            if let q = previous {
                let d = Geo.distance(q, p)
                if d > 500 {
                    let n = Int(d / 500)
                    for s in 1...n {
                        let t = Double(s) / Double(n + 1)
                        set.insert(CameraStore.key(for: Coord(lat: q.lat + (p.lat - q.lat) * t,
                                                              lon: q.lon + (p.lon - q.lon) * t)))
                    }
                }
            }
            set.insert(CameraStore.key(for: p))
            previous = p
        }
        return Array(set)
    }

    // MARK: reading

    /// Cameras from whatever is cached for these cells (fresh or stale).
    func cameras(in keys: [Key]) -> [SpeedCamera] {
        lock.lock()
        defer { lock.unlock() }
        var seen = Set<Int64>()
        var out: [SpeedCamera] = []
        for k in keys {
            guard let cell = cachedCell(k) else { continue }
            for cam in cell.cameras where !seen.contains(cam.id) {
                seen.insert(cam.id)
                out.append(cam)
            }
        }
        return out
    }

    /// Make sure these cells are fresh. `completion` runs on the main thread exactly once,
    /// when everything this call needed has been attempted. The Bool is true if any new
    /// data arrived.
    func load(_ keys: [Key], completion: @escaping (Bool) -> Void) {
        lock.lock()
        var need = Set<Key>()
        for k in keys {
            if let c = cachedCell(k), Date().timeIntervalSince(c.fetched) < ttl { continue }
            if let failed = failedAt[k], Date().timeIntervalSince(failed) < 60 { continue }
            need.insert(k)
        }
        if need.isEmpty {
            lock.unlock()
            DispatchQueue.main.async { completion(false) }
            return
        }
        requests.append(Request(remaining: need, completion: completion))
        for k in need where !queue.contains(k) && !inflight.contains(k) {
            queue.append(k)
        }
        let shouldStart = !running
        running = true
        lock.unlock()
        if shouldStart { pump() }
    }

    // MARK: fetching (one cell at a time, to be polite to the public servers)

    private func pump() {
        lock.lock()
        guard !queue.isEmpty else {
            running = false
            lock.unlock()
            return
        }
        let k = queue.removeFirst()
        inflight.insert(k)
        lock.unlock()

        fetch(k, endpoint: 0) { [weak self] ok in
            guard let self = self else { return }
            self.finish(k, success: ok)
            self.pump()
        }
    }

    private func finish(_ k: Key, success: Bool) {
        lock.lock()
        inflight.remove(k)
        if !success { failedAt[k] = Date() }
        var done: [Request] = []
        for r in requests {
            if r.remaining.remove(k) != nil, success { r.gotAny = true }
            if r.remaining.isEmpty { done.append(r) }
        }
        requests.removeAll { $0.remaining.isEmpty }
        lock.unlock()
        for r in done {
            DispatchQueue.main.async { r.completion(r.gotAny) }
        }
    }

    private func fetch(_ k: Key, endpoint: Int, done: @escaping (Bool) -> Void) {
        guard endpoint < endpoints.count, let url = URL(string: endpoints[endpoint]) else {
            done(false)
            return
        }
        let b = bounds(k)
        let query = Overpass.query(south: b.s, west: b.w, north: b.n, east: b.e)
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = "data=" + (query.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = Data(body.utf8)
        req.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.setValue("CamAlertUK/1.0 (personal speed-camera alerts)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 25

        URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
            guard let self = self else {
                done(false)
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode == 200,
               let data = data, let cams = try? Overpass.parse(data) {
                self.store(Cell(fetched: Date(), cameras: cams), for: k)
                done(true)
            } else {
                self.fetch(k, endpoint: endpoint + 1, done: done)
            }
        }.resume()
    }

    // MARK: storage

    private func fileURL(_ k: Key) -> URL {
        directory.appendingPathComponent("cell_\(k.i)_\(k.j).json")
    }

    /// Call with the lock held.
    private func cachedCell(_ k: Key) -> Cell? {
        if let c = memory[k] { return c }
        if let data = try? Data(contentsOf: fileURL(k)),
           let c = try? JSONDecoder().decode(Cell.self, from: data) {
            memory[k] = c
            return c
        }
        return nil
    }

    private func store(_ cell: Cell, for k: Key) {
        lock.lock()
        memory[k] = cell
        lock.unlock()
        if let data = try? JSONEncoder().encode(cell) {
            try? data.write(to: fileURL(k), options: .atomic)
        }
    }
}
