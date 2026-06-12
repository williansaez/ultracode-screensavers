import AppKit
import ScreenSaver

private extension Notification.Name {
    static let grayScottConfigChanged = Notification.Name("UltracodeGrayScottConfigChanged")
}

@objc(UltracodeGrayScottView)
public final class UltracodeGrayScottView: ScreenSaverView {

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

    private static let moduleName = "com.williansaez.ultracode-grayscott"

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

    /// Quantized level the empty floor maps to; cells at this level are
    /// covered by the pre-rendered floor blit and skipped during draw.
    private var floorLevelIndex = 0

    /// Pre-rendered empty lattice (background gradient + every cell at the
    /// floor color), built once per rebuildGrid() and blitted each frame.
    private var floorImage: CGImage?

    /// One pre-rendered rounded-rect cell per quantized color level, built at
    /// the window's backing scale. Dynamic cells are drawn by blitting these
    /// (grouped per level) instead of filling one vector path per cell:
    /// CoreGraphics blits small images far faster than it rasterizes
    /// thousands of rounded-rect paths.
    private var levelSprites: [CGImage] = []
    /// Side of a sprite's destination rect in points (cellSide + AA margin,
    /// rounded up to an integral pixel count at the backing scale).
    private var spriteSide: CGFloat = 0
    /// Backing scale the sprites were rendered at; destination rects are
    /// snapped to this pixel grid so blits stay 1:1 (no resampling).
    private var spriteScale: CGFloat = 2

    // MARK: - Gray-Scott reaction-diffusion

    // Two chemicals diffuse over a fine toroidal grid: U (the feedstock,
    // initially everywhere) and V (the catalyst, seeded in a few spots).
    // V consumes U to make more V (u*v^2), U is replenished at rate F and V
    // is removed at rate F+k. At F=0.037, k=0.06 the seeds grow into coral:
    // fronts advance, split and fold into labyrinthine stripes that keep
    // morphing. Fresh seeds dropped into quiet areas every ~20 s ensure the
    // pattern never fully settles.

    private let simScale = 2
    private var fw = 0
    private var fh = 0
    private var fieldU: [Float] = []
    private var fieldV: [Float] = []
    private var nextU: [Float] = []
    private var nextV: [Float] = []

    private let paramF: Float = 0.037
    private let paramK: Float = 0.06
    private let diffU: Float = 0.16
    private let diffV: Float = 0.08
    private let stepsPerFrame = 8

    private var frameCount = 0
    private var reseedEvery = 600     // frames between new seed drops (~20 s)
    // Fixed bloom threshold just above the steady-state 99th percentile of
    // cell V (p95≈0.32, p99≈0.33, max≈0.36 at F=0.037/k=0.06): only the
    // hottest reaction peaks and fresh seed flashes bloom — naturally sparse.
    private let bloomThreshold: Float = 0.335

    private var rngState: UInt64 = 0x243F6A8885A308D3
    private func nextRand() -> UInt64 {
        rngState ^= rngState << 13
        rngState ^= rngState >> 7
        rngState ^= rngState << 17
        return rngState
    }

    private func wrap(_ a: Int, _ n: Int) -> Int {
        let m = a % n
        return m < 0 ? m + n : m
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
            name: .grayScottConfigChanged, object: nil)
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

        reseedEvery = max(60, Int(20.0 * config.fps))

        let stops = Self.themes[config.theme].stops.map(RGB.init)
        let f = CGFloat(config.floor)
        levelColors = (0..<colorLevels).map { l in
            let b = f + (1 - f) * CGFloat(l) / CGFloat(colorLevels - 1)
            return ramp(b, stops: stops).color
        }
        levelCGColors = levelColors.map(\.cgColor)
        // Same quantization as draw(_:) applied to brightness b == f.
        floorLevelIndex = min(colorLevels - 1, Int(f * CGFloat(colorLevels - 1)))
        rebuildLevelSprites()
        rebuildFloorImage()

