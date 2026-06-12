import AppKit
import ScreenSaver

private extension Notification.Name {
    static let ultracodeConfigChanged = Notification.Name("UltracodeConfigChanged")
}

@objc(UltracodeView)
public final class UltracodeView: ScreenSaverView {

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

    // MARK: - Themes

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

    // MARK: - User configuration (ScreenSaverDefaults)

    private struct Config {
        var theme = 0             // index into themes
        var flameHeight: Double = 0.60   // fraction of screen the flames reach
        var intensity: Double = 1.0      // brightness scale, shape unchanged
        var floor: Double = 0.10         // empty-cell brightness on the ramp
        var pitch: Double = 26    // points between cell centers
        var fps: Double = 30
        var bloom = true
    }

    private static let moduleName = "com.williansaez.ultracode-screensaver"

    private static func makeDefaults() -> ScreenSaverDefaults? {
        let d = ScreenSaverDefaults(forModuleWithName: moduleName)
        d?.register(defaults: [
            "theme": 0,
            "flameHeight": 0.60,
            "intensity": 1.0,
            "floorLevel": 0.10,
            "pitch": 26.0,
            "fps": 30.0,
            "bloom": true,
        ])
        return d
    }

    private var config = Config()

    private func loadConfig() {
        guard let d = Self.makeDefaults() else { return }
        config.theme = min(max(d.integer(forKey: "theme"), 0), Self.themes.count - 1)
        config.flameHeight = min(max(d.double(forKey: "flameHeight"), 0.20), 1.0)
        config.intensity = min(max(d.double(forKey: "intensity"), 0.20), 1.0)
        config.floor = min(max(d.double(forKey: "floorLevel"), 0.0), 0.30)
        config.pitch = min(max(d.double(forKey: "pitch"), 8.0), 80.0)
        config.fps = min(max(d.double(forKey: "fps"), 15.0), 60.0)
        config.bloom = d.bool(forKey: "bloom")
        animationTimeInterval = 1.0 / config.fps
    }

    // Heat level -> NSColor, precomputed per grid rebuild (avoids
    // thousands of NSColor allocations per frame).
    private var levelColors: [NSColor] = []

    // MARK: - Grid + fire state

    private var cols = 0
    private var rows = 0
    private var pitch: CGFloat = 26
    private var cellSide: CGFloat = 18
    private var originX: CGFloat = 0
    private var originY: CGFloat = 0

    /// Doom fire heat buffer, row-major, row 0 = bottom (the source).
    private var heat: [Int] = []
    /// Number of discrete heat levels; sized from row count and the
    /// configured flame height (mean decay 0.5 level/row -> height ~ 2*levels).
    private var levels = 36

