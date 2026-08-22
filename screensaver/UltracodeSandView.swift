import AppKit
import ScreenSaver

private extension Notification.Name {
    static let sandConfigChanged = Notification.Name("UltracodeSandConfigChanged")
}

@objc(UltracodeSandView)
public final class UltracodeSandView: ScreenSaverView {

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
        var bloom = true
        var floor: Double = 0.10
    }

    private static let moduleName = "com.williansaez.ultracode-sand"

    private static func makeDefaults() -> ScreenSaverDefaults? {
        let d = ScreenSaverDefaults(forModuleWithName: moduleName)
        d?.register(defaults: [
            "theme": 0,
            "pitch": 26.0,
            "fps": 30.0,
            "bloom": false,
            "floorLevel": 0.08,
        ])
        return d
    }

    private var config = Config()

    private func loadConfig() {
        guard let d = Self.makeDefaults() else { return }
        config.theme = min(max(d.integer(forKey: "theme"), 0), Self.themes.count - 1)
        config.pitch = min(max(d.double(forKey: "pitch"), 8.0), 80.0)
        config.fps = min(max(d.double(forKey: "fps"), 15.0), 60.0)
        config.bloom = d.bool(forKey: "bloom")
        config.floor = min(max(d.double(forKey: "floorLevel"), 0.0), 0.30)
        animationTimeInterval = 1.0 / config.fps
    }

    // MARK: - Grid

    private var cols = 0
    private var rows = 0
    private var pitch: CGFloat = 26
    private var cellSide: CGFloat = 18
    private var originX: CGFloat = 0
    private var originY: CGFloat = 0

    private var levelColors: [NSColor] = []
    private var levelCGColors: [CGColor] = []
    private let colorLevels = 32

    /// Quantized level the empty "floor" cells land on; cells at this level
    /// are covered by the pre-rendered floor blit and never drawn per-cell.
    private var floorLevelIndex = 0

    /// Entire empty lattice (bg gradient + one rounded rect per cell at the
    /// floor color) pre-rendered at Retina scale. Blitted once per frame so
    /// only non-floor cells need real path fills.
    private var floorImage: CGImage?

    // MARK: - Sand state

    // Falling-sand cellular automaton. cells[idx] == 0 means empty; otherwise
    // it holds the grain's brightness level (0.45...0.95) fixed at spawn. The
    // spawn level drifts through that range over ~30 s so the pile builds
    // visible strata. Emitters near the top drift slowly left/right. When the
    // screen actually fills (a settled grain reaches one of the top 2 rows,
    // or grains cover ~90% of the grid) a drain opens at the bottom and
    // grains pour out until the grid is nearly empty, then it closes.

    private var cells: [Float] = []
    private var falling: [Bool] = []
    private var emitterX: [Double] = []
    private var emitterV: [Double] = []
    private var totalGrains = 0
    private var draining = false
    private var levelPhase: Double = 0
    private var frameCount = 0

    private var rngState: UInt64 = 0x243F6A8885A308D3
    private func nextRand() -> UInt64 {
        rngState ^= rngState << 13
        rngState ^= rngState >> 7
        rngState ^= rngState << 17
        return rngState
    }
    private func randInt(_ n: Int) -> Int { Int(nextRand() % UInt64(max(1, n))) }
    private func randUnit() -> Double { Double(nextRand() >> 11) * (1.0 / 9007199254740992.0) }

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
            name: .sandConfigChanged, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func configChanged() {
        loadConfig()
        rebuildGrid()
        needsDisplay = true
    }

    // MARK: - Layout

    private func rebuildGrid() {
        pitch = isPreview ? 9 : CGFloat(config.pitch)
        cellSide = pitch * 0.70
        cols = max(8, Int(bounds.width / pitch) + 1)
        rows = max(8, Int(bounds.height / pitch) + 1)
        originX = (bounds.width - CGFloat(cols - 1) * pitch) / 2
        originY = (bounds.height - CGFloat(rows - 1) * pitch) / 2

        let stops = Self.themes[config.theme].stops.map(RGB.init)
        let f = CGFloat(config.floor)
        levelColors = (0..<colorLevels).map { l in
            let b = f + (1 - f) * CGFloat(l) / CGFloat(colorLevels - 1)
            return ramp(b, stops: stops).color
        }
        levelCGColors = levelColors.map(\.cgColor)
        floorLevelIndex = min(colorLevels - 1,
                              max(0, Int(f * CGFloat(colorLevels - 1))))
        rebuildFloorImage()

        cells = .init(repeating: 0, count: cols * rows)
        falling = .init(repeating: false, count: cols * rows)
        totalGrains = 0
        draining = false
        levelPhase = 0
        frameCount = 0

        // 2-3 emitters spread across the top, each with a slow drift.
        let n = cols >= 40 ? 3 : 2
        emitterX = []
        emitterV = []
        for k in 0..<n {
            let span = Double(cols) / Double(n)
            emitterX.append(span * (Double(k) + 0.5) + (randUnit() - 0.5) * span * 0.3)
            emitterV.append((randUnit() < 0.5 ? -1.0 : 1.0) * (0.02 + 0.03 * randUnit()))
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

    // MARK: - Simulation

    private func idx(_ i: Int, _ j: Int) -> Int { j * cols + i }

    public override func animateOneFrame() {
        if cells.isEmpty || levelColors.isEmpty { rebuildGrid() }
        frameCount += 1
        stepSand()
        needsDisplay = true
    }

    private func stepSand() {
        var nowFalling = [Bool](repeating: false, count: cols * rows)

        // Grain physics, bottom-up (row 0 is the bottom in view coords).
        // Alternate the horizontal scan direction to avoid sideways bias.
        for j in 1..<rows {
            let leftToRight = (frameCount + j) % 2 == 0
            for s in 0..<cols {
                let i = leftToRight ? s : cols - 1 - s
                let cur = idx(i, j)
                let lvl = cells[cur]
                if lvl <= 0 { continue }
                let below = idx(i, j - 1)
                if cells[below] <= 0 {
                    cells[below] = lvl
                    cells[cur] = 0
                    nowFalling[below] = true
                    continue
                }
                // Below is solid: try below-left / below-right, random first.
                let d0 = (nextRand() & 1) == 0 ? -1 : 1
                var moved = false
                for d in [d0, -d0] {
                    let ni = i + d
                    if ni < 0 || ni >= cols { continue }
                    if cells[idx(ni, j)] <= 0 && cells[idx(ni, j - 1)] <= 0 {
                        cells[idx(ni, j - 1)] = lvl
                        cells[cur] = 0
                        nowFalling[idx(ni, j - 1)] = true
                        moved = true
                        break
                    }
                }
                if !moved { /* rest */ }
            }
        }

        // Emitters drift slowly and bounce off the side margins.
        for k in 0..<emitterX.count {
            emitterX[k] += emitterV[k]
            if emitterX[k] < 2 { emitterX[k] = 2; emitterV[k] = abs(emitterV[k]) }
            if emitterX[k] > Double(cols - 3) {
                emitterX[k] = Double(cols - 3)
                emitterV[k] = -abs(emitterV[k])
            }
            // Occasionally nudge the drift speed a little.
            if randInt(300) == 0 {
                emitterV[k] = (emitterV[k] < 0 ? -1.0 : 1.0) * (0.02 + 0.03 * randUnit())
            }
        }

        // Spawn level cycles through 0.45...0.95 over ~30 s (triangle wave),
        // so successive deposits build visible strata bands in the pile.
        levelPhase += 2.0 / (30.0 * config.fps)
        let t = levelPhase.truncatingRemainder(dividingBy: 2.0)
        let tri = t < 1.0 ? t : 2.0 - t
        let spawnLevel = Float(0.45 + 0.5 * tri)

        // Each emitter drops grains at a steady (probabilistic) rate.
        let top = rows - 1
        for k in 0..<emitterX.count {
            if randUnit() > 0.40 { continue }
            let i = min(cols - 1, max(0, Int(emitterX[k].rounded())))
            let cell = idx(i, top)
            if cells[cell] <= 0 {
                let jitter = Float(randUnit() - 0.5) * 0.03
                cells[cell] = min(0.95, max(0.45, spawnLevel + jitter))
                nowFalling[cell] = true
                totalGrains += 1
            }
        }

        falling = nowFalling

        // Drain control: open only when the screen actually FILLS — a settled
        // grain occupies one of the top 2 rows, or the settled grains cover
        // ~90% of the grid. Close once almost everything has poured out.
        if !draining {
            var full = totalGrains >= Int(Double(cols * rows) * 0.90)
            if !full {
                let top2Start = idx(0, max(0, rows - 2))
                for c in top2Start..<(cols * rows) where cells[c] > 0 && !falling[c] {
                    full = true
                    break
                }
            }
            if full { draining = true }
        } else {
            // Remove a few grains per frame from the bottom row at random x.
            var removed = 0
            var attempts = 0
            while removed < 8 && attempts < 24 {
                let i = randInt(cols)
                if cells[idx(i, 0)] > 0 {
                    cells[idx(i, 0)] = 0
                    totalGrains -= 1
                    removed += 1
                }
                attempts += 1
            }
            if totalGrains < Int(Double(cols * rows) * 0.15) { draining = false }
        }
    }

    // MARK: - Debug hooks (offline harness only)

    @objc public var debugGrainCount: Int { totalGrains }
    @objc public var debugIsDraining: Bool { draining }
    @objc public var debugRows: Int { rows }
    @objc public var debugMaxSettledHeight: Int {
        var maxHeight = 0
        for i in 0..<cols {
            var j = rows - 1
            while j >= 0 {
                if cells[idx(i, j)] > 0 && !falling[idx(i, j)] {
                    maxHeight = max(maxHeight, j + 1)
                    break
                }
                j -= 1
            }
            if maxHeight >= rows { break }
        }
        return maxHeight
    }

    // MARK: - Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if cells.isEmpty || levelColors.isEmpty || floorImage == nil { rebuildGrid() }
        guard let floor = floorImage else { return }

        // One blit covers the bg gradient and every cell at the floor level.
        ctx.draw(floor, in: bounds)

        // Dynamic cells: batch all rounded rects of the same quantized color
        // into one path so each level costs a single fill. Bloomed cells are
        // collected and drawn individually ON TOP (they need the shadow).
        let bloomRow = rows - 3
        let radius = cellSide * 0.28
        var batches = [CGMutablePath?](repeating: nil, count: colorLevels)
        var bloomCells: [(x: CGFloat, y: CGFloat, level: Int)] = []

        for j in 0..<rows {
            let cy = originY + CGFloat(j) * pitch
            let rowBase = j * cols
            for i in 0..<cols {
                let cell = rowBase + i
                let lvl = cells[cell]
                if lvl <= 0 { continue }
                var b = CGFloat(lvl)
                var bloom = false
                if falling[cell] {
                    b = min(1.0, b + 0.10)
                    bloom = config.bloom && j >= bloomRow
                }
                let l = min(colorLevels - 1, max(0, Int(b * CGFloat(colorLevels - 1))))
                let cx = originX + CGFloat(i) * pitch
                if bloom {
                    bloomCells.append((cx, cy, l))
                    continue
                }
                if l == floorLevelIndex { continue }  // already in the blit
                let rect = CGRect(x: cx - cellSide / 2, y: cy - cellSide / 2,
                                  width: cellSide, height: cellSide)
                let path: CGMutablePath
                if let existing = batches[l] {
                    path = existing
                } else {
                    path = CGMutablePath()
                    batches[l] = path
                }
                path.addPath(CGPath(roundedRect: rect, cornerWidth: radius,
                                    cornerHeight: radius, transform: nil))
            }
        }

        for l in 0..<colorLevels {
            guard let path = batches[l] else { continue }
            ctx.setFillColor(levelCGColors[l])
            ctx.addPath(path)
            ctx.fillPath()
        }

        for c in bloomCells {
            drawCell(ctx, x: c.x, y: c.y, color: levelColors[c.level], bloom: true)
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

    /// Render the whole empty lattice (gradient + floor cells) once into a
    /// Retina-scale CGImage. Rebuilt by rebuildGrid() on resize/config change
    /// so the "Brilho do fundo" slider keeps working.
    private func rebuildFloorImage() {
        floorImage = nil
        guard bounds.width >= 1, bounds.height >= 1,
              levelColors.indices.contains(floorLevelIndex) else { return }
        let scale = window?.backingScaleFactor ?? 2
        let pw = max(1, Int((bounds.width * scale).rounded()))
        let ph = max(1, Int((bounds.height * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pw, height: ph,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        ctx.scaleBy(x: scale, y: scale)

        drawBackground(ctx)

        let radius = cellSide * 0.28
        let path = CGMutablePath()
        for j in 0..<rows {
            let cy = originY + CGFloat(j) * pitch
            for i in 0..<cols {
                let cx = originX + CGFloat(i) * pitch
                let rect = CGRect(x: cx - cellSide / 2, y: cy - cellSide / 2,
                                  width: cellSide, height: cellSide)
                path.addPath(CGPath(roundedRect: rect, cornerWidth: radius,
                                    cornerHeight: radius, transform: nil))
            }
        }
        ctx.setFillColor(levelCGColors[floorLevelIndex])
        ctx.addPath(path)
        ctx.fillPath()

        floorImage = ctx.makeImage()
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

    /// Pitches in [8, 80] where the grid shows NO cut cells on the main
    /// screen. Grid math is untouched (cols = Int(w/p)+1, centered, cell side
    /// 0.7p): edge cells stay fully inside whenever the fractional parts of
    /// w/p and h/p are >= 0.7. Scan that condition and take the center of
    /// each valid band as a slider detent.
    private static func pitchDetents() -> [Double] {
        let size = NSScreen.main?.frame.size ?? NSSize(width: 1512, height: 982)
        let w = Double(size.width), h = Double(size.height)
        var runs: [[Double]] = []
        var cur: [Double] = []
        var p = 8.0
        while p <= 80.0 {
            let fw = w / p - (w / p).rounded(.down)
            let fh = h / p - (h / p).rounded(.down)
            if fw >= 0.7 && fh >= 0.7 {
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

        let W: CGFloat = 440, H: CGFloat = 250
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                            styleMask: [.titled],
                            backing: .buffered, defer: false)
        panel.title = "Areia"
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

        let bloom = NSButton(checkboxWithTitle: "Brilho (bloom) nos grãos a cair",
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
        NotificationCenter.default.post(name: .sandConfigChanged, object: nil)
        closeSheet()
    }

    @objc private func sheetCancel(_ sender: Any?) { closeSheet() }

    private func closeSheet() {
        guard let sheet else { return }
        if let parent = sheet.sheetParent {
            parent.endSheet(sheet)
        } else {
            sheet.close()
        }
    }
}
