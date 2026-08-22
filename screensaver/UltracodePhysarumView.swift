import AppKit
import ScreenSaver

private extension Notification.Name {
    static let physarumConfigChanged = Notification.Name("UltracodePhysarumConfigChanged")
}

@objc(UltracodePhysarumView)
public final class UltracodePhysarumView: ScreenSaverView {

    // MARK: - Color helpers

    private struct RGB {
        var r: CGFloat, g: CGFloat, b: CGFloat
        init(_ hex: UInt32) {
            r = CGFloat((hex >> 16) & 0xFF) / 255
            g = CGFloat((hex >> 8) & 0xFF) / 255
            b = CGFloat(hex & 0xFF) / 255
        }
        init(r: CGFloat, g: CGFloat, b: CGFloat) {
            self.r = r; self.g = g; self.b = b
        }
        static func lerp(_ a: RGB, _ b: RGB, _ t: CGFloat) -> RGB {
            RGB(r: a.r + (b.r - a.r) * t,
                g: a.g + (b.g - a.g) * t,
                b: a.b + (b.b - a.b) * t)
        }
        var color: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
    }

    private struct Theme {
        let name: String
        let stops: [UInt32]
    }

    private static let themes: [Theme] = [
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
        Theme(name: "Mono", stops: [
            0x141414, 0x2A2A2A, 0x454545, 0x656565,
            0x8A8A8A, 0xB4B4B4, 0xDCDCDC, 0xFFFFFF,
        ]),
    ]

    private let bgTop = RGB(0x232126)
    private let bgBottom = RGB(0x1B191E)

    private func ramp(_ v: CGFloat, stops: [RGB]) -> RGB {
        let x = min(max(v, 0), 1) * CGFloat(stops.count - 1)
        let i = min(Int(x), stops.count - 2)
        return RGB.lerp(stops[i], stops[i + 1], x - CGFloat(i))
    }

    // MARK: - User configuration

    private struct Config {
        var theme = 0
        var pitch: Double = 26
        var fps: Double = 30
        var floor: Double = 0.10
        var bloom = true
    }

    private static let moduleName = "com.williansaez.ultracode-physarum"

    private static func makeDefaults() -> ScreenSaverDefaults? {
        let d = ScreenSaverDefaults(forModuleWithName: moduleName)
        d?.register(defaults: [
            "theme": 0,
            "pitch": 26.0,
            "fps": 30.0,
            "floorLevel": 0.05,
            "bloom": true,
        ])
        return d
    }

    private var config = Config()

    private func loadConfig() {
        guard let d = Self.makeDefaults() else { return }
        config.theme = min(max(d.integer(forKey: "theme"), 0), Self.themes.count - 1)
        config.pitch = min(max(d.double(forKey: "pitch"), 8.0), 80.0)
        config.fps = min(max(d.double(forKey: "fps"), 15.0), 60.0)
        config.floor = min(max(d.double(forKey: "floorLevel"), 0.0), 0.30)
        config.bloom = d.bool(forKey: "bloom")
        animationTimeInterval = 1.0 / config.fps
    }

    // MARK: - Display grid

    private var cols = 0
    private var rows = 0
    private var pitch: CGFloat = 26
    private var cellSide: CGFloat = 18
    private var originX: CGFloat = 0
    private var originY: CGFloat = 0

    private var levelColors: [NSColor] = []
    private var levelCGColors: [CGColor] = []
    private let colorLevels = 32
    private var floorLevelIndex = 0

    /// Empty lattice (bg gradient + every cell at floor brightness),
    /// pre-rendered once per rebuildGrid() and blitted each frame.
    private var floorImage: CGImage?

    // MARK: - Space-colonization growth from one inoculation point

    // A colony is seeded at a single point. Food (attractors) is scattered
    // over the WHOLE screen; the network grows from the seed toward it,
    // branching as it goes, until it has reached across the screen — a
    // dendritic tree radiating from the inoculation point, exactly like the
    // slime mold spreading across a Petri dish. Vein brightness/thickness
    // follows flux (subtree size): fat bright trunks near the seed, fine
    // faint tips at the frontier. When the food is exhausted the colony
    // holds briefly, dissolves, and re-inoculates at a new point — endless.