        reseed()
    }

    /// Pre-render one cell (rounded rect, same geometry as drawCell) per
    /// quantized color level at the backing scale.
    private func rebuildLevelSprites() {
        levelSprites = []
        spriteSide = 0
        guard !levelCGColors.isEmpty, cellSide > 0 else { return }
        let scale = window?.backingScaleFactor ?? 2
        spriteScale = scale
        // 1 pt of margin on each side so antialiased edges are not clipped;
        // integral pixel count so blits at the backing scale stay 1:1.
        let px = Int(((cellSide + 2) * scale).rounded(.up))
        spriteSide = CGFloat(px) / scale
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return }
        let cellRect = CGRect(x: -cellSide / 2, y: -cellSide / 2,
                              width: cellSide, height: cellSide)
        let template = CGPath(roundedRect: cellRect,
                              cornerWidth: cellSide * 0.28,
                              cornerHeight: cellSide * 0.28, transform: nil)
        var sprites: [CGImage] = []
        sprites.reserveCapacity(colorLevels)
        for level in 0..<colorLevels {
            guard let c = CGContext(data: nil, width: px, height: px,
                                    bitsPerComponent: 8, bytesPerRow: 0,
                                    space: space,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }
            c.scaleBy(x: scale, y: scale)
            c.translateBy(x: spriteSide / 2, y: spriteSide / 2)
            c.setFillColor(levelCGColors[level])
            c.addPath(template)
            c.fillPath()
            guard let img = c.makeImage() else { return }
            sprites.append(img)
        }
        levelSprites = sprites
    }

    /// Render the entire empty lattice (background gradient + floor cells)
    /// once into a Retina-scale CGImage; draw(_:) blits it every frame
    /// instead of filling thousands of floor cells individually.
    private func rebuildFloorImage() {
        floorImage = nil
        guard cols > 0, rows > 0, levelSprites.count == colorLevels else { return }
        let scale = window?.backingScaleFactor ?? 2
        let pw = Int((bounds.width * scale).rounded())
        let ph = Int((bounds.height * scale).rounded())
        guard pw > 0, ph > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pw, height: ph,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        ctx.scaleBy(x: scale, y: scale)
        drawBackground(ctx)
        let sprite = levelSprites[floorLevelIndex]
        let half = spriteSide / 2
        let s = spriteScale
        for j in 0..<rows {
            let cy = originY + CGFloat(j) * pitch
            for i in 0..<cols {
                let cx = originX + CGFloat(i) * pitch
                let x = ((cx - half) * s).rounded() / s
                let y = ((cy - half) * s).rounded() / s
                ctx.draw(sprite, in: CGRect(x: x, y: y,
                                            width: spriteSide, height: spriteSide))
            }
        }
        floorImage = ctx.makeImage()
    }

    private func reseed() {
        let n = fw * fh
        fieldU = .init(repeating: 1.0, count: n)
        fieldV = .init(repeating: 0.0, count: n)
        nextU = fieldU
        nextV = fieldV
        // ~12 small squares of catalyst scattered over the torus.
        for _ in 0..<12 {
            stampSeed(Int(nextRand() % UInt64(fw)), Int(nextRand() % UInt64(fh)))
        }
        frameCount = 0
    }

    /// Drop a small square of V=1 centered near (cx, cy), toroidally.
    private func stampSeed(_ cx: Int, _ cy: Int) {
        for dy in -2...1 {
            let row = wrap(cy + dy, fh) * fw
            for dx in -2...1 {
                fieldV[row + wrap(cx + dx, fw)] = 1.0
            }
        }
    }

    /// Every ~20 s: drop 1-2 fresh seeds into quiet (low-V) areas so the
    /// pattern keeps morphing forever instead of stabilizing.
    private func seedQuietAreas() {
        let spots = 1 + Int(nextRand() % 2)
        for _ in 0..<spots {
            for _ in 0..<12 {     // attempts to find a quiet location
                let cx = Int(nextRand() % UInt64(fw))
                let cy = Int(nextRand() % UInt64(fh))
                if fieldV[cy * fw + cx] < 0.05 {
                    stampSeed(cx, cy)
                    break
                }
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

    private func stepSim() {
        let F = paramF, K = paramK, Du = diffU, Dv = diffV
        let fw = self.fw, fh = self.fh
        // Unsafe buffers drop bounds/COW checks in the hot loop; the
        // arithmetic and traversal are identical to the straightforward form.
        fieldU.withUnsafeBufferPointer { u in
            fieldV.withUnsafeBufferPointer { v in
                nextU.withUnsafeMutableBufferPointer { nu in
                    nextV.withUnsafeMutableBufferPointer { nv in
                        for j in 0..<fh {
                            let jm = (j == 0 ? fh - 1 : j - 1) * fw
                            let j0 = j * fw
                            let jp = (j == fh - 1 ? 0 : j + 1) * fw
                            for i in 0..<fw {
                                let im = i == 0 ? fw - 1 : i - 1
                                let ip = i == fw - 1 ? 0 : i + 1
                                let idx = j0 + i
                                let uc = u[idx]
                                let vc = v[idx]
                                let lapU = u[jm + i] + u[jp + i]
                                         + u[j0 + im] + u[j0 + ip] - 4 * uc
                                let lapV = v[jm + i] + v[jp + i]
                                         + v[j0 + im] + v[j0 + ip] - 4 * vc
                                let uvv = uc * vc * vc
                                // dt = 1
                                let nuv = uc + (Du * lapU - uvv + F * (1 - uc))
                                let nvv = vc + (Dv * lapV + uvv - (F + K) * vc)
                                nu[idx] = min(1, max(0, nuv))
                                nv[idx] = min(1, max(0, nvv))
                            }
                        }
                    }
                }
            }
        }
        swap(&fieldU, &nextU)
        swap(&fieldV, &nextV)
    }

    public override func animateOneFrame() {
        if fieldV.isEmpty { rebuildGrid() }
        for _ in 0..<stepsPerFrame { stepSim() }
        frameCount += 1
        if frameCount % reseedEvery == 0 { seedQuietAreas() }
        // Extinction guard: if the catalyst dies out entirely, start over.
        if frameCount % 30 == 0 {
            var maxV: Float = 0
            for x in fieldV where x > maxV { maxV = x }
            if maxV < 0.03 { reseed() }
        }
        needsDisplay = true
    }

    /// Harness-only diagnostics; no effect in the installed saver.
    @objc public func debugDump() {
        var maxV: Float = 0
        var sum: Float = 0
        var active = 0
        for x in fieldV {
            if x > maxV { maxV = x }
            sum += x
            if x > 0.1 { active += 1 }
        }
        var bloomCells = 0
        var cellVals: [Float] = []
        cellVals.reserveCapacity(cols * rows)
        let block = Float(simScale * simScale)
        for j in 0..<rows {
            let by = j * simScale
            for i in 0..<cols {
                let bx = i * simScale
                var s: Float = 0
                for sy in 0..<simScale {
                    let base = (by + sy) * fw + bx
                    for sx in 0..<simScale { s += fieldV[base + sx] }
                }
                let a = s / block
                cellVals.append(a)
                if a > bloomThreshold { bloomCells += 1 }
            }
        }
        cellVals.sort()
        func q(_ p: Double) -> Float {
            cellVals[min(cellVals.count - 1, Int(Double(cellVals.count) * p))]
        }
        let pct = Double(active) / Double(max(1, fieldV.count)) * 100
        print(String(format: "frame=%d grid=%dx%d sim=%dx%d maxV=%.3f meanV=%.4f v>0.1=%.1f%% bloomCells=%d p90=%.3f p95=%.3f p99=%.3f cellMax=%.3f",
                     frameCount, cols, rows, fw, fh, maxV,
                     sum / Float(max(1, fieldV.count)), pct, bloomCells,
                     q(0.90), q(0.95), q(0.99), cellVals.last ?? 0))
    }

    // MARK: - Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if fieldV.isEmpty { rebuildGrid() }
        if floorImage == nil { rebuildFloorImage() }

        // 1) Blit the pre-rendered empty lattice (gradient + floor cells).
        if let floorImage {
            ctx.draw(floorImage, in: bounds)
        } else {
            drawBackground(ctx)
        }
        guard levelSprites.count == colorLevels else { return }

        let block = Float(simScale * simScale)
        let f = CGFloat(config.floor)

        // 2) Group non-floor cells by quantized color level and draw each
        //    group by blitting that level's pre-rendered cell sprite — far
        //    cheaper than rasterizing one rounded-rect path per cell. Cells
        //    at the floor level are skipped (the blit already shows them).
        //    Bloomed cells are collected and drawn individually on top (they
        //    are few and need the shadow).
        var levelCells = [[CGPoint]](repeating: [], count: colorLevels)
        var bloomCells: [(x: CGFloat, y: CGFloat, level: Int)] = []

        for j in 0..<rows {
            let cy = originY + CGFloat(j) * pitch
            let by = j * simScale
            for i in 0..<cols {
                let bx = i * simScale
                var s: Float = 0
                for sy in 0..<simScale {
                    let base = (by + sy) * fw + bx
                    for sx in 0..<simScale { s += fieldV[base + sx] }
                }
                let vAvg = s / block
                // Brightness = V concentration; stripes saturate near v≈0.33.
                let b = max(f, min(1.0, CGFloat(vAvg) * 3.0))
                let level = min(colorLevels - 1, Int(b * CGFloat(colorLevels - 1)))
                let cx = originX + CGFloat(i) * pitch
                if config.bloom && vAvg > bloomThreshold {
                    bloomCells.append((cx, cy, level))
                    continue
                }
                if level == floorLevelIndex { continue }  // floor blit shows it
                levelCells[level].append(CGPoint(x: cx, y: cy))
            }
        }

        let half = spriteSide / 2
        let s = spriteScale
        for level in 0..<colorLevels {
            let cells = levelCells[level]
            if cells.isEmpty { continue }
            let sprite = levelSprites[level]
            for p in cells {
                let x = ((p.x - half) * s).rounded() / s
                let y = ((p.y - half) * s).rounded() / s
                ctx.draw(sprite, in: CGRect(x: x, y: y,
                                            width: spriteSide, height: spriteSide))
            }
        }

        // 3) Bloomed peaks on top, exactly as before.
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
        panel.title = "Reação-Difusão"
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

        let bloom = NSButton(checkboxWithTitle: "Brilho (bloom) nos picos de reação",
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
        NotificationCenter.default.post(name: .grayScottConfigChanged, object: nil)
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
