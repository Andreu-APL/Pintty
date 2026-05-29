import AppKit
import MapKit

struct PinttyGeoPoint: Decodable {
    let lat: Double
    let lon: Double
    let label: String?
    let color: String?
}

enum PinttyGeoRenderer {

    /// Render geo points onto a map snapshot and return a CGImage via `completion` (main thread).
    static func render(
        eventsJSON: String,
        size: CGSize,
        completion: @escaping (CGImage?) -> Void
    ) {
        guard size.width > 0, size.height > 0,
              let data = eventsJSON.data(using: .utf8),
              let points = try? JSONDecoder().decode([PinttyGeoPoint].self, from: data),
              !points.isEmpty
        else { completion(nil); return }

        let opts = MKMapSnapshotter.Options()
        opts.region      = boundingRegion(for: points)
        opts.size        = size
        opts.mapType     = .mutedStandard
        opts.showsBuildings = false

        MKMapSnapshotter(options: opts).start(with: .main) { snapshot, _ in
            guard let snap = snapshot else { completion(nil); return }
            completion(composite(points: points, snap: snap))
        }
    }

    // MARK: - Private

    private static func boundingRegion(for points: [PinttyGeoPoint]) -> MKCoordinateRegion {
        let lats = points.map(\.lat)
        let lons = points.map(\.lon)
        let center = CLLocationCoordinate2D(
            latitude:  (lats.min()! + lats.max()!) / 2,
            longitude: (lons.min()! + lons.max()!) / 2
        )
        let latDelta = max(lats.max()! - lats.min()!, 4.0) * 1.6
        let lonDelta = max(lons.max()! - lons.min()!, 4.0) * 1.6
        return MKCoordinateRegion(
            center: center,
            span:   MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)
        )
    }

    /// Composite event dots and labels over the base map image.
    private static func composite(
        points: [PinttyGeoPoint],
        snap: MKMapSnapshotter.Snapshot
    ) -> CGImage? {
        let size   = snap.image.size
        let canvas = NSImage(size: size)
        canvas.lockFocus()
        defer { canvas.unlockFocus() }

        snap.image.draw(in: NSRect(origin: .zero, size: size))

        for pt in points {
            let coord = CLLocationCoordinate2D(latitude: pt.lat, longitude: pt.lon)
            // On macOS, snapshot.point(for:) uses AppKit y-up coordinates.
            let p   = snap.point(for: coord)
            let dot: CGFloat = 5
            let col = parseColor(pt.color) ?? PinttyColors.geoDefault

            // Outer glow ring.
            col.withAlphaComponent(0.25).setFill()
            NSBezierPath(ovalIn: CGRect(
                x: p.x - dot * 2.2, y: p.y - dot * 2.2,
                width: dot * 4.4,   height: dot * 4.4
            )).fill()

            // Solid core.
            col.setFill()
            NSBezierPath(ovalIn: CGRect(
                x: p.x - dot, y: p.y - dot,
                width: dot * 2, height: dot * 2
            )).fill()

            // Label (if present).
            if let label = pt.label {
                let shadow = NSShadow()
                shadow.shadowColor      = NSColor.black.withAlphaComponent(0.8)
                shadow.shadowBlurRadius = 2
                shadow.shadowOffset     = .zero
                let attrs: [NSAttributedString.Key: Any] = [
                    .font:            NSFont.systemFont(ofSize: 9, weight: .semibold),
                    .foregroundColor: NSColor.white,
                    .shadow:          shadow,
                ]
                NSAttributedString(string: label, attributes: attrs)
                    .draw(at: CGPoint(x: p.x + dot + 3, y: p.y - 5))
            }
        }

        return canvas.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    private static func parseColor(_ hex: String?) -> NSColor? {
        guard let h = hex?.trimmingCharacters(in: CharacterSet(charactersIn: "#")),
              h.count == 6,
              let v = UInt64(h, radix: 16)
        else { return nil }
        return NSColor(
            red:   CGFloat((v >> 16) & 0xFF) / 255,
            green: CGFloat((v >>  8) & 0xFF) / 255,
            blue:  CGFloat( v        & 0xFF) / 255,
            alpha: 1.0
        )
    }
}
