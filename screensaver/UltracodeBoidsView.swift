import AppKit
import ScreenSaver

private extension Notification.Name {
    static let boidsConfigChanged = Notification.Name("UltracodeBoidsConfigChanged")
}

@objc(UltracodeBoidsView)
public final class UltracodeBoidsView: ScreenSaverView {

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
        let stops: [UInt32]   // cold -> hot
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
        var pitch: Double = 26    // points between cell centers
        var fps: Double = 30      // frames per second
        var floor: Double = 0.10  // empty-cell brightness on the theme ramp
        var bloom = true
    }

    private static let moduleName = "com.williansaez.ultracode-boids"

    private static func makeDefaults() -> ScreenSaverDefaults? {
        let d = ScreenSaverDefaults(forModuleWithName: moduleName)
        d?.register(defaults: [
            "theme": 0,
            "pitch": 26.0,
            "fps": 30.0,
            "floorLevel": 0.10,
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

    // MARK: - Grid + flock state

    private var cols = 0
    private var rows = 0
    private var pitch: CGFloat = 26
    private var cellSide: CGFloat = 18
    private var originX: CGFloat = 0
    private var originY: CGFloat = 0

    /// Decaying brightness field, one Float per display cell (comet trails).
    private var trail: [Float] = []
    private let trailDecay: Float = 0.86
    private let trailFloor: Float = 0.004

    private struct Boid {
        var x: Float, y: Float    // continuous cell coordinates
        var vx: Float, vy: Float  // cells per frame
    }
    private var boids: [Boid] = []
    /// Scales with the grid so flock density looks right at any pitch
    /// (set in rebuildGrid; ~1 boid per 26 cells, clamped).
    private var boidCount = 90

    // Flocking parameters (all in cell units / cells-per-frame).
    private let sepRadius: Float = 2.2
    private let nbRadius: Float = 5.0
    private let sepWeight: Float = 0.055
    private let alignWeight: Float = 0.06
    private let cohWeight: Float = 0.008
    private let wander: Float = 0.035
    private let minSpeed: Float = 0.25
    private let maxSpeed: Float = 0.45

    // Predator event: every ~15 s a point appears inside the flock and the
    // boids flee from it for ~4 s (scatter + regroup drama).
    private var predX: Float = 0
    private var predY: Float = 0
    private var predatorFramesLeft = 0
    private var framesToNextPredator = 0
    private let fleeRadius: Float = 12.0
    private let fleeWeight: Float = 0.30

    /// Precomputed colors: trail brightness quantized to 64 levels.
    private var trailColors: [NSColor] = []
    private var trailCGColors: [CGColor] = []
    private var floorColor: NSColor = .black
    private var headColor: NSColor = .white
    private var predatorColor: NSColor = .white
    private let trailLevels = 64

    /// Pre-rendered empty lattice (bg gradient + every cell at floor color),
    /// blitted as the first drawing step each frame instead of filling
    /// thousands of floor cells individually. Rebuilt by rebuildGrid().
    private var floorImage: CGImage?

    private var rngState: UInt64 = 0x9E3779B97F4A7C15
    private func nextRand() -> UInt64 {
        rngState ^= rngState << 13
        rngState ^= rngState >> 7
        rngState ^= rngState << 17
        return rngState
    }
    /// Uniform Float in [0, 1).
    private func randF() -> Float {
        Float(nextRand() >> 40) / Float(1 << 24)
    }

    @inline(__always) private func wrap(_ i: Int, _ n: Int) -> Int {
        let m = i % n
        return m < 0 ? m + n : m
    }
    @inline(__always) private func wrapF(_ v: Float, _ n: Float) -> Float {
        let m = v.truncatingRemainder(dividingBy: n)
        return m < 0 ? m + n : m
    }
    /// Shortest signed toroidal delta.
    @inline(__always) private func torDelta(_ d: Float, _ n: Float) -> Float {
        if d > n * 0.5 { return d - n }
        if d < -n * 0.5 { return d + n }
        return d
    }

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
            name: .boidsConfigChanged, object: nil)
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

        let stops = Self.themes[config.theme].stops.map(RGB.init)
        // Configurable empty-cell floor; trails span floor -> 0.88 so the
        // lit end of the ramp is unchanged regardless of the floor setting.
        let f = CGFloat(config.floor)
        floorColor = ramp(f, stops: stops).color
        trailColors = (0..<trailLevels).map { k in
            let t = CGFloat(k) / CGFloat(trailLevels - 1)
            return ramp(f + (0.88 - f) * t, stops: stops).color
        }
        trailCGColors = trailColors.map(\.cgColor)
        headColor = ramp(1.0, stops: stops).color
        // Predator in a contrasting color per theme so it reads instantly:
        // lavanda -> yellow, Doom -> blue, Matrix -> red.
        switch config.theme {
        case 1:  predatorColor = RGB(0x3A8DFF).color   // Doom clássico: azul
        case 2:  predatorColor = RGB(0xFF453A).color   // Matrix: vermelho
        default: predatorColor = RGB(0xFFD60A).color   // Ultracode: amarelo
        }

        // Flock size proportional to the grid: ~1 boid per 26 cells.
        boidCount = min(280, max(16, (cols * rows) / 26))

        trail = .init(repeating: 0, count: cols * rows)
        rebuildFloorImage()
        seedFlock()
        predatorFramesLeft = 0
        framesToNextPredator = Int(config.fps * (12.0 + 6.0 * Double(randF())))
    }

    /// Render the empty lattice (background gradient + all cells at the
    /// floor color) once into a CGImage at Retina scale.
    private func rebuildFloorImage() {
        floorImage = nil
        let scale = window?.backingScaleFactor ?? 2
        let pw = Int((bounds.width * scale).rounded())
        let ph = Int((bounds.height * scale).rounded())
        guard pw > 0, ph > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil, width: pw, height: ph,
                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        ctx.scaleBy(x: scale, y: scale)
        drawBackground(ctx)
        let path = CGMutablePath()
        for j in 0..<rows {
            let cy = originY + CGFloat(j) * pitch
            for i in 0..<cols {
                path.addPath(cellPath(x: originX + CGFloat(i) * pitch, y: cy))
            }
        }
        ctx.setFillColor(floorColor.cgColor)
        ctx.addPath(path)
        ctx.fillPath()
        floorImage = ctx.makeImage()
    }

    /// Rounded-rect path for one standard-size cell centered at (x, y).
    @inline(__always)
    private func cellPath(x: CGFloat, y: CGFloat) -> CGPath {
        let side = cellSide
        return CGPath(
            roundedRect: CGRect(x: x - side / 2, y: y - side / 2,
                                width: side, height: side),
            cornerWidth: side * 0.28, cornerHeight: side * 0.28,
            transform: nil)
    }

    /// Spawn the flock in a few loose clusters with a shared heading per
    /// cluster, so it reads as a flock from the first frames.
    private func seedFlock() {
        boids.removeAll(keepingCapacity: true)
        let fc = Float(cols), fr = Float(rows)
        let clusters = 3
        for c in 0..<clusters {
            let cx = randF() * fc
            let cy = randF() * fr
            let heading = randF() * 2 * Float.pi
            let n = boidCount / clusters + (c < boidCount % clusters ? 1 : 0)
            for _ in 0..<n {
                let a = randF() * 2 * Float.pi
                let r = randF() * 3.5
                let jitter = (randF() - 0.5) * 0.8
                let h = heading + jitter
                let sp = minSpeed + (maxSpeed - minSpeed) * 0.5
                boids.append(Boid(
                    x: wrapF(cx + cos(a) * r, fc),
                    y: wrapF(cy + sin(a) * r, fr),
                    vx: cos(h) * sp,
                    vy: sin(h) * sp))
            }
        }
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

    // MARK: - Simulation step

    private func stepBoids() {
        guard cols > 4, rows > 4, !boids.isEmpty else { return }
        let fc = Float(cols), fr = Float(rows)
        let nbR2 = nbRadius * nbRadius
        let sepR2 = sepRadius * sepRadius
        let n = boids.count

        // Predator scheduling.
        if predatorFramesLeft > 0 {
            predatorFramesLeft -= 1
        } else {
            framesToNextPredator -= 1
            if framesToNextPredator <= 0 {
                triggerPredator()
            }
        }
        let fleeing = predatorFramesLeft > 0

        var newVel = [(Float, Float)](repeating: (0, 0), count: n)
        for i in 0..<n {
            let b = boids[i]
            var sepX: Float = 0, sepY: Float = 0
            var alX: Float = 0, alY: Float = 0
            var cohX: Float = 0, cohY: Float = 0
            var nb = 0
            for j in 0..<n where j != i {
                let dx = torDelta(boids[j].x - b.x, fc)
                let dy = torDelta(boids[j].y - b.y, fr)
                let d2 = dx * dx + dy * dy
                if d2 < nbR2 {
                    nb += 1
                    alX += boids[j].vx
                    alY += boids[j].vy
                    cohX += dx
                    cohY += dy
                    if d2 < sepR2 {
                        let d = max(sqrt(d2), 0.08)
                        let push = (1 - d / sepRadius) / d
                        sepX -= dx * push
                        sepY -= dy * push
                    }
                }
            }
            var ax = sepX * sepWeight
            var ay = sepY * sepWeight
            if nb > 0 {
                let inv = 1 / Float(nb)
                ax += (alX * inv - b.vx) * alignWeight
                ay += (alY * inv - b.vy) * alignWeight
                ax += cohX * inv * cohWeight
                ay += cohY * inv * cohWeight
            }
            ax += (randF() - 0.5) * wander
            ay += (randF() - 0.5) * wander
            if fleeing {
                let dx = torDelta(b.x - predX, fc)
                let dy = torDelta(b.y - predY, fr)
                let d = sqrt(dx * dx + dy * dy)
                if d < fleeRadius {
                    let f = fleeWeight * (1 - d / fleeRadius) / max(d, 0.5)
                    ax += dx * f
                    ay += dy * f
                }
            }
            var vx = b.vx + ax
            var vy = b.vy + ay
            let sp = sqrt(vx * vx + vy * vy)
            if sp < 1e-4 {
                let h = randF() * 2 * Float.pi
                vx = cos(h) * minSpeed
                vy = sin(h) * minSpeed
            } else {
                let clamped = min(max(sp, minSpeed), maxSpeed)
                vx *= clamped / sp
                vy *= clamped / sp
            }
            newVel[i] = (vx, vy)
        }

        // Decay the trail field, then integrate + deposit.
        for k in 0..<trail.count {
            let v = trail[k] * trailDecay
            trail[k] = v < trailFloor ? 0 : v
        }
        for i in 0..<n {
            boids[i].vx = newVel[i].0
            boids[i].vy = newVel[i].1
            boids[i].x = wrapF(boids[i].x + boids[i].vx, fc)
            boids[i].y = wrapF(boids[i].y + boids[i].vy, fr)
            let ci = wrap(Int(boids[i].x), cols)
            let cj = wrap(Int(boids[i].y), rows)
            trail[cj * cols + ci] = 1.0
        }
    }

    private func triggerPredator() {
        guard !boids.isEmpty else { return }
        // Drop the predator on a random boid so it lands inside the flock.
        let pick = Int(nextRand() % UInt64(boids.count))
        predX = boids[pick].x
        predY = boids[pick].y
        predatorFramesLeft = Int(config.fps * 4.0)
        framesToNextPredator = Int(config.fps * (12.0 + 6.0 * Double(randF())))
    }

    /// Test hook: force a predator event now (offline harness only).
    public func debugTriggerPredator() {
        triggerPredator()
    }

    public override func animateOneFrame() {
        if trail.isEmpty { rebuildGrid() }
        stepBoids()
        needsDisplay = true
    }

    // MARK: - Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if trail.isEmpty || floorImage == nil { rebuildGrid() }

        // 1. Blit the pre-rendered empty lattice (bg + all floor cells).
        if let floorImage {
            ctx.draw(floorImage, in: bounds)
        } else {
            drawBackground(ctx)
        }

        // 2. Dynamic trail cells, batched into one fill per quantized color
        //    level (floor cells are skipped: the blit already shows them).
        let maxLevel = Float(trailLevels - 1)
        var levelPaths = [CGMutablePath?](repeating: nil, count: trailLevels)
        for j in 0..<rows {
            let cy = originY + CGFloat(j) * pitch
            let rowBase = j * cols
            for i in 0..<cols {
                let v = trail[rowBase + i]
                if v <= 0 { continue }
                let level = Int(min(v, 1) * maxLevel)
                let path: CGMutablePath
                if let existing = levelPaths[level] {
                    path = existing
                } else {
                    path = CGMutablePath()
                    levelPaths[level] = path
                }
                path.addPath(cellPath(x: originX + CGFloat(i) * pitch, y: cy))
            }
        }
        for level in 0..<trailLevels {
            guard let path = levelPaths[level] else { continue }
            ctx.setFillColor(trailCGColors[level])
            ctx.addPath(path)
            ctx.fillPath()
        }

        // 3. Heads on top: the only bloomed cells (≤ boidCount per frame).
        //    With bloom off they are all the same color -> one batched fill.
        if config.bloom {
            for b in boids {
                let ci = wrap(Int(b.x), cols)
                let cj = wrap(Int(b.y), rows)
                let cx = originX + CGFloat(ci) * pitch
                let cy = originY + CGFloat(cj) * pitch
                drawCell(ctx, x: cx, y: cy, color: headColor, bloom: true)
            }
        } else {
            let headPath = CGMutablePath()
            for b in boids {
                let ci = wrap(Int(b.x), cols)
                let cj = wrap(Int(b.y), rows)
                headPath.addPath(cellPath(
                    x: originX + CGFloat(ci) * pitch,
                    y: originY + CGFloat(cj) * pitch))
            }
            ctx.setFillColor(headColor.cgColor)
            ctx.addPath(headPath)
            ctx.fillPath()
        }

        // Predator point while the scatter is on.
        if predatorFramesLeft > 0 {
            let ci = wrap(Int(predX), cols)
            let cj = wrap(Int(predY), rows)
            let cx = originX + CGFloat(ci) * pitch
            let cy = originY + CGFloat(cj) * pitch
            drawCell(ctx, x: cx, y: cy, color: predatorColor,
                     bloom: config.bloom, scale: 1.45)
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
            ctx.setFillColor(bgTop.color.cgColor)
            ctx.fill(bounds)
        }
    }

    private func drawCell(_ ctx: CGContext, x: CGFloat, y: CGFloat,
                          color: NSColor, bloom: Bool, scale: CGFloat = 1.0) {
        let side = cellSide * scale
        let rect = NSRect(x: x - side / 2, y: y - side / 2,
                          width: side, height: side)
        let path = NSBezierPath(roundedRect: rect,
                                xRadius: side * 0.28, yRadius: side * 0.28)
        if bloom {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: side * 1.2,
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
        panel.title = "Boids"
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

        let bloom = NSButton(checkboxWithTitle: "Brilho (bloom) nos boids",
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
        NotificationCenter.default.post(name: .boidsConfigChanged, object: nil)
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
