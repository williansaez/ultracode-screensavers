import AppKit
import ScreenSaver

private extension Notification.Name {
    static let pongConfigChanged = Notification.Name("UltracodePongConfigChanged")
}

@objc(UltracodePongView)
public final class UltracodePongView: ScreenSaverView {

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

    /// Suite-wide contrast accent: lavanda -> amarelo, Doom -> azul,
    /// Matrix -> vermelho. Used by anything that must pop from the ramp.
    private func contrastAccent(forTheme t: Int) -> RGB {
        switch t {
        case 1: return RGB(0x3A8DFF)
        case 2: return RGB(0xFF453A)
        case 3: return RGB(0xE07000)
        default: return RGB(0xFFD60A)
        }
    }

    // MARK: - User configuration

    private struct Config {
        var theme = 0
        var pitch: Double = 26
        var fps: Double = 30
        var floor: Double = 0.10
        var bloom = true
    }

    private static let moduleName = "com.williansaez.ultracode-pong"

    private static func makeDefaults() -> ScreenSaverDefaults? {
        let d = ScreenSaverDefaults(forModuleWithName: moduleName)
        d?.register(defaults: [
            "theme": 0,
            "pitch": 26.0,
            "fps": 30.0,
            "floorLevel": 0.1,
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

    // MARK: - Grid

    private var cols = 0
    private var rows = 0
    private var pitch: CGFloat = 26
    private var cellSide: CGFloat = 18
    private var originX: CGFloat = 0
    private var originY: CGFloat = 0

    private var levelColors: [NSColor] = []
    private let colorLevels = 32

    /// Pre-rendered background gradient + every cell at floor brightness.
    /// Blitted once per frame so draw() only fills the dynamic cells.
    private var floorImage: CGImage?
    private var floorLevelIndex = 0

    // MARK: - Pong state

    // Self-playing Pong. The ball lives in continuous cell coordinates and
    // leaves a decaying comet tail in `trail`. Both paddles are simple AIs
    // that chase the ball with capped speed plus a per-rally aiming error,
    // so every 20-40 seconds someone whiffs and the other side flashes.

    private let padHalf: Float = 2.5        // paddle = 5 cells tall
    private let padSpeed: Float = 0.3       // cells per frame, capped
    private let ballSpeedX: Float = 0.42
    private let maxVy: Float = 0.34

    private var ballX: Float = 0
    private var ballY: Float = 0
    private var velX: Float = 0
    private var velY: Float = 0

    private var padY: [Float] = [0, 0]      // [left, right] paddle centers
    private var aimErr: [Float] = [0, 0]
    private var react: [Int] = [0, 0]       // reaction-delay frames left

    private var trail: [Float] = []
    private var pauseFrames = 0             // serve delay after a miss
    private var flashFrames = 0             // winner-side score flash
    private var flashSide = 0               // 0 = left half, 1 = right half
    private var serveDir: Float = 1
    private var overrideAimErr: Float? = nil

    // MARK: - RNG (xorshift64)

    private var rngState: UInt64 = 0x243F6A8885A308D3
    private func nextRand() -> UInt64 {
        rngState ^= rngState << 13
        rngState ^= rngState >> 7
        rngState ^= rngState << 17
        return rngState
    }
    private func randFloat() -> Float {            // [0, 1)
        Float(nextRand() % 1_000_000) / 1_000_000
    }
    private func randSigned() -> Float {           // [-1, 1)
        randFloat() * 2 - 1
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
            name: .pongConfigChanged, object: nil)
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
        cols = max(12, Int(bounds.width / pitch) + 1)
        rows = max(10, Int(bounds.height / pitch) + 1)
        originX = (bounds.width - CGFloat(cols - 1) * pitch) / 2
        originY = (bounds.height - CGFloat(rows - 1) * pitch) / 2

        let stops = Self.themes[config.theme].stops.map(RGB.init)
        let f = CGFloat(config.floor)
        levelColors = (0..<colorLevels).map { l in
            let b = f + (1 - f) * CGFloat(l) / CGFloat(colorLevels - 1)
            return ramp(b, stops: stops).color
        }
        floorLevelIndex = min(colorLevels - 1,
                              max(0, Int(f * CGFloat(colorLevels - 1))))
        rebuildFloorImage()

        trail = [Float](repeating: 0, count: cols * rows)
        padY = [Float(rows - 1) / 2, Float(rows - 1) / 2]
        react = [0, 0]
        resampleAim(0)
        resampleAim(1)
        pauseFrames = 0
        flashFrames = 0
        serveDir = randFloat() < 0.5 ? -1 : 1
        serve()
    }

    /// Renders the empty lattice (gradient + floor-color cells) once into a
    /// Retina-scale CGImage. draw(_:) blits it instead of filling thousands
    /// of floor cells per frame. Runs on every rebuildGrid(), so resize,
    /// theme and "Brilho do fundo" changes regenerate it.
    private func rebuildFloorImage() {
        floorImage = nil
        let scale = window?.backingScaleFactor ?? 2
        let pw = max(1, Int(bounds.width * scale))
        let ph = max(1, Int(bounds.height * scale))
        guard !levelColors.isEmpty,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pw, height: ph,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        ctx.scaleBy(x: scale, y: scale)
        drawBackground(ctx)

        ctx.setFillColor(levelColors[floorLevelIndex].cgColor)
        let radius = cellSide * 0.28
        let path = CGMutablePath()
        for i in 0..<cols {
            let cx = originX + CGFloat(i) * pitch
            for j in 0..<rows {
                let cy = originY + CGFloat(j) * pitch
                let rect = CGRect(x: cx - cellSide / 2, y: cy - cellSide / 2,
                                  width: cellSide, height: cellSide)
                path.addPath(CGPath(roundedRect: rect, cornerWidth: radius,
                                    cornerHeight: radius, transform: nil))
            }
        }
        ctx.addPath(path)
        ctx.fillPath()
        floorImage = ctx.makeImage()
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

    private func resampleAim(_ side: Int) {
        if let o = overrideAimErr {
            aimErr[side] = o
        } else {
            aimErr[side] = randSigned() * 3.4
        }
    }

    private func serve() {
        ballX = Float(cols - 1) / 2
        ballY = Float(rows - 1) / 2 + randSigned() * Float(rows) * 0.15
        velX = serveDir * ballSpeedX
        velY = randSigned() * 0.25
        resampleAim(0)
        resampleAim(1)
    }

    private func clampF(_ v: Float, _ lo: Float, _ hi: Float) -> Float {
        min(max(v, lo), hi)
    }

    public override func animateOneFrame() {
        if levelColors.isEmpty || trail.count != cols * rows { rebuildGrid() }

        // Comet tail decay.
        for k in 0..<trail.count {
            trail[k] *= 0.80
            if trail[k] < 0.02 { trail[k] = 0 }
        }
        if flashFrames > 0 { flashFrames -= 1 }

        if pauseFrames > 0 {
            pauseFrames -= 1
            if pauseFrames == 0 { serve() }
            movePaddles()
            needsDisplay = true
            return
        }

        let prevX = ballX
        ballX += velX
        ballY += velY

        // Top/bottom walls.
        let topY = Float(rows - 1)
        if ballY < 0 { ballY = -ballY; velY = abs(velY) }
        if ballY > topY { ballY = 2 * topY - ballY; velY = -abs(velY) }

        // Paddle faces: left paddle in column 1, right in column cols-2.
        let faceL: Float = 1.5
        let faceR = Float(cols - 2) - 0.5

        if velX < 0 && prevX > faceL && ballX <= faceL {
            if abs(ballY - padY[0]) <= padHalf + 0.3 {
                ballX = faceL + (faceL - ballX)
                velX = abs(velX)
                // Spin: where it strikes the paddle bends the return angle.
                velY = clampF(velY * 0.25 + (ballY - padY[0]) * 0.16,
                              -maxVy, maxVy)
                react[1] = Int(config.fps * 0.25)
                resampleAim(1)
            }
        } else if velX > 0 && prevX < faceR && ballX >= faceR {
            if abs(ballY - padY[1]) <= padHalf + 0.3 {
                ballX = faceR - (ballX - faceR)
                velX = -abs(velX)
                velY = clampF(velY * 0.25 + (ballY - padY[1]) * 0.16,
                              -maxVy, maxVy)
                react[0] = Int(config.fps * 0.25)
                resampleAim(0)
            }
        }

        // Score: ball fully out — flash the winner half, pause, then serve
        // toward the loser.
        if ballX < -1.5 {
            flashSide = 1
            flashFrames = Int(config.fps * 0.4)
            pauseFrames = Int(config.fps)
            serveDir = -1
        } else if ballX > Float(cols) + 0.5 {
            flashSide = 0
            flashFrames = Int(config.fps * 0.4)
            pauseFrames = Int(config.fps)
            serveDir = 1
        } else {
            // Stamp the comet head.
            let bi = min(max(Int(ballX.rounded()), 0), cols - 1)
            let bj = min(max(Int(ballY.rounded()), 0), rows - 1)
            trail[bj * cols + bi] = 1.0
        }

        movePaddles()
        needsDisplay = true
    }

    private func movePaddles() {
        let center = Float(rows - 1) / 2
        for side in 0..<2 {
            if react[side] > 0 { react[side] -= 1 }
            let incoming = side == 0 ? velX < 0 : velX > 0
            let target: Float
            if pauseFrames == 0 && incoming && react[side] == 0 {
                target = ballY + aimErr[side]
            } else {
                target = center
            }
            let d = target - padY[side]
            padY[side] += clampF(d, -padSpeed, padSpeed)
            padY[side] = clampF(padY[side], padHalf, Float(rows - 1) - padHalf)
        }
    }

    /// Harness only: pin the aiming error so a miss is deterministic.
    @objc public func debugSetAimError(_ err: Float) {
        overrideAimErr = err
        aimErr = [err, err]
    }

    /// Harness only: clear the pinned aiming error.
    @objc public func debugClearAimError() {
        overrideAimErr = nil
    }

    /// Harness only: true while the score flash is on screen.
    @objc public var debugIsFlashing: Bool { flashFrames > 0 }

    // MARK: - Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if levelColors.isEmpty || trail.count != cols * rows { rebuildGrid() }
        if floorImage == nil { rebuildFloorImage() }

        // Floor blit: gradient + every floor-brightness cell in one call.
        let haveFloor = floorImage != nil
        if let floorImage {
            ctx.draw(floorImage, in: bounds)
        } else {
            drawBackground(ctx)
        }

        let midCol = cols / 2
        let ballVisible = pauseFrames == 0
        let bi = min(max(Int(ballX.rounded()), 0), cols - 1)
        let bj = min(max(Int(ballY.rounded()), 0), rows - 1)
        let f = CGFloat(config.floor)
        let radius = cellSide * 0.28

        // Batch the dynamic cells into ONE path per quantized color level;
        // the ball is held back and drawn individually on top (bloom shadow).
        var levelPaths = [CGMutablePath?](repeating: nil, count: colorLevels)
        var ballPos: (x: CGFloat, y: CGFloat)? = nil

        for i in 0..<cols {
            let cx = originX + CGFloat(i) * pitch
            for j in 0..<rows {
                if ballVisible && i == bi && j == bj {
                    ballPos = (cx, originY + CGFloat(j) * pitch)
                    continue
                }

                var b: CGFloat = f
                // Faint dotted center line, slightly above the floor.
                if i == midCol && j % 2 == 0 { b = f + 0.08 }
                // Comet tail.
                let t = trail[j * cols + i]
                if t > 0 { b = max(b, f + 0.02 + 0.83 * CGFloat(t)) }
                // Score flash lifts the winner half briefly.
                if flashFrames > 0 {
                    if (flashSide == 0 && i < midCol) ||
                       (flashSide == 1 && i > midCol) {
                        b = max(b, f + 0.20)
                    }
                }
                // Paddles.
                if (i == 1 && abs(Float(j) - padY[0]) < padHalf) ||
                   (i == cols - 2 && abs(Float(j) - padY[1]) < padHalf) {
                    b = max(b, 0.80)
                }

                let lvl = min(colorLevels - 1, max(0, Int(b * CGFloat(colorLevels - 1))))
                // Floor-level cells are already in the blit.
                if haveFloor && lvl == floorLevelIndex { continue }

                let cy = originY + CGFloat(j) * pitch
                let rect = CGRect(x: cx - cellSide / 2, y: cy - cellSide / 2,
                                  width: cellSide, height: cellSide)
                let cellPath = CGPath(roundedRect: rect, cornerWidth: radius,
                                      cornerHeight: radius, transform: nil)
                if let p = levelPaths[lvl] {
                    p.addPath(cellPath)
                } else {
                    let p = CGMutablePath()
                    p.addPath(cellPath)
                    levelPaths[lvl] = p
                }
            }
        }

        // One fill per color level present this frame.
        for lvl in 0..<colorLevels {
            guard let p = levelPaths[lvl] else { continue }
            ctx.setFillColor(levelColors[lvl].cgColor)
            ctx.addPath(p)
            ctx.fillPath()
        }

        // Ball: full white-hot in the suite-wide accent, with bloom, on top;
        // trail/paddles stay on the ramp.
        if let pos = ballPos {
            let a = contrastAccent(forTheme: config.theme)
            let cellColor = NSColor(srgbRed: a.r, green: a.g, blue: a.b, alpha: 1)
            drawCell(ctx, x: pos.x, y: pos.y, color: cellColor,
                     bloom: config.bloom)
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
        panel.title = "Pong"
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

        let bloom = NSButton(checkboxWithTitle: "Brilho (bloom) na bola",
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
        NotificationCenter.default.post(name: .pongConfigChanged, object: nil)
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