    private let simScale = 3
    private var fw = 0
    private var fh = 0
    private var trail: [Float] = []     // rasterized brightness, rebuilt per frame

    // Network nodes (parallel arrays).
    private var nx: [Float] = []
    private var ny: [Float] = []
    private var nparent: [Int] = []
    private var ndepth: [Int] = []
    private var nflux: [Float] = []     // subtree size = vein thickness/brightness
    private var nage: [Int] = []
    private var maxFlux: Float = 1

    // Attractors (food).
    private var ax: [Float] = []
    private var ay: [Float] = []
    private var aalive: [Bool] = []

    // Geometry (sim-cell units), set in rebuildGrid.
    private var segLen: Float = 3.5
    private var killR: Float = 3.0
    private var inflR: Float = 13

    // Spatial hash of nodes for nearest-node queries.
    private var bucket: [[Int]] = []
    private var bucketsX = 1
    private var bucketsY = 1
    private var bucketSize: Float = 13

    // Lifecycle: 0 = growing, 1 = holding, 2 = dissolving.
    private var mode = 0
    private var holdTimer = 0
    private var fadeAlpha: Float = 1
    private var stalledTicks = 0
    private var frameCount = 0
    private let growEvery = 2           // advance the frontier every N frames (creep)
    private let holdFrames = 130
    private let fadeFrames = 48
    private var pulsePhase: Float = 0

    private var rngState: UInt64 = 0x243F6A8885A308D3
    private func nextRand() -> UInt64 {
        rngState ^= rngState << 13
        rngState ^= rngState >> 7
        rngState ^= rngState << 17
        return rngState
    }
    private func rand01() -> Float { Float(nextRand() & 0xFFFFFF) / Float(0x1000000) }

    // MARK: - Init

