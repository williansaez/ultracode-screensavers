import AppKit
import ScreenSaver

// UltracodeGlobe — faithful port of the originkit.dev "globe" web component
// (preset `base`, three.js) to a native macOS screensaver.
//
// Ported parameters (from refs/globe/source_1.tsx, preset props baked in):
//   fill="dots", dots = { color:#ffffff, size:5, density:8, allDots:false }
//   speed=2, direction="left", smoothing=8
//   scale=8  -> globeRadius = 0.2 + (7/19)*1.8 = 0.8631578947
//              cameraDistance = 2.5 / globeRadius, PerspectiveCamera fov 50
//   initialLatitude=23, initialLongitude=-23
//   oceanColor=#000000, showOutline=true, outlineColor=#ffffff, outlineWidth=1
//   showGrid=true, graticuleColor=#D4D4D4 (15 deg spacing, gridWidth=1)
//   detail=5 -> continent-outline ring simplification step = 6
//
// Landmass data: Natural Earth 50m land (ne_50m_land.json), the exact dataset
// the web component fetches at runtime. Baked into the bundle as
// Contents/Resources/land.bin (int16 centidegrees, all rings + outer flag).
// The land mask is rasterized at 2048x1024 (equirectangular) exactly like the
// reference's offscreen canvas, and dots are sampled with the same grid:
//   baseStep = dotSpacing*0.08, dotSpacing = 24 + (7/9)*(8-24) = 11.5556
//   lngStep  = baseStep / max(0.3, cos(lat))
//
// Rotation (autonomous; mouse drag from the web version is intentionally
// dropped): per 60 Hz step, targetYaw += rotationSpeed*0.01 with
// rotationSpeed = -(2/10)*0.9 = -0.18, then yaw lerps toward target with
// factor mapLinear(0.8, 0,1, 0.4,0.03) = 0.104 — identical to the reference's
// requestAnimationFrame loop. The saver runs at 30 fps and performs two 60 Hz
// substeps per frame, so real-time speed matches (-0.108 rad/s, drifting left).

@objc(UltracodeGlobeView)
final class UltracodeGlobeView: ScreenSaverView {

    // MARK: - Ported constants

    private let globeRadius: Double = 0.2 + (7.0 / 19.0) * 1.8      // 0.86315789
    private var cameraDistance: Double { 2.5 / globeRadius }         // 2.89634...
    private let fovFactor: Double = 1.0 / tan(25.0 * Double.pi / 180.0) // fov 50
    private let rotationSpeed: Double = -0.18                        // speed 2, left
    private let lerpFactor: Double = 0.4 + 0.8 * (0.03 - 0.4)        // 0.104
    private let pitch: Double = 23.0 * Double.pi / 180.0             // initialLatitude
    private let initialYaw: Double = -23.0 * Double.pi / 180.0       // initialLongitude
    private let dotWorldRadius: Double = 0.01 * (0.1 + (4.0 / 9.0) * 0.4) // 0.0027778
    private let tubeWorldRadius: Double = 0.001   // (width/10)*0.01, width 1 (grid & outline)
    private let baseStep: Double = (24.0 + (7.0 / 9.0) * (8.0 - 24.0)) * 0.08 // 0.924444