    // Fast xorshift PRNG — Doom-style fire needs thousands of cheap
    // random draws per frame; SystemRandomNumberGenerator is overkill.
    private var rngState: UInt64 = 0x9E3779B97F4A7C15
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
            name: .ultracodeConfigChanged, object: nil)
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
        // Preview thumbnail is tiny; scale the grid down so it still reads.
        pitch = isPreview ? 9 : CGFloat(config.pitch)
        cellSide = pitch * 0.70
        cols = max(1, Int(bounds.width / pitch) + 2)
        rows = max(1, Int(bounds.height / pitch) + 2)
        originX = (bounds.width - CGFloat(cols - 1) * pitch) / 2
        originY = (bounds.height - CGFloat(rows - 1) * pitch) / 2

        levels = max(8, Int(CGFloat(rows) * CGFloat(config.flameHeight) * 0.5))

        heat = .init(repeating: 0, count: cols * rows)
        for i in 0..<cols { heat[i] = levels - 1 }   // bottom row = source

        let stops = Self.themes[config.theme].stops.map(RGB.init)
        let f = CGFloat(config.floor)
        let bgMid = RGB.lerp(bgTop, bgBottom, 0.5)
        levelColors = (0..<levels).map { h in
            // Cold cells sit at the configurable grid floor (default 0.10,
            // the classic idle-lattice look). Intensity scales only the heat
            // contribution, so the flame keeps its shape and height but
            // peaks at a dimmer color.
            let heatPart = pow(CGFloat(h) / CGFloat(levels - 1), 1.25)
            let b = f + (1 - f) * CGFloat(config.intensity) * heatPart
            // The theme ramp bottoms out at its coldest stop, which is
            // brighter than the background; below that band fade toward the
            // background so floor 0 makes empty cells invisible. At the
            // default floor 0.10 this branch never runs.
            if b < 0.10 {
                return RGB.lerp(bgMid, ramp(0.10, stops: stops), b / 0.10).color
            }
            return ramp(b, stops: stops).color
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

    public override func stopAnimation() {
        super.stopAnimation()
        freezeFrameIfNeeded()
    }

    /// "Macintosh"-style pairing emulation: when the real screensaver stops,
    /// persist the current frame as a PNG. A LaunchAgent outside the
    /// legacyScreenSaver sandbox watches this file and applies it as the
    /// desktop wallpaper, so the desktop (and the login screen, which
    /// inherits the user wallpaper) freezes on the last frame.
    private func freezeFrameIfNeeded() {
        guard !isPreview, bounds.width >= 800, !heat.isEmpty else { return }
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(bounds.width * scale),
            pixelsHigh: Int(bounds.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let gctx = NSGraphicsContext(bitmapImageRep: rep) else { return }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gctx
        gctx.cgContext.scaleBy(x: scale, y: scale)
        draw(bounds)
        gctx.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        do {
            // Inside legacyScreenSaver this resolves into its sandbox
            // container; in a plain process it is ~/Library/Application
            // Support. The watcher watches both.
            let dir = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Ultracode", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try png.write(to: dir.appendingPathComponent("lastframe.png"), options: .atomic)
        } catch {
            // Sandbox denied the write — pairing simply won't update.
        }
    }

    // MARK: - Doom fire propagation

    /// One simulation step, straight from the PSX Doom playbook:
    /// heat climbs one row, drifts sideways -1..+1, and randomly loses
    /// 0-1 levels. Rows iterate top-down so each frame propagates
    /// exactly one row (sources are always last frame's values).
    private func stepFire() {
        guard rows > 1 else { return }
        for j in stride(from: rows - 2, through: 0, by: -1) {
            let srcRow = j * cols
            let dstRow = (j + 1) * cols
            for i in 0..<cols {
                let src = heat[srcRow + i]
                let r = nextRand()
                let drift = Int(r & 3) - 1            // -1, 0, 1, 2(wraps)
                let loss = Int((r >> 2) & 1)          // 0 or 1
                var di = i + (drift == 2 ? 0 : drift) // bias-free -1..1
                if di < 0 { di += cols }
                if di >= cols { di -= cols }
                heat[dstRow + di] = max(0, src - loss)
            }
        }
        // Source flicker: tiny random dips keep the base alive, not flat.
        for i in 0..<cols {
            let dip = Int(nextRand() % 4) == 0 ? 1 : 0
            heat[i] = levels - 1 - dip
        }
    }

    public override func animateOneFrame() {
        if heat.isEmpty { rebuildGrid() }
        stepFire()
        needsDisplay = true
    }

    // MARK: - Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if heat.isEmpty { rebuildGrid() }

        drawBackground(ctx)

        let bloomCut = Int(CGFloat(levels - 1) * 0.82)
        for j in 0..<rows {
            let cy = originY + CGFloat(j) * pitch
            let rowBase = j * cols
            for i in 0..<cols {
                let h = heat[rowBase + i]
                let cx = originX + CGFloat(i) * pitch
                drawCell(ctx, x: cx, y: cy,
                         color: levelColors[min(h, levels - 1)],
                         bloom: config.bloom && h >= bloomCut)
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
            // Soft bloom on the hottest cells only — CG shadows are
            // expensive and the fire base has many bright cells.
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

    // MARK: - Configure sheet ("Opções…" in System Settings)

    private var sheet: NSPanel?
    private var themePopup: NSPopUpButton?
    private var heightSlider: NSSlider?
    private var intensitySlider: NSSlider?
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
        // pass runs, and an autolayout-sized panel collapses to ~0 height
        // there. Classic explicit-frame layout is what working third-party
        // savers ship.
        let W: CGFloat = 440, H: CGFloat = 326
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                            styleMask: [.titled],
                            backing: .buffered, defer: false)
        panel.title = "Ultracode"
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

        _ = label("Tema:", row: 278)
        let popup = NSPopUpButton(frame: NSRect(x: 178, y: 272, width: 244, height: 26),
                                  pullsDown: false)
        popup.addItems(withTitles: Self.themes.map(\.name))
        popup.selectItem(at: config.theme)
        content.addSubview(popup)

        _ = label("Altura das chamas:", row: 238)
        let hSlider = slider(config.flameHeight, 0.20, 1.0, row: 238)
        _ = label("Intensidade:", row: 200)
        let iSlider = slider(config.intensity, 0.20, 1.0, row: 200)
        _ = label("Espaçamento da grelha:", row: 162)
        // Detented spacing slider: only positions with no cut cells.
        let detents = Self.pitchDetents()
        pitchDetentValues = detents
        let nearestIdx = detents.enumerated().min {
            abs($0.element - config.pitch) < abs($1.element - config.pitch)
        }!.offset
        let pSlider = slider(Double(nearestIdx), 0, Double(detents.count - 1), row: 162)
        pSlider.numberOfTickMarks = detents.count
        pSlider.allowsTickMarkValuesOnly = true
        _ = label("Velocidade (fps):", row: 124)
        let fSlider = slider(config.fps, 15, 60, row: 124)
        _ = label("Brilho do fundo:", row: 86)
        let flSlider = slider(config.floor, 0.0, 0.30, row: 86)

        let bloom = NSButton(checkboxWithTitle: "Brilho (bloom) nas células quentes",
                             target: nil, action: nil)
        bloom.state = config.bloom ? .on : .off
        bloom.frame = NSRect(x: 180, y: 54, width: 240, height: 20)
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
        heightSlider = hSlider
        intensitySlider = iSlider
        pitchSlider = pSlider
        fpsSlider = fSlider
        floorSlider = flSlider
        bloomCheck = bloom
        return panel
    }

    @objc private func sheetOK(_ sender: Any?) {
        if let d = Self.makeDefaults() {
            d.set(themePopup?.indexOfSelectedItem ?? 0, forKey: "theme")
            d.set(heightSlider?.doubleValue ?? 0.60, forKey: "flameHeight")
            d.set(intensitySlider?.doubleValue ?? 1.0, forKey: "intensity")
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
        NotificationCenter.default.post(name: .ultracodeConfigChanged, object: nil)
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