    public override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        loadConfig()
        NotificationCenter.default.addObserver(
            self, selector: #selector(configChanged),
            name: .physarumConfigChanged, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func configChanged() {
        loadConfig()
        rebuildGrid()
        needsDisplay = true
    }

    // MARK: - Layout

    private func rebuildGrid() {
        pitch = isPreview ? 9 : CGFloat(config.pitch)
        cellSide = pitch * 0.70
        cols = max(8, Int(bounds.width / pitch) + 2)
        rows = max(8, Int(bounds.height / pitch) + 2)
        originX = (bounds.width - CGFloat(cols - 1) * pitch) / 2
        originY = (bounds.height - CGFloat(rows - 1) * pitch) / 2

        fw = cols * simScale
        fh = rows * simScale
        trail = .init(repeating: 0, count: fw * fh)

        // Branch grain. Long enough that veins sit >1 display cell apart so
        // the network reads as dendrites with dark gaps, not a solid mass.
        segLen = max(3.0, Float(min(fw, fh)) * 0.032)
        killR = segLen * 0.9
        inflR = segLen * 3.6
        bucketSize = inflR
        bucketsX = Int(Float(fw) / bucketSize) + 2
        bucketsY = Int(Float(fh) / bucketSize) + 2

        let stops = Self.themes[config.theme].stops.map(RGB.init)
        let f = CGFloat(config.floor)
        levelColors = (0..<colorLevels).map { l in
            let b = f + (1 - f) * CGFloat(l) / CGFloat(colorLevels - 1)
            return ramp(b, stops: stops).color
        }
        levelCGColors = levelColors.map(\.cgColor)
        // Quantized level of an empty cell: b = max(floor, 0) = floor.
        floorLevelIndex = min(colorLevels - 1,
                              Int(CGFloat(config.floor) * CGFloat(colorLevels - 1)))

        rebuildFloorImage()
        reseed()
    }

    /// Renders the empty lattice (gradient + all cells at floor brightness)
    /// once into a CGImage at Retina scale; draw() blits it instead of
    /// filling thousands of floor cells per frame.
    private func rebuildFloorImage() {
        floorImage = nil
        let w = bounds.width, h = bounds.height
        guard w >= 1, h >= 1 else { return }
        let scale = window?.backingScaleFactor ?? 2
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil,
                                  width: Int(w * scale), height: Int(h * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        ctx.scaleBy(x: scale, y: scale)

        // Background gradient, same as drawBackground().
        let colors = [bgTop.color.cgColor, bgBottom.color.cgColor] as CFArray
        if let grad = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(grad,
                                   start: CGPoint(x: 0, y: h),
                                   end: CGPoint(x: 0, y: 0),
                                   options: [])
        } else {
            ctx.setFillColor(bgTop.color.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }

        // Every cell at the floor color, one batched fill.
        let path = CGMutablePath()
        let radius = cellSide * 0.28
        for j in 0..<rows {
            let cy = originY + CGFloat(j) * pitch
            for i in 0..<cols {
                let cx = originX + CGFloat(i) * pitch
                path.addPath(CGPath(
                    roundedRect: CGRect(x: cx - cellSide / 2, y: cy - cellSide / 2,
                                        width: cellSide, height: cellSide),
                    cornerWidth: radius, cornerHeight: radius, transform: nil))
            }
        }
        ctx.setFillColor(levelCGColors[floorLevelIndex])
        ctx.addPath(path)
        ctx.fillPath()

        floorImage = ctx.makeImage()
    }

    private func reseed() {
        // Food scattered over the WHOLE screen; spacing leaves gaps between
        // branches. The network will grow from the seed to reach all of it.
        let spacing = segLen * 1.7
        let target = min(4000, max(200, Int(Float(fw * fh) / (spacing * spacing))))
        ax.removeAll(keepingCapacity: true)
        ay.removeAll(keepingCapacity: true)
        aalive.removeAll(keepingCapacity: true)
        for _ in 0..<target {
            ax.append(rand01() * Float(fw))
            ay.append(rand01() * Float(fh))
            aalive.append(true)
        }

        // A single inoculation point somewhere on the screen.
        let sx = (0.2 + 0.6 * rand01()) * Float(fw)
        let sy = (0.2 + 0.6 * rand01()) * Float(fh)
        nx = [sx]; ny = [sy]
        nparent = [-1]; ndepth = [0]; nflux = [1]; nage = [0]
        maxFlux = 1

        mode = 0
        fadeAlpha = 1
        stalledTicks = 0
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        rebuildGrid()
    }

    public override func startAnimation() {
        loadConfig()
        super.startAnimation()
        rebuildGrid()
    }

    // MARK: - Growth (space colonization)

    private func rebuildBuckets() {
        let total = bucketsX * bucketsY
        if bucket.count != total {
            bucket = .init(repeating: [], count: total)
        } else {
            for i in 0..<total { bucket[i].removeAll(keepingCapacity: true) }
        }
        for i in 0..<nx.count {
            let bx = min(bucketsX - 1, max(0, Int(nx[i] / bucketSize)))
            let by = min(bucketsY - 1, max(0, Int(ny[i] / bucketSize)))
            bucket[by * bucketsX + bx].append(i)
        }
    }

    private func nearestNode(_ px: Float, _ py: Float) -> (Int, Float) {
        let bx = min(bucketsX - 1, max(0, Int(px / bucketSize)))
        let by = min(bucketsY - 1, max(0, Int(py / bucketSize)))
        var best = -1
        var bestD2 = Float.greatestFiniteMagnitude
        var dy = -1
        while dy <= 1 {
            let cy = by + dy
            if cy >= 0 && cy < bucketsY {
                var dx = -1
                while dx <= 1 {
                    let cx = bx + dx
                    if cx >= 0 && cx < bucketsX {
                        for idx in bucket[cy * bucketsX + cx] {
                            let ddx = nx[idx] - px, ddy = ny[idx] - py
                            let d2 = ddx * ddx + ddy * ddy
                            if d2 < bestD2 { bestD2 = d2; best = idx }
                        }
                    }
                    dx += 1
                }
            }
            dy += 1
        }
        return best == -1 ? (-1, .greatestFiniteMagnitude) : (best, sqrt(bestD2))
    }

    private func growTick() {
        rebuildBuckets()
        let n = nx.count
        var accX = [Float](repeating: 0, count: n)
        var accY = [Float](repeating: 0, count: n)
        var accN = [Int](repeating: 0, count: n)

        var consumed = 0
        for a in 0..<ax.count where aalive[a] {
            let (node, d) = nearestNode(ax[a], ay[a])
            if node < 0 || d > inflR { continue }
            if d < killR { aalive[a] = false; consumed += 1; continue }
            var dx = ax[a] - nx[node], dy = ay[a] - ny[node]
            let len = max(1e-4, sqrt(dx * dx + dy * dy))
            dx /= len; dy /= len
            accX[node] += dx; accY[node] += dy; accN[node] += 1
        }

        var grew = false
        for node in 0..<n where accN[node] > 0 {
            var dx = accX[node], dy = accY[node]
            let len = sqrt(dx * dx + dy * dy)
            if len < 1e-4 { continue }
            dx /= len; dy /= len
            let jit = (rand01() - 0.5) * 0.5
            let ca = cos(jit), sa = sin(jit)
            let rdx = dx * ca - dy * sa
            let rdy = dx * sa + dy * ca
            let cxp = nx[node] + rdx * segLen
            let cyp = ny[node] + rdy * segLen
            if cxp < 1 || cxp >= Float(fw) - 1 || cyp < 1 || cyp >= Float(fh) - 1 { continue }
            nx.append(cxp); ny.append(cyp)
            nparent.append(node); ndepth.append(ndepth[node] + 1)
            nflux.append(1); nage.append(0)
            var p = node
            while p >= 0 {
                nflux[p] += 1
                if nflux[p] > maxFlux { maxFlux = nflux[p] }
                p = nparent[p]
            }
            grew = true
        }

        if !grew || consumed == 0 { stalledTicks += 1 } else { stalledTicks = 0 }
        if nx.count > 12000 { stalledTicks += 5 }   // safety cap
    }

    private func stampSegment(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float,
                              _ inten: Float, thick: Bool) {
        let steps = max(1, Int(max(abs(x1 - x0), abs(y1 - y0))) + 1)
        for s in 0...steps {
            let t = Float(s) / Float(steps)
            let px = x0 + (x1 - x0) * t
            let py = y0 + (y1 - y0) * t
            let xi = Int(px), yi = Int(py)
            if xi < 0 || xi >= fw || yi < 0 || yi >= fh { continue }
            let idx = yi * fw + xi
            if inten > trail[idx] { trail[idx] = inten }
            if thick {
                if xi + 1 < fw { let j = idx + 1; if inten * 0.82 > trail[j] { trail[j] = inten * 0.82 } }
                if yi + 1 < fh { let j = idx + fw; if inten * 0.82 > trail[j] { trail[j] = inten * 0.82 } }
            }
        }
    }

    private func rasterize() {
        for i in 0..<trail.count { trail[i] = 0 }
        let logMax = log(maxFlux + 1)
        for i in 1..<nx.count {
            let p = nparent[i]
            if p < 0 { continue }
            let f = nflux[i]
            let fluxNorm = logMax > 0 ? log(f + 1) / logMax : 0
            var inten = 0.34 + 0.66 * fluxNorm
            let pulse = 1 + 0.18 * sin(pulsePhase - Float(ndepth[i]) * 0.55)
            inten *= pulse
            if nage[i] < 4 { inten = min(1.2, inten + 0.32) }   // glowing frontier
            inten = min(1, inten) * fadeAlpha
            stampSegment(nx[p], ny[p], nx[i], ny[i], inten, thick: f > maxFlux * 0.22)
        }
    }

    public override func animateOneFrame() {
        if trail.isEmpty { rebuildGrid() }
        frameCount += 1
        pulsePhase += 0.4

        switch mode {
        case 0:   // growing — frontier creeps outward from the seed
            if frameCount % growEvery == 0 { growTick() }
            for i in 0..<nage.count { nage[i] += 1 }
            if stalledTicks > 6 { mode = 1; holdTimer = holdFrames }
        case 1:   // holding (network complete, veins pulse)
            for i in 0..<nage.count { nage[i] += 1 }
            holdTimer -= 1
            if holdTimer <= 0 { mode = 2; fadeAlpha = 1 }
        default:  // dissolving, then re-inoculate at a new point
            fadeAlpha -= 1.0 / Float(fadeFrames)
            if fadeAlpha <= 0 { reseed() }
        }

        rasterize()
        needsDisplay = true
    }

    /// Harness-only diagnostics; no effect in the installed saver.
    @objc public func debugDump() {
        let alive = aalive.lazy.filter { $0 }.count
        var lit = 0
        for v in trail where v > 0.2 { lit += 1 }
        let pct = Double(lit) / Double(max(1, trail.count)) * 100
        print(String(format: "nodes=%d foodLeft=%d mode=%d lit>0.2=%.0f%% grid=%dx%d segLen=%.1f",
                     nx.count, alive, mode, pct, cols, rows, segLen))
    }

    // MARK: - Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if trail.isEmpty || floorImage == nil { rebuildGrid() }

        // 1. Blit the pre-rendered empty lattice (gradient + floor cells).
        if let floorImage {
            ctx.draw(floorImage, in: bounds)
        } else {
            drawBackground(ctx)
        }

        // 2. Dynamic cells, batched by quantized color level: one fill per
        //    level instead of one NSBezierPath fill per cell. Cells at the
        //    floor level are skipped — the blit already shows them.
        let bloomLevel = Int(CGFloat(colorLevels - 1) * 0.80)
        var levelPaths = [CGMutablePath?](repeating: nil, count: colorLevels)
        var bloomCells: [(x: CGFloat, y: CGFloat, level: Int)] = []
        let radius = cellSide * 0.28

        for j in 0..<rows {
            let cy = originY + CGFloat(j) * pitch
            for i in 0..<cols {
                var v: Float = 0
                let bx = i * simScale, by = j * simScale
                for sy in 0..<simScale {
                    let base = (by + sy) * fw + bx
                    for sx in 0..<simScale {
                        v = max(v, trail[base + sx])
                    }
                }
                let b = max(CGFloat(config.floor), CGFloat(v))
                let level = min(colorLevels - 1, Int(b * CGFloat(colorLevels - 1)))
                if level <= floorLevelIndex { continue }
                let cx = originX + CGFloat(i) * pitch
                if config.bloom && level >= bloomLevel {
                    bloomCells.append((cx, cy, level))
                    continue
                }
                let path = levelPaths[level] ?? CGMutablePath()
                path.addPath(CGPath(
                    roundedRect: CGRect(x: cx - cellSide / 2, y: cy - cellSide / 2,
                                        width: cellSide, height: cellSide),
                    cornerWidth: radius, cornerHeight: radius, transform: nil))
                levelPaths[level] = path
            }
        }

        for level in 0..<colorLevels {
            guard let path = levelPaths[level] else { continue }
            ctx.setFillColor(levelCGColors[level])
            ctx.addPath(path)
            ctx.fillPath()
        }

        // 3. Bloomed cells on top, individually (few, and they need the shadow).
        for cell in bloomCells {
            drawCell(ctx, x: cell.x, y: cell.y,
                     color: levelColors[cell.level], bloom: true)
        }
    }

    private func drawBackground(_ ctx: CGContext) {
        let colors = [bgTop.color.cgColor, bgBottom.color.cgColor] as CFArray
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        if let grad = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(grad,
                                   start: CGPoint(x: 0, y: bounds.height),
                                   end: CGPoint(x: 0, y: 0),
                                   options: [])
        } else {
            bgTop.color.setFill()
            bounds.fill()
        }
    }