    private let graticuleColor = CGColor(red: 212.0 / 255.0, green: 212.0 / 255.0,
                                         blue: 212.0 / 255.0, alpha: 1.0)   // #D4D4D4
    private let outlineColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1) // #ffffff
    private let dotColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1)     // #ffffff
    private let oceanColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)   // #000000

    // MARK: - State

    private var yaw: Double = 0
    private var targetYaw: Double = 0

    // Precomputed unit-sphere geometry (x = cos(lat)sin(lng), y = sin(lat),
    // z = cos(lat)cos(lng) — same latLngToPosition as the reference).
    private var dotUnits: [Double] = []            // flattened x,y,z
    private var outlineRings: [[Double]] = []      // each: flattened x,y,z (closed)
    private var gridLines: [[Double]] = []         // graticule polylines

    // Reusable device-resolution splat buffer for the land dots (drawing ~7k
    // antialiased CGPath ellipses per frame is too slow; splatting analytic-AA
    // circles into a premultiplied RGBA buffer and compositing once is not).
    private var dotBuf: UnsafeMutablePointer<UInt8>? = nil
    private var dotBufSide: Int = 0

    deinit { dotBuf?.deallocate() }

    // MARK: - Init

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        animationTimeInterval = 1.0 / 30.0
        yaw = initialYaw
        targetYaw = initialYaw
        buildGraticule()
        if let rings = loadLandRings() {
            buildContinentOutlines(rings: rings)
            buildDots(rings: rings)
        }
        NSLog("UltracodeGlobe: %d dots, %d outline rings, %d grid lines",
              dotUnits.count / 3, outlineRings.count, gridLines.count)
    }

    override var hasConfigureSheet: Bool { false }
    override var configureSheet: NSWindow? { nil }

    // MARK: - Land data loading

    private struct LandRing {
        var isOuter: Bool
        var coords: [Double]   // flattened lng, lat (degrees)
    }

    private func landDataURL() -> URL? {
        let bundle = Bundle(for: UltracodeGlobeView.self)
        if let url = bundle.url(forResource: "land", withExtension: "bin") {
            return url
        }
        if let env = ProcessInfo.processInfo.environment["ULTRACODE_GLOBE_DATA"] {
            let url = URL(fileURLWithPath: env)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        if let url = Bundle.main.url(forResource: "land", withExtension: "bin") {
            return url
        }
        return nil
    }

    private func loadLandRings() -> [LandRing]? {
        guard let url = landDataURL(), let data = try? Data(contentsOf: url) else {
            NSLog("UltracodeGlobe: land.bin not found — rendering globe without landmass")
            return nil
        }
        var offset = 0
        func readU8() -> UInt8 { defer { offset += 1 }; return data[offset] }
        func readU32() -> UInt32 {
            defer { offset += 4 }
            return UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8)
                | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
        }
        func readI16() -> Int16 {
            defer { offset += 2 }
            return Int16(bitPattern: UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8))
        }
        guard data.count > 8,
              data[0] == 0x4C, data[1] == 0x4E, data[2] == 0x44, data[3] == 0x31 else {
            NSLog("UltracodeGlobe: bad land.bin header")
            return nil
        }
        offset = 4
        let ringCount = Int(readU32())
        var rings: [LandRing] = []
        rings.reserveCapacity(ringCount)
        for _ in 0..<ringCount {
            guard offset + 5 <= data.count else { return rings }
            let count = Int(readU32())
            let isOuter = readU8() == 1
            guard offset + count * 4 <= data.count else { return rings }
            var coords = [Double]()
            coords.reserveCapacity(count * 2)
            for _ in 0..<count {
                let lng = Double(readI16()) / 100.0
                let lat = Double(readI16()) / 100.0
                coords.append(lng)
                coords.append(lat)
            }
            rings.append(LandRing(isOuter: isOuter, coords: coords))
        }
        return rings
    }

    // MARK: - Geometry building

    private static func unitPos(lat: Double, lng: Double) -> (Double, Double, Double) {
        let latRad = lat * Double.pi / 180.0
        let lngRad = lng * Double.pi / 180.0
        return (cos(latRad) * sin(lngRad), sin(latRad), cos(latRad) * cos(lngRad))
    }

    private func buildGraticule() {
        // Latitude circles every 15 deg (poles are degenerate points; skip them).
        var lat = -90.0
        while lat <= 90.0 {
            if abs(lat) < 90.0 {
                var line = [Double]()
                let segments = 64
                for i in 0...segments {
                    let lng = Double(i) / Double(segments) * 360.0 - 180.0
                    let p = Self.unitPos(lat: lat, lng: lng)
                    line.append(contentsOf: [p.0, p.1, p.2])
                }
                gridLines.append(line)
            }
            lat += 15.0
        }
        // Meridians every 15 deg.
        var lng = -180.0
        while lng < 180.0 {
            var line = [Double]()
            let segments = 64
            for i in 0...segments {
                let lat = Double(i) / Double(segments) * 180.0 - 90.0
                let p = Self.unitPos(lat: lat, lng: lng)
                line.append(contentsOf: [p.0, p.1, p.2])
            }
            gridLines.append(line)
            lng += 15.0
        }
    }

    /// Reference simplifyRing with detail=5 -> step 6.
    private func simplifyRing(_ coords: [Double]) -> [Double] {
        let n = coords.count / 2
        if n < 2 { return coords }
        let step = 6
        var out = [Double]()
        out.append(coords[0]); out.append(coords[1])
        var i = step
        while i < n - 1 {
            let idx = min(i, n - 1)
            out.append(coords[idx * 2]); out.append(coords[idx * 2 + 1])
            i += step
        }
        let lastLng = coords[(n - 1) * 2], lastLat = coords[(n - 1) * 2 + 1]
        let isClosed = abs(lastLng - coords[0]) < 1e-4 && abs(lastLat - coords[1]) < 1e-4
        if !isClosed { out.append(lastLng); out.append(lastLat) }
        return out.count >= 4 ? out : coords
    }

    private func buildContinentOutlines(rings: [LandRing]) {
        for ring in rings where ring.isOuter {
            let simplified = simplifyRing(ring.coords)
            let n = simplified.count / 2
            guard n >= 2 else { continue }
            var line = [Double]()
            line.reserveCapacity((n + 1) * 3)
            for i in 0..<n {
                let p = Self.unitPos(lat: simplified[i * 2 + 1], lng: simplified[i * 2])
                line.append(contentsOf: [p.0, p.1, p.2])
            }
            // Close the ring if endpoints differ (> 0.001 world units), like the ref.
            let dx = line[0] - line[line.count - 3]
            let dy = line[1] - line[line.count - 2]
            let dz = line[2] - line[line.count - 1]
            if (dx * dx + dy * dy + dz * dz).squareRoot() * globeRadius > 0.001 {
                line.append(line[0]); line.append(line[1]); line.append(line[2])
            }
            outlineRings.append(line)
        }
    }

    private func buildDots(rings: [LandRing]) {
        // Rasterize the land mask exactly like the reference's 2048x1024
        // offscreen canvas (equirectangular fit, nonzero winding fill).
        let w = 2048, h = 1024
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
        // Flip so buffer row == projected y (top-down).
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setShouldAntialias(true)
        let path = CGMutablePath()
        for ring in rings {
            let n = ring.coords.count / 2
            guard n >= 3 else { continue }
            for i in 0..<n {
                let lng = ring.coords[i * 2], lat = ring.coords[i * 2 + 1]
                let x = (lng + 180.0) / 360.0 * Double(w)
                let y = (90.0 - lat) / 180.0 * Double(h)
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            path.closeSubpath()
        }
        ctx.addPath(path)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fillPath(using: .winding)
        guard let buf = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return }

        func isOnLand(lng: Double, lat: Double) -> Bool {
            var x = Int(((lng + 180.0) / 360.0 * Double(w)).rounded()) % w
            if x < 0 { x += w }
            let y = Int(((90.0 - lat) / 180.0 * Double(h)).rounded())
            let cy = max(0, min(h - 1, y))
            return buf[cy * w + x] > 128
        }

        // Same dot grid as the reference.
        var lat = -90.0
        while lat <= 90.0 {
            let cosLat = cos(abs(lat) * Double.pi / 180.0)
            let lngStep = cosLat > 0.01 ? baseStep / max(0.3, cosLat) : 360.0
            var lng = -180.0
            while lng < 180.0 {
                if isOnLand(lng: lng, lat: lat) {
                    let p = Self.unitPos(lat: lat, lng: lng)
                    dotUnits.append(contentsOf: [p.0, p.1, p.2])
                }
                lng += lngStep
            }
            lat += baseStep
        }
    }

    // MARK: - Animation

    override func animateOneFrame() {
        // Two 60 Hz substeps per 30 fps frame — matches the reference's rAF loop.
        for _ in 0..<2 {
            targetYaw += rotationSpeed * 0.01
            yaw += (targetYaw - yaw) * lerpFactor
        }
        needsDisplay = true
    }

    // MARK: - Rendering

    override func draw(_ rect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let w = Double(bounds.width), h = Double(bounds.height)
        ctx.setFillColor(oceanColor)   // page background + ocean sphere are both black
        ctx.fill(CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height))
        guard w > 1, h > 1 else { return }

        let R = globeRadius
        let d = cameraDistance
        let K = fovFactor * h / 2.0            // pixels per (world unit / depth)
        let cx = w / 2.0, cyc = h / 2.0
        let zThreshold = R / d                 // perspective horizon on the unit sphere

        let cy = cos(yaw), sy = sin(yaw)
        let cp = cos(pitch), sp = sin(pitch)

        // Rotate a unit-sphere point: Rx(pitch) * Ry(yaw) * p (three.js XYZ order,
        // globeGroup.rotation = (pitch, yaw, 0)). Returns rotated unit coords.
        @inline(__always)
        func rotate(_ x: Double, _ y: Double, _ z: Double) -> (Double, Double, Double) {
            let x1 = x * cy + z * sy
            let z1 = -x * sy + z * cy
            let y2 = y * cp - z1 * sp
            let z2 = y * sp + z1 * cp
            return (x1, y2, z2)
        }

        @inline(__always)
        func project(_ x: Double, _ y: Double, _ z: Double) -> (Double, Double, Double) {
            // World coords = unit * R; camera at (0,0,d) looking at origin, y-up.
            let depth = d - z * R
            let s = K / depth
            return (cx + x * R * s, cyc + y * R * s, depth)
        }

        // Tube diameter in px, computed at the globe's front depth (constant width,
        // matching the reference's ~1px tubes).
        let lineWidth = max(0.5, 2.0 * tubeWorldRadius * K / (d - R))

        func strokePolylines(_ lines: [[Double]], color: CGColor) {
            let path = CGMutablePath()
            for line in lines {
                var penDown = false
                var i = 0
                while i < line.count {
                    let (rx, ry, rz) = rotate(line[i], line[i + 1], line[i + 2])
                    if rz > zThreshold {
                        let (sx, syp, _) = project(rx, ry, rz)
                        if penDown { path.addLine(to: CGPoint(x: sx, y: syp)) }
                        else { path.move(to: CGPoint(x: sx, y: syp)); penDown = true }
                    } else {
                        penDown = false
                    }
                    i += 3
                }
            }
            ctx.setStrokeColor(color)
            ctx.setLineWidth(CGFloat(lineWidth))
            ctx.setLineJoin(.round)
            ctx.setLineCap(.round)
            ctx.addPath(path)
            ctx.strokePath()
        }

        // Draw order: graticule, continent outlines, land dots (renderOrder 0 in
        // the reference; the ocean sphere culls the back hemisphere, which the
        // zThreshold test reproduces).
        strokePolylines(gridLines, color: graticuleColor)
        strokePolylines(outlineRings, color: outlineColor)

        if !dotUnits.isEmpty {
            // Device pixel scale of the destination (retina-aware).
            let devT = ctx.userSpaceToDeviceSpaceTransform
            let scale = max(1.0, Double(abs(devT.a)))

            // Globe silhouette radius in user px, plus margin for dot size + AA.
            let sinA = R / d
            let silhouette = sinA / (1.0 - sinA * sinA).squareRoot() * K
            let margin = dotWorldRadius * K / (d - R) + 4.0
            let rr = silhouette + margin
            // Snap the region origin to the device pixel grid (1:1 blit).
            let x0 = (Darwin.floor((cx - rr) * scale)) / scale
            let y0 = (Darwin.floor((cyc - rr) * scale)) / scale
            let side = Int((2.0 * rr * scale).rounded(.up)) + 2
            let sideUser = Double(side) / scale
            let yTop = y0 + sideUser

            if dotBuf == nil || dotBufSide != side {
                dotBuf?.deallocate()
                dotBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: side * side * 4)
                dotBufSide = side
            }
            guard let buf = dotBuf else { return }
            memset(buf, 0, side * side * 4)

            var i = 0
            while i < dotUnits.count {
                let (rx, ry, rz) = rotate(dotUnits[i], dotUnits[i + 1], dotUnits[i + 2])
                i += 3
                guard rz > zThreshold else { continue }
                let (sx, syp, depth) = project(rx, ry, rz)
                let r = dotWorldRadius * K / depth * scale   // device px, perspective-attenuated
                let bx = (sx - x0) * scale
                let by = (yTop - syp) * scale                // row 0 = top of region
                let minX = max(0, Int(bx - r - 1.0)), maxX = min(side - 1, Int(bx + r + 1.0))
                let minY = max(0, Int(by - r - 1.0)), maxY = min(side - 1, Int(by + r + 1.0))
                guard minX <= maxX, minY <= maxY else { continue }
                var py = minY
                while py <= maxY {
                    let dy = Double(py) + 0.5 - by
                    let rowBase = py * side
                    var px = minX
                    while px <= maxX {
                        let dx = Double(px) + 0.5 - bx
                        let cov = r - (dx * dx + dy * dy).squareRoot() + 0.5
                        if cov > 0 {
                            let v = UInt8(min(1.0, cov) * 255.0)
                            let idx = (rowBase + px) * 4
                            if v > buf[idx + 3] {
                                buf[idx] = v; buf[idx + 1] = v
                                buf[idx + 2] = v; buf[idx + 3] = v   // premultiplied white
                            }
                        }
                        px += 1
                    }
                    py += 1
                }
            }

            if let maskCtx = CGContext(
                data: buf, width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
               let image = maskCtx.makeImage() {
                let q = ctx.interpolationQuality
                ctx.interpolationQuality = .none
                ctx.draw(image, in: CGRect(x: x0, y: y0, width: sideUser, height: sideUser))
                ctx.interpolationQuality = q
            }
        }
    }

    override func startAnimation() { super.startAnimation() }
    override func stopAnimation() { super.stopAnimation() }
}
