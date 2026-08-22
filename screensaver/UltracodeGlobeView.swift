import AppKit
import ScreenSaver

private extension Notification.Name {
    static let globeConfigChanged = Notification.Name("UltracodeGlobeConfigChanged")
}

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

    // Cores ativas (definidas por applyTheme; tema 0 = "Base" reproduz o original).
    private var graticuleColor = CGColor(red: 212.0 / 255.0, green: 212.0 / 255.0,
                                         blue: 212.0 / 255.0, alpha: 1.0)   // #D4D4D4
    private var outlineColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1) // #ffffff
    private var dotRGB: (Double, Double, Double) = (1, 1, 1)  // cor do splat dos dots
    private let oceanColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)   // #000000
    // Marcador de posição é semântico: mantém-se verde em TODOS os temas.
    private let locationColor = CGColor(red: 0x30 / 255.0, green: 0xD1 / 255.0,
                                        blue: 0x58 / 255.0, alpha: 1)       // #30D158 (verde Apple)

    // MARK: - Temas

    // "Base" = cores originais do port; os restantes usam as MESMAS stops do
    // UltracodeLife (frio -> quente). Mapeamento monocromático na família do
    // tema: dots = stop quente (6-7), contornos = 5-6, graticule = frio (2-3).
    private struct Theme {
        let name: String
        let stops: [UInt32]?   // nil = Base (branco / #D4D4D4)
    }

    private static let themes: [Theme] = [
        Theme(name: "Base", stops: nil),
        Theme(name: "Ultracode (lavanda)", stops: [
            0x34313A, 0x3D3946, 0x56506B, 0x6F6590,
            0x9C8FD0, 0xB9AEE8, 0xCFC6F2, 0xEEE9FB,
        ]),
        Theme(name: "Doom clássico", stops: [
            0x3A322C, 0x571B08, 0x9F2A00, 0xD75F07,
            0xF0A039, 0xFAD75C, 0xFFF3A0, 0xFFFFE6,
        ]),
        Theme(name: "Matrix", stops: [
            0x303A33, 0x2F4D33, 0x2F6B3A, 0x32934A,
            0x3FBF5F, 0x73E08C, 0xB6F2C2, 0xEFFFF2,
        ]),
    ]

    private static func mix(_ a: UInt32, _ b: UInt32) -> (Double, Double, Double) {
        func c(_ h: UInt32, _ s: UInt32) -> Double { Double((h >> s) & 0xFF) / 255.0 }
        return ((c(a, 16) + c(b, 16)) / 2,
                (c(a, 8) + c(b, 8)) / 2,
                (c(a, 0) + c(b, 0)) / 2)
    }

    private func applyTheme() {
        let theme = Self.themes[config.theme]
        if let stops = theme.stops {
            dotRGB = Self.mix(stops[6], stops[7])            // stop quente 6-7
            let line = Self.mix(stops[5], stops[6])          // contornos 5-6
            outlineColor = CGColor(red: line.0, green: line.1, blue: line.2, alpha: 1)
            let grid = Self.mix(stops[2], stops[3])          // graticule frio 2-3
            graticuleColor = CGColor(red: grid.0, green: grid.1, blue: grid.2, alpha: 1)
        } else {
            dotRGB = (1, 1, 1)
            outlineColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
            graticuleColor = CGColor(red: 212.0 / 255.0, green: 212.0 / 255.0,
                                     blue: 212.0 / 255.0, alpha: 1)
        }
    }

    // MARK: - User configuration

    private struct Config {
        var theme = 0
        var speed = 1.0          // multiplicador de rotationSpeed (0.25x-3x)
        var showLocation = true  // marcador verde da posição atual
        var density = 1.0        // multiplicador de baseStep (0.5x-2x)
    }

    private static let moduleName = "com.williansaez.ultracode-globe"

    private static func makeDefaults() -> ScreenSaverDefaults? {
        let d = ScreenSaverDefaults(forModuleWithName: moduleName)
        d?.register(defaults: [
            "theme": 0,
            "speed": 1.0,
            "showLocation": true,
            "density": 1.0,
        ])
        return d
    }

    private var config = Config()
    private var builtDensity = 1.0   // densidade com que dotUnits foi construído

    private func loadConfig() {
        guard let d = Self.makeDefaults() else { return }
        config.theme = min(max(d.integer(forKey: "theme"), 0), Self.themes.count - 1)
        config.speed = min(max(d.double(forKey: "speed"), 0.25), 3.0)
        config.showLocation = d.bool(forKey: "showLocation")
        config.density = min(max(d.double(forKey: "density"), 0.5), 2.0)
        applyTheme()
        if config.density != builtDensity, let rings = landRings {
            dotUnits.removeAll(keepingCapacity: true)
            buildDots(rings: rings)
        }
    }

    // MARK: - State

    private var yaw: Double = 0
    private var targetYaw: Double = 0

    // Precomputed unit-sphere geometry (x = cos(lat)sin(lng), y = sin(lat),
    // z = cos(lat)cos(lng) — same latLngToPosition as the reference).
    private var dotUnits: [Double] = []            // flattened x,y,z
    private var outlineRings: [[Double]] = []      // each: flattened x,y,z (closed)
    private var gridLines: [[Double]] = []         // graticule polylines
    private var locationUnit: (Double, Double, Double)? = nil  // posição atual (verde)
    private var landRings: [LandRing]? = nil       // retidos para reconstruir dots

    // Reusable device-resolution splat buffer for the land dots (drawing ~7k
    // antialiased CGPath ellipses per frame is too slow; splatting analytic-AA
    // circles into a premultiplied RGBA buffer and compositing once is not).
    private var dotBuf: UnsafeMutablePointer<UInt8>? = nil
    private var dotBufSide: Int = 0

    deinit {
        NotificationCenter.default.removeObserver(self)
        dotBuf?.deallocate()
    }

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
        landRings = loadLandRings()
        if let rings = landRings {
            buildContinentOutlines(rings: rings)
        }
        loadConfig()   // aplica tema e constrói dots com a densidade configurada
        if dotUnits.isEmpty, let rings = landRings {
            buildDots(rings: rings)
        }
        locationUnit = Self.timezoneLocationUnit()
        NotificationCenter.default.addObserver(self, selector: #selector(configChanged(_:)),
                                               name: .globeConfigChanged, object: nil)
        NSLog("UltracodeGlobe: %d dots, %d outline rings, %d grid lines, location %@",
              dotUnits.count / 3, outlineRings.count, gridLines.count,
              locationUnit != nil ? "ok" : "indisponível")
    }

    // MARK: - Localização atual (sem permissões)

    // Coordenadas da cidade do fuso horário atual, via /usr/share/zoneinfo/zone.tab
    // (offline, sem CoreLocation — precisão de cidade chega para a malha de ~0.9°).
    private static func timezoneLocationUnit() -> (Double, Double, Double)? {
        let tzId = TimeZone.current.identifier
        guard let content = try? String(contentsOfFile: "/usr/share/zoneinfo/zone.tab",
                                        encoding: .utf8) else { return nil }
        for line in content.split(separator: "\n") {
            guard !line.hasPrefix("#") else { continue }
            let cols = line.split(separator: "\t")
            guard cols.count >= 3, cols[2] == Substring(tzId) else { continue }
            guard let (lat, lng) = parseISO6709(String(cols[1])) else { return nil }
            return unitPos(lat: lat, lng: lng)
        }
        return nil
    }

    // "±DDMM±DDDMM" ou "±DDMMSS±DDDMMSS" (formato do zone.tab)
    private static func parseISO6709(_ s: String) -> (lat: Double, lng: Double)? {
        let chars = Array(s)
        guard chars.count > 1,
              let split = (1..<chars.count).first(where: { chars[$0] == "+" || chars[$0] == "-" })
        else { return nil }

        func value(_ part: ArraySlice<Character>, degDigits: Int) -> Double? {
            guard let first = part.first, first == "+" || first == "-" else { return nil }
            let digits = String(part.dropFirst())
            guard digits.count >= degDigits, digits.allSatisfy({ $0.isNumber }) else { return nil }
            let deg = Double(digits.prefix(degDigits))!
            var rest = digits.dropFirst(degDigits)
            var minutes = 0.0, seconds = 0.0
            if rest.count >= 2 { minutes = Double(rest.prefix(2))!; rest = rest.dropFirst(2) }
            if rest.count >= 2 { seconds = Double(rest.prefix(2))! }
            return (first == "-" ? -1.0 : 1.0) * (deg + minutes / 60.0 + seconds / 3600.0)
        }

        guard let lat = value(chars[0..<split], degDigits: 2),
              let lng = value(chars[split...], degDigits: 3) else { return nil }
        return (lat, lng)
    }

    @objc private func configChanged(_ note: Notification) {
        loadConfig()
        needsDisplay = true
    }

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

        // Same dot grid as the reference; step escalado pela densidade
        // configurada (0.5x = mais denso, 2x = mais esparso).
        let step = baseStep * config.density
        var lat = -90.0
        while lat <= 90.0 {
            let cosLat = cos(abs(lat) * Double.pi / 180.0)
            let lngStep = cosLat > 0.01 ? step / max(0.3, cosLat) : 360.0
            var lng = -180.0
            while lng < 180.0 {
                if isOnLand(lng: lng, lat: lat) {
                    let p = Self.unitPos(lat: lat, lng: lng)
                    dotUnits.append(contentsOf: [p.0, p.1, p.2])
                }
                lng += lngStep
            }
            lat += step
        }
        builtDensity = config.density
    }

    // MARK: - Animation

    override func animateOneFrame() {
        // Two 60 Hz substeps per 30 fps frame — matches the reference's rAF loop.
        for _ in 0..<2 {
            targetYaw += rotationSpeed * config.speed * 0.01
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

            // Cor do splat premultiplicada pelo tema (antes: branco hardcoded).
            let dR = dotRGB.0, dG = dotRGB.1, dB = dotRGB.2

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
                            let a = min(1.0, cov)
                            let v = UInt8(a * 255.0)
                            let idx = (rowBase + px) * 4
                            if v > buf[idx + 3] {
                                buf[idx] = UInt8(a * dR * 255.0)     // premultiplied
                                buf[idx + 1] = UInt8(a * dG * 255.0) // pela cor do tema
                                buf[idx + 2] = UInt8(a * dB * 255.0)
                                buf[idx + 3] = v
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

        // Posição atual: bolinha verde por cima dos dots (mesma rotação/culling)
        if config.showLocation, let loc = locationUnit {
            let (rx, ry, rz) = rotate(loc.0, loc.1, loc.2)
            if rz > zThreshold {
                let (sx, syp, depth) = project(rx, ry, rz)
                let r = CGFloat(dotWorldRadius * K / depth) * 1.8
                ctx.setFillColor(locationColor)
                ctx.fillEllipse(in: CGRect(x: sx - Double(r), y: syp - Double(r),
                                           width: Double(r) * 2, height: Double(r) * 2))
            }
        }
    }

    override func startAnimation() {
        loadConfig()
        super.startAnimation()
    }
    override func stopAnimation() { super.stopAnimation() }

    // MARK: - Configure sheet

    private var sheet: NSPanel?
    private var themePopup: NSPopUpButton?
    private var speedSlider: NSSlider?
    private var densitySlider: NSSlider?
    private var locationCheck: NSButton?

    override var hasConfigureSheet: Bool { true }

    override var configureSheet: NSWindow? {
        if let sheet { return sheet }
        loadConfig()

        // Frames fixos, zero Auto Layout: a sheet é medida e apresentada
        // remotamente (legacyScreenSaver -> Definições do Sistema) antes de
        // qualquer passagem de layout; painéis com autolayout colapsam aí.
        let W: CGFloat = 440, H: CGFloat = 212
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                            styleMask: [.titled],
                            backing: .buffered, defer: false)
        panel.title = "Globo"
        panel.isReleasedWhenClosed = false

        let content = panel.contentView!

        func label(_ text: String, row y: CGFloat) -> NSTextField {
            let l = NSTextField(labelWithString: text)
            l.alignment = .right
            l.frame = NSRect(x: 20, y: y, width: 150, height: 20)
            content.addSubview(l)
            return l
        }
        func slider(_ value: Double, _ minV: Double, _ maxV: Double,
                    row y: CGFloat) -> NSSlider {
            let s = NSSlider(value: value, minValue: minV, maxValue: maxV,
                             target: nil, action: nil)
            s.isContinuous = false
            s.frame = NSRect(x: 180, y: y - 2, width: 240, height: 24)
            content.addSubview(s)
            return s
        }

        _ = label("Tema:", row: 164)
        let popup = NSPopUpButton(frame: NSRect(x: 178, y: 158, width: 244, height: 26),
                                  pullsDown: false)
        popup.addItems(withTitles: Self.themes.map(\.name))
        popup.selectItem(at: config.theme)
        content.addSubview(popup)

        _ = label("Velocidade de rotação:", row: 126)
        let sSlider = slider(config.speed, 0.25, 3.0, row: 126)

        _ = label("Densidade de pontos:", row: 88)
        // Slider mostra "mais pontos à direita": inverte o multiplicador de
        // baseStep (2x step = esquerda/esparso, 0.5x step = direita/denso).
        let dSlider = slider(-config.density, -2.0, -0.5, row: 88)

        let locCheck = NSButton(checkboxWithTitle: "Mostrar posição atual",
                                target: nil, action: nil)
        locCheck.state = config.showLocation ? .on : .off
        locCheck.frame = NSRect(x: 180, y: 56, width: 248, height: 20)
        content.addSubview(locCheck)

        let cancel = NSButton(title: "Cancelar", target: self,
                              action: #selector(sheetCancel(_:)))
        cancel.bezelStyle = .rounded
        cancel.frame = NSRect(x: W - 200, y: 12, width: 90, height: 30)
        content.addSubview(cancel)

        let ok = NSButton(title: "OK", target: self,
                          action: #selector(sheetOK(_:)))
        ok.bezelStyle = .rounded
        ok.keyEquivalent = "\r"
        ok.frame = NSRect(x: W - 102, y: 12, width: 82, height: 30)
        content.addSubview(ok)

        content.layoutSubtreeIfNeeded()

        sheet = panel
        themePopup = popup
        speedSlider = sSlider
        densitySlider = dSlider
        locationCheck = locCheck
        return panel
    }

    @objc private func sheetOK(_ sender: Any?) {
        if let d = Self.makeDefaults() {
            d.set(themePopup?.indexOfSelectedItem ?? 0, forKey: "theme")
            d.set(speedSlider?.doubleValue ?? 1.0, forKey: "speed")
            d.set(-(densitySlider?.doubleValue ?? -1.0), forKey: "density")
            d.set(locationCheck?.state == .on, forKey: "showLocation")
            d.synchronize()
        }
        NotificationCenter.default.post(name: .globeConfigChanged, object: nil)
        closeSheet()
    }

    @objc private func sheetCancel(_ sender: Any?) {
        closeSheet()
    }

    private func closeSheet() {
        guard let sheet else { return }
        if let parent = sheet.sheetParent {
            parent.endSheet(sheet)
        } else {
            sheet.close()
        }
    }
}