    private func drawCell(_ ctx: CGContext, x: CGFloat, y: CGFloat,
                          color: NSColor, bloom: Bool) {
        let rect = NSRect(x: x - cellSide / 2, y: y - cellSide / 2,
                          width: cellSide, height: cellSide)
        let path = NSBezierPath(roundedRect: rect,
                                xRadius: cellSide * 0.28, yRadius: cellSide * 0.28)
        if bloom {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: cellSide * 1.2,
                          color: color.withAlphaComponent(0.8).cgColor)
            color.setFill()
            path.fill()
            ctx.restoreGState()
        } else {
            color.setFill()
            path.fill()
        }
    }

    // MARK: - Configure sheet

    private var sheet: NSPanel?
    private var themePopup: NSPopUpButton?
    private var pitchSlider: NSSlider?
    private var fpsSlider: NSSlider?
    private var floorSlider: NSSlider?
    private var bloomCheck: NSButton?

    private var pitchDetentValues: [Double] = []

    /// Pitches in [8, 80] where the grid shows NO partially cut cells on the
    /// main screen. Grid math is untouched (cols = Int(w/p)+2, centered, cell
    /// side 0.7p): the overflow edge cells are FULLY offscreen whenever the
    /// fractional parts of w/p and h/p are <= 0.3. Scan that condition and
    /// take the center of each valid band as a slider detent.
    private static func pitchDetents() -> [Double] {
        let size = NSScreen.main?.frame.size ?? NSSize(width: 1512, height: 982)
        let w = Double(size.width), h = Double(size.height)
        var runs: [[Double]] = []
        var cur: [Double] = []
        var p = 8.0
        while p <= 80.0 {
            let fw = w / p - (w / p).rounded(.down)
            let fh = h / p - (h / p).rounded(.down)
            if fw <= 0.3 && fh <= 0.3 {
                cur.append(p)
            } else if !cur.isEmpty {
                runs.append(cur); cur = []
            }
            p += 0.1
        }
        if !cur.isEmpty { runs.append(cur) }
        let detents = runs.map { ($0[$0.count / 2] * 10).rounded() / 10 }
        return detents.isEmpty ? [26.0] : detents
    }

    public override var hasConfigureSheet: Bool { true }

    public override var configureSheet: NSWindow? {
        if let sheet { return sheet }
        loadConfig()

        // Fixed frames, no autolayout: the sheet is measured and presented
        // remotely (legacyScreenSaver -> System Settings) before any layout
        // pass runs; autolayout-sized panels collapse there.
        let W: CGFloat = 440, H: CGFloat = 250
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                            styleMask: [.titled],
                            backing: .buffered, defer: false)
        panel.title = "Bolor Limoso"
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

        _ = label("Tema:", row: 202)
        let popup = NSPopUpButton(frame: NSRect(x: 178, y: 196, width: 244, height: 26),
                                  pullsDown: false)
        popup.addItems(withTitles: Self.themes.map(\.name))
        popup.selectItem(at: config.theme)
        content.addSubview(popup)

        _ = label("Espaçamento da grelha:", row: 164)
        // Detented spacing slider: only positions with no cut cells.
        let detents = Self.pitchDetents()
        pitchDetentValues = detents
        let nearestIdx = detents.enumerated().min {
            abs($0.element - config.pitch) < abs($1.element - config.pitch)
        }!.offset
        let pSlider = slider(Double(nearestIdx), 0, Double(detents.count - 1), row: 164)
        pSlider.numberOfTickMarks = detents.count
        pSlider.allowsTickMarkValuesOnly = true
        _ = label("Velocidade (fps):", row: 126)
        let fSlider = slider(config.fps, 15, 60, row: 126)
        _ = label("Brilho do fundo:", row: 88)
        let flSlider = slider(config.floor, 0.0, 0.30, row: 88)

        let bloom = NSButton(checkboxWithTitle: "Brilho (bloom) nas veias fortes",
                             target: nil, action: nil)
        bloom.state = config.bloom ? .on : .off
        bloom.frame = NSRect(x: 180, y: 56, width: 248, height: 20)
        content.addSubview(bloom)

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
        pitchSlider = pSlider
        fpsSlider = fSlider
        floorSlider = flSlider
        bloomCheck = bloom
        return panel
    }

    @objc private func sheetOK(_ sender: Any?) {
        if let d = Self.makeDefaults() {
            d.set(themePopup?.indexOfSelectedItem ?? 0, forKey: "theme")
            // The pitch slider carries a detent INDEX; translate to points.
            let pitchIdx = Int((pitchSlider?.doubleValue ?? 0).rounded())
            let pitchVal = pitchDetentValues.indices.contains(pitchIdx)
                ? pitchDetentValues[pitchIdx] : 26.0
            d.set(pitchVal, forKey: "pitch")
            d.set(fpsSlider?.doubleValue ?? 30.0, forKey: "fps")
            d.set(floorSlider?.doubleValue ?? 0.10, forKey: "floorLevel")
            d.set(bloomCheck?.state == .on, forKey: "bloom")
            d.synchronize()
        }
        NotificationCenter.default.post(name: .physarumConfigChanged, object: nil)
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
