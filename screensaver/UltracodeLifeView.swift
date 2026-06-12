import AppKit
import ScreenSaver

private extension Notification.Name {
    static let lifeConfigChanged = Notification.Name("UltracodeLifeConfigChanged")
}

@objc(UltracodeLifeView)
public final class UltracodeLifeView: ScreenSaverView {

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
        var fps: Double = 10      // generations per second
        var bloom = true
        var floor: Double = 0.10  // brightness of empty grid cells
    }

    private static let moduleName = "com.williansaez.ultracode-life"

    private static func makeDefaults() -> ScreenSaverDefaults? {
        let d = ScreenSaverDefaults(forModuleWithName: moduleName)
        d?.register(defaults: [
            "theme": 0,
            "pitch": 26.0,
            "fps": 10.0,
            "bloom": true,
            "floorLevel": 0.10,
        ])
        return d
    }

    private var config = Config()

    private func loadConfig() {
        guard let d = Self.makeDefaults() else { return }
        config.theme = min(max(d.integer(forKey: "theme"), 0), Self.themes.count - 1)
        config.pitch = min(max(d.double(forKey: "pitch"), 8.0), 80.0)
        config.fps = min(max(d.double(forKey: "fps"), 2.0), 30.0)
        config.bloom = d.bool(forKey: "bloom")
        config.floor = min(max(d.double(forKey: "floorLevel"), 0.0), 0.30)
        animationTimeInterval = 1.0 / config.fps
    }

    // MARK: - Grid + life state

    private var cols = 0
    private var rows = 0
    private var pitch: CGFloat = 26
    private var cellSide: CGFloat = 18
    private var originX: CGFloat = 0
    private var originY: CGFloat = 0

    /// Per-cell state: 0 = long dead, >0 = alive for N generations,
    /// <0 = died |N| generations ago (fading trail).
    private var state: [Int] = []
    private var next: [Int] = []
    private let trailLength = 6

    /// Precomputed colors. aliveColors indexed by capped age,
    /// trailColors indexed by generations-since-death.
    private var aliveColors: [NSColor] = []
    private var trailColors: [NSColor] = []
    private var floorColor: NSColor = .black
    private let aliveAgeCap = 12

    // Stagnation detection: hash recent boards; reseed when the world
    // settles into still lifes / short oscillators.
    private var recentHashes: [UInt64] = []
    private var stagnantSteps = 0

    private var rngState: UInt64 = 0x243F6A8885A308D3
    private func nextRand() -> UInt64 {
        rngState ^= rngState << 13
        rngState ^= rngState >> 7
        rngState ^= rngState << 17
        return rngState
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
            name: .lifeConfigChanged, object: nil)
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
        let f = CGFloat(config.floor)
        // The ramp's darkest stop is brighter than the background, so below
        // the legacy 0.10 floor ease the empty-cell color into the bg: at
        // f = 0 the grid vanishes; at f >= 0.10 it sits on the ramp exactly
        // as before.
        if f < 0.10 {
            let bgMid = RGB.lerp(bgTop, bgBottom, 0.5)
            floorColor = RGB.lerp(bgMid, ramp(f, stops: stops), f / 0.10).color
        } else {
            floorColor = ramp(f, stops: stops).color
        }
        // Newborn = hottest, settles toward mid as it ages.
        aliveColors = (0...aliveAgeCap).map { age in
            let t = CGFloat(min(age, aliveAgeCap)) / CGFloat(aliveAgeCap)
            let b = 1.0 - 0.42 * t           // 1.0 -> 0.58
            return ramp(b, stops: stops).color
        }
        // Death trail fades from just-below-alive down to the grid floor.
        trailColors = (1...trailLength).map { k in
            let t = CGFloat(k) / CGFloat(trailLength + 1)
            let b = f + (0.55 - f) * (1 - t)
            return ramp(b, stops: stops).color
        }

        reseed()
    }

    private func reseed() {
        state = .init(repeating: 0, count: cols * rows)
        next = state
        // ~22% alive, in loose clumps: seed random points then thicken
        // around them so the start looks organic instead of static noise.
        let n = cols * rows
        var i = 0
        while i < n {
            if nextRand() % 100 < 22 { state[i] = 1 }
            i += 1
        }
        recentHashes.removeAll()
        stagnantSteps = 0
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

    // MARK: - Conway step

    private func stepLife() {
        guard cols > 2, rows > 2 else { return }
        var population = 0
        var hash: UInt64 = 14695981039346656037   // FNV-1a offset basis

        for j in 0..<rows {
            let jm = (j == 0 ? rows - 1 : j - 1) * cols
            let j0 = j * cols
            let jp = (j == rows - 1 ? 0 : j + 1) * cols
            for i in 0..<cols {
                let im = i == 0 ? cols - 1 : i - 1
                let ip = i == cols - 1 ? 0 : i + 1
                var neigh = 0
                if state[jm + im] > 0 { neigh += 1 }
                if state[jm + i]  > 0 { neigh += 1 }
                if state[jm + ip] > 0 { neigh += 1 }
                if state[j0 + im] > 0 { neigh += 1 }
                if state[j0 + ip] > 0 { neigh += 1 }
                if state[jp + im] > 0 { neigh += 1 }
                if state[jp + i]  > 0 { neigh += 1 }
                if state[jp + ip] > 0 { neigh += 1 }

                let idx = j0 + i
                let s = state[idx]
                let alive = s > 0
                if alive ? (neigh == 2 || neigh == 3) : (neigh == 3) {
                    next[idx] = alive ? min(s + 1, aliveAgeCap) : 1
                    population += 1
                    hash = (hash ^ UInt64(idx)) &* 1099511628211
                } else if alive {
                    next[idx] = -1                       // just died
                } else if s < 0 {
                    next[idx] = s > -trailLength ? s - 1 : 0
                } else {
                    next[idx] = 0
                }
            }
        }
        swap(&state, &next)

        // Reseed on extinction or stagnation (still lifes + period-2
        // oscillators repeat a recent board hash).
        if population == 0 {
            reseed()
            return
        }
        if recentHashes.contains(hash) {
            stagnantSteps += 1
        } else {
            stagnantSteps = 0
        }
        recentHashes.append(hash)
        if recentHashes.count > 6 { recentHashes.removeFirst() }
        if stagnantSteps > 60 { reseed() }   // ~6 s at 10 gen/s
    }

    public override func animateOneFrame() {
        if state.isEmpty { rebuildGrid() }
        stepLife()
        needsDisplay = true
    }

    // MARK: - Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if state.isEmpty { rebuildGrid() }

        drawBackground(ctx)

        for j in 0..<rows {
            let cy = originY + CGFloat(j) * pitch
            let rowBase = j * cols
            for i in 0..<cols {
                let s = state[rowBase + i]
                let cx = originX + CGFloat(i) * pitch
                if s > 0 {
                    // Newborns get the bloom; settled cells stay flat.
                    drawCell(ctx, x: cx, y: cy,
                             color: aliveColors[min(s, aliveAgeCap)],
                             bloom: config.bloom && s <= 2)
                } else if s < 0 {
                    drawCell(ctx, x: cx, y: cy,
                             color: trailColors[min(-s, trailLength) - 1],
                             bloom: false)
                } else {
                    drawCell(ctx, x: cx, y: cy, color: floorColor, bloom: false)
                }
            }
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
        panel.title = "Jogo da Vida"
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
        _ = label("Velocidade (ger./s):", row: 126)
        let fSlider = slider(config.fps, 2, 30, row: 126)
        _ = label("Brilho do fundo:", row: 88)
        let flSlider = slider(config.floor, 0.0, 0.30, row: 88)

        let bloom = NSButton(checkboxWithTitle: "Brilho (bloom) nas células novas",
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
            d.set(fpsSlider?.doubleValue ?? 10.0, forKey: "fps")
            d.set(floorSlider?.doubleValue ?? 0.10, forKey: "floorLevel")
            d.set(bloomCheck?.state == .on, forKey: "bloom")
            d.synchronize()
        }
        NotificationCenter.default.post(name: .lifeConfigChanged, object: nil)
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
