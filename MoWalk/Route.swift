import Foundation
import CoreLocation

/// A route to follow: points, cumulative distance and the turns along it.
/// Turns: anywhere the line bends 35° or more within ~25 m.
struct Route: Identifiable {
    struct Turn { let along: Double; let deg: Double }      // + right, - left

    let id: String            // file name
    let name: String
    let pts: [CLLocationCoordinate2D]
    let cum: [Double]
    let turns: [Turn]
    var length: Double { cum.last ?? 0 }

    init?(gpxURL url: URL) {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let p = GPXReader(); let x = XMLParser(data: data); x.delegate = p
        guard x.parse(), p.pts.count >= 2, p.pts.count <= Route.maxPoints else { return nil }
        id = url.lastPathComponent
        name = p.name ?? url.deletingPathExtension().lastPathComponent
        pts = p.pts
        var c = [0.0]
        for i in 1..<pts.count { c.append(c[i - 1] + Route.dist(pts[i - 1], pts[i])) }
        guard let total = c.last, total.isFinite, total <= Route.maxLength else { return nil }
        cum = c
        turns = Route.findTurns(pts, cum)
    }

    // a GPX from anywhere is untrusted: bound what we'll load
    static let maxPoints = 200_000, maxLength = 1_000_000.0      // 1000 km

    // MARK: geometry

    static func dist(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let kx = 111_320 * cos((a.latitude + b.latitude) / 2 * .pi / 180)
        return hypot((b.longitude - a.longitude) * kx, (b.latitude - a.latitude) * 110_540)
    }
    static func bearing(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let p1 = a.latitude * .pi / 180, p2 = b.latitude * .pi / 180, dl = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dl) * cos(p2), x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Point `along` metres down the route.
    func point(at along: Double) -> CLLocationCoordinate2D {
        let s = min(max(0, along), length)
        var lo = 0, hi = cum.count - 1
        while hi - lo > 1 { let m = (lo + hi) / 2; if cum[m] <= s { lo = m } else { hi = m } }
        let seg = cum[hi] - cum[lo], t = seg > 0 ? (s - cum[lo]) / seg : 0
        return CLLocationCoordinate2D(latitude: pts[lo].latitude + t * (pts[hi].latitude - pts[lo].latitude),
                                      longitude: pts[lo].longitude + t * (pts[hi].longitude - pts[lo].longitude))
    }

    struct Snap { let seg: Int; let along: Double; let off: Double; let at: CLLocationCoordinate2D }

    /// Nearest point on the line. Searches near the last snap first (so a fix can't jump to
    /// a far part of a route that doubles back), and the whole route when that's far off.
    func snap(_ p: CLLocationCoordinate2D, near hint: Int?) -> Snap {
        func best(_ r: Range<Int>) -> Snap {
            let kx = 111_320 * cos(p.latitude * .pi / 180), ky = 110_540.0
            var b = Snap(seg: 0, along: 0, off: .infinity, at: pts[0])
            for i in r {
                let a = pts[i], c = pts[i + 1]
                let ax = (a.longitude - p.longitude) * kx, ay = (a.latitude - p.latitude) * ky
                let dx = (c.longitude - a.longitude) * kx, dy = (c.latitude - a.latitude) * ky
                let l2 = dx * dx + dy * dy
                let t = l2 > 0 ? min(1, max(0, -(ax * dx + ay * dy) / l2)) : 0
                let d = hypot(ax + t * dx, ay + t * dy)
                if d < b.off {
                    b = Snap(seg: i, along: cum[i] + t * (cum[i + 1] - cum[i]), off: d,
                             at: CLLocationCoordinate2D(latitude: a.latitude + t * (c.latitude - a.latitude),
                                                        longitude: a.longitude + t * (c.longitude - a.longitude)))
                }
            }
            return b
        }
        let n = pts.count - 1
        if let h = hint {
            let local = best(max(0, h - 15)..<min(n, h + 150))
            if local.off < 100 { return local }
        }
        return best(0..<n)
    }

    // MARK: turns -- resample every 5 m, compare bearing over 25 m before / after,
    // >= 35 degrees is a bend, bends within 30 m (same side) are one turn at the sharpest.

    static func findTurns(_ pts: [CLLocationCoordinate2D], _ cum: [Double]) -> [Turn] {
        let step = 5.0, k = 5, minDeg = 35.0, merge = 30.0
        guard let total = cum.last, total.isFinite, total > 60, total <= maxLength else { return [] }
        var r: [(CLLocationCoordinate2D, Double)] = []
        var j = 0, s = 0.0
        while s <= total {
            while j < pts.count - 2 && cum[j + 1] < s { j += 1 }
            let seg = cum[j + 1] - cum[j], t = seg > 0 ? (s - cum[j]) / seg : 0
            r.append((CLLocationCoordinate2D(latitude: pts[j].latitude + t * (pts[j + 1].latitude - pts[j].latitude),
                                             longitude: pts[j].longitude + t * (pts[j + 1].longitude - pts[j].longitude)), s))
            s += step
        }
        var out: [(along: Double, deg: Double, last: Double)] = []
        guard r.count > 2 * k else { return [] }
        for i in k..<(r.count - k) {
            var d = bearing(r[i].0, r[i + k].0) - bearing(r[i - k].0, r[i].0)
            d = (d + 540).truncatingRemainder(dividingBy: 360) - 180
            guard abs(d) >= minDeg else { continue }
            let a = r[i].1
            if let l = out.last, a - l.last <= merge, (d > 0) == (l.deg > 0) {
                out[out.count - 1] = abs(d) > abs(l.deg) ? (a, d, a) : (l.along, l.deg, a)
            } else { out.append((a, d, a)) }
        }
        return out.map { Turn(along: $0.along, deg: $0.deg) }
    }
}

extension Route.Turn {
    var left: Bool { deg < 0 }
    var words: String {
        let side = left ? "left" : "right"
        return abs(deg) < 60 ? "bear \(side)" : abs(deg) < 120 ? "turn \(side)" : "sharp \(side)"
    }
    var icon: String {
        abs(deg) < 60 ? (left ? "arrow.up.left" : "arrow.up.right")
        : abs(deg) < 120 ? (left ? "arrow.turn.up.left" : "arrow.turn.up.right")
        : (left ? "arrow.uturn.left" : "arrow.uturn.right")
    }
}

/// Track points (or route points) and the first name in a GPX file.
private final class GPXReader: NSObject, XMLParserDelegate {
    var pts: [CLLocationCoordinate2D] = []
    var rte: [CLLocationCoordinate2D] = []
    var name: String?
    private var inName = false, text = ""

    func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?,
                attributes a: [String: String] = [:]) {
        if e == "trkpt" || e == "rtept", let la = Double(a["lat"] ?? ""), let lo = Double(a["lon"] ?? ""),
           la.isFinite, lo.isFinite, abs(la) <= 90, abs(lo) <= 180, pts.count + rte.count <= Route.maxPoints + 1 {
            let c = CLLocationCoordinate2D(latitude: la, longitude: lo)
            if e == "trkpt" { pts.append(c) } else { rte.append(c) }
        }
        if e == "name" && name == nil { inName = true; text = "" }
    }
    func parser(_ p: XMLParser, foundCharacters s: String) { if inName { text += s } }
    func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
        if e == "name" && inName {
            inName = false
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { name = t }
        }
        if e == "gpx" && pts.isEmpty { pts = rte }          // a <rte> only file
    }
}
