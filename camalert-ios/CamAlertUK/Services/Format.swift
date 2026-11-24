import Foundation
import UIKit

/// UK-style formatting: miles and yards, minutes.
enum Fmt {
    static func distance(_ meters: Double) -> String {
        if meters < 160 {
            let yards = Int((meters * 1.09361 / 10).rounded()) * 10
            return "\(max(yards, 10)) yd"
        }
        let miles = meters / 1609.344
        return miles < 10 ? String(format: "%.1f mi", miles) : String(format: "%.0f mi", miles)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }

    static func arrivalTime(after seconds: TimeInterval) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: Date().addingTimeInterval(seconds))
    }
}

/// Picks an SF Symbol for a turn instruction such as "Turn left onto High Street".
enum GuidanceIcon {
    static func symbolName(for instruction: String) -> String {
        let t = instruction.lowercased()
        if t.contains("arrive") || t.contains("destination") { return "mappin.circle.fill" }
        if t.contains("roundabout") || t.contains("traffic circle") { return "arrow.triangle.2.circlepath" }
        if t.contains("u-turn") { return "arrow.uturn.left" }
        if t.contains("slight left") || t.contains("bear left") || t.contains("keep left") { return "arrow.up.left" }
        if t.contains("slight right") || t.contains("bear right") || t.contains("keep right") { return "arrow.up.right" }
        if t.contains("left") { return "arrow.turn.up.left" }
        if t.contains("right") { return "arrow.turn.up.right" }
        if t.contains("merge") || t.contains("exit") || t.contains("ramp") || t.contains("take the") { return "arrow.up.right" }
        return "arrow.up"
    }

    static func image(for instruction: String) -> UIImage? {
        UIImage(systemName: symbolName(for: instruction))
    }
}
