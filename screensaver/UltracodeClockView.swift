import AppKit
import ScreenSaver

private extension Notification.Name {
    static let clockConfigChanged = Notification.Name("UltracodeClockConfigChanged")
}

@objc(UltracodeClockView)
public final class UltracodeClockView: ScreenSaverView {

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

    private static let moduleName = "com.williansaez.ultracode-clock"

    private static func makeDefaults() -> ScreenSaverDefaults? {
        let d = ScreenSaverDefaults(forModuleWithName: moduleName)
        d?.register(defaults: [
            "theme": 0,
            "pitch": 26.0,
            "fps": 30.0,
            "bloom": true,
            "floorLevel": 0.18,
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

    // MARK: - 5x7 digit font (rows top to bottom, 5 bits each, MSB = left)

    private static let digitFont: [[UInt8]] = [
        [0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110], // 0
        [0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110], // 1
        [0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b01000, 0b11111], // 2
        [0b11111, 0b00010, 0b00100, 0b00010, 0b00001, 0b10001, 0b01110], // 3
        [0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010], // 4
        [0b11111, 0b10000, 0b11110, 0b00001, 0b00001, 0b10001, 0b01110], // 5
        [0b00110, 0b01000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110], // 6
        [0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000], // 7
        [0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110], // 8
        [0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00010, 0b01100], // 9
    ]

    // Glyph layout in base (unscaled) cells: D gap D gap : gap D gap D
    // Digit base-x positions and the colon column; total width 25, height 7.
    private static let digitBaseX = [0, 6, 14, 20]
    private static let colonBaseX = 12
    private static let baseWidth = 25
    private static let baseHeight = 7

    // MARK: - Grid

    private var cols = 0
    private var rows = 0
    private var pitch: CGFloat = 26
    private var cellSide: CGFloat = 18
    private var originX: CGFloat = 0
    private var originY: CGFloat = 0

    private var levelColors: [NSColor] = []
    private let colorLevels = 32

    /// Pre-rendered empty lattice (bg gradient + every cell at floor color),
    /// blitted as the first draw step so floor cells cost one image draw
    /// instead of thousands of path fills. Rebuilt by rebuildGrid().
    private var floorImage: CGImage?

    /// Quantized color level of an empty (floor) cell; cells at this level
    /// are skipped during drawing because the floor blit already shows them.
    private var floorLevel: Int {
        let f = CGFloat(config.floor)
        return min(colorLevels - 1, max(0, Int(f * CGFloat(colorLevels - 1))))
    }

    // MARK: - Clock state

    // The lit-cell sets of the four HH:MM digits, plus a separately handled
    // blinking colon. On minute change the differing cells flip at random
    // per-cell times spread over ~1 s; brightness eases toward each cell's
    // lit target, so old digits dissolve while the new ones sparkle in.

    private var scale = 1               // whole cells per font cell
    private var clockX = 0              // grid col of glyph block origin
    private var clockY = 0              // grid row of glyph block origin (bottom)

    private var litDigit: [Bool] = []   // current lit target per cell (digits)
    private var pendingLit: [Bool] = [] // lit set being transitioned to
    private var offAt: [Double] = []    // per-cell dissolve time (sim seconds)
    private var onAt: [Double] = []     // per-cell light-up time (sim seconds)
    private var transitionUntil: Double = -1
    private var colonCells: [Int] = []  // grid indices of the two colon dots
    private var brightness: [Float] = [] // eased draw brightness per cell
    private var shimmerPhase: [Float] = []

    private var shownHour = -1
    private var shownMinute = -1
    private var shownDigits: [Int] = [-1, -1, -1, -1]
    private var simTime: Double = 0

    private var overrideHM: (Int, Int)? = nil
    private var overrideColon: Bool? = nil

    private var rngState: UInt64 = 0x243F6A8885A308D3
    private func nextRand() -> UInt64 {
        rngState ^= rngState << 13
        rngState ^= rngState >> 7
        rngState ^= rngState << 17
        return rngState
    }
    private func randUnit() -> Double {
        Double(nextRand() % 1_000_000) / 1_000_000.0
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
            name: .clockConfigChanged, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func configChanged() {
        loadConfig()
        rebuildGrid()
        needsDisplay = true
    }

    // MARK: - Time

    private func currentHM() -> (Int, Int) {
        if let o = overrideHM { return o }
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return (c.hour ?? 0, c.minute ?? 0)
    }

    private func colonOn() -> Bool {
        if let o = overrideColon { return o }
        // 1 Hz blink: one second on, one second off.
        return Int(Date().timeIntervalSince1970) % 2 == 0
    }

    // MARK: - Layout

    private func rebuildGrid() {
        pitch = isPreview ? 9 : CGFloat(config.pitch)
        cellSide = pitch * 0.70
        cols = max(4, Int(bounds.width / pitch) + 1)
        rows = max(4, Int(bounds.height / pitch) + 1)
        originX = (bounds.width - CGFloat(cols - 1) * pitch) / 2
        originY = (bounds.height - CGFloat(rows - 1) * pitch) / 2

        let stops = Self.themes[config.theme].stops.map(RGB.init)
        let f = CGFloat(config.floor)
        levelColors = (0..<colorLevels).map { l in
            let b = f + (1 - f) * CGFloat(l) / CGFloat(colorLevels - 1)
            return ramp(b, stops: stops).color
        }

        // Whole-cell font scale: clock spans ~60% of the grid width.
        scale = max(1, Int((0.6 * Double(cols) / Double(Self.baseWidth)).rounded()))
        while scale > 1 && (Self.baseWidth * scale > cols - 2 ||
                            Self.baseHeight * scale > rows - 2) {
            scale -= 1
        }
        clockX = (cols - Self.baseWidth * scale) / 2
        clockY = (rows - Self.baseHeight * scale) / 2

        let n = cols * rows
        offAt = .init(repeating: .infinity, count: n)
        onAt = .init(repeating: .infinity, count: n)
        transitionUntil = -1
        shimmerPhase = (0..<n).map { _ in Float(randUnit()) * 2 * .pi }

        // Colon: two s x s dots at font rows 2 and 4 (top-indexed).
        colonCells = []
        for fontRow in [2, 4] {
            for sy in 0..<scale {
                let j = clockY + (Self.baseHeight - 1 - fontRow) * scale + sy
                for sx in 0..<scale {
                    let i = clockX + Self.colonBaseX * scale + sx
                    if i >= 0 && i < cols && j >= 0 && j < rows {
                        colonCells.append(j * cols + i)
                    }
                }
            }
        }

        let (h, m) = currentHM()
        shownHour = h; shownMinute = m
        shownDigits = [h / 10, h % 10, m / 10, m % 10]
        litDigit = computeLit(hour: h, minute: m)
        pendingLit = litDigit
        brightness = litDigit.map { $0 ? 1 : 0 }

        rebuildFloorImage()
    }

    /// Renders the empty lattice (bg gradient + all cells at floor color)
    /// once into a Retina-scale CGImage for per-frame blitting.
    private func rebuildFloorImage() {
        floorImage = nil
        let imgScale = window?.backingScaleFactor ?? 2
        let pxW = Int((bounds.width * imgScale).rounded())
        let pxH = Int((bounds.height * imgScale).rounded())
        guard pxW > 0, pxH > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pxW, height: pxH,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        ctx.scaleBy(x: imgScale, y: imgScale)

        drawBackground(ctx)

        guard !levelColors.isEmpty else { return }
        ctx.setFillColor(levelColors[floorLevel].cgColor)
        let radius = cellSide * 0.28
        let path = CGMutablePath()
        for j in 0..<rows {
            let cy = originY + CGFloat(j) * pitch
            for i in 0..<cols {
                let rect = CGRect(x: originX + CGFloat(i) * pitch - cellSide / 2,
                                  y: cy - cellSide / 2,
                                  width: cellSide, height: cellSide)
                path.addPath(CGPath(roundedRect: rect, cornerWidth: radius,
                                    cornerHeight: radius, transform: nil))
            }
        }
        ctx.addPath(path)
        ctx.fillPath()
        floorImage = ctx.makeImage()
    }

    /// Grid-cell indices covered by one digit slot's 5x7 block.
    private func slotCells(_ slot: Int) -> [Int] {
        var cells: [Int] = []
        let baseX = Self.digitBaseX[slot]
        for j in clockY..<(clockY + Self.baseHeight * scale) where j >= 0 && j < rows {
            for fontCol in 0..<5 {
                for sx in 0..<scale {
                    let i = clockX + (baseX + fontCol) * scale + sx
                    if i >= 0 && i < cols { cells.append(j * cols + i) }
                }
            }
        }
        return cells
    }

    /// Lit-cell mask for the four digits of HH:MM (colon excluded).
    private func computeLit(hour: Int, minute: Int) -> [Bool] {
        var lit = [Bool](repeating: false, count: cols * rows)
        let digits = [hour / 10, hour % 10, minute / 10, minute % 10]
        for (slot, d) in digits.enumerated() {
            let glyph = Self.digitFont[d]
            let baseX = Self.digitBaseX[slot]
            for fontRow in 0..<Self.baseHeight {
                let bits = glyph[fontRow]
                for fontCol in 0..<5 where bits & (1 << (4 - fontCol)) != 0 {
                    for sy in 0..<scale {
                        let j = clockY + (Self.baseHeight - 1 - fontRow) * scale + sy
                        guard j >= 0 && j < rows else { continue }
                        for sx in 0..<scale {
                            let i = clockX + (baseX + fontCol) * scale + sx
                            guard i >= 0 && i < cols else { continue }
                            lit[j * cols + i] = true
                        }
                    }
                }
            }
        }
        return lit
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

    // MARK: - Frame

    public override func animateOneFrame() {
        if levelColors.isEmpty || litDigit.count != cols * rows { rebuildGrid() }
        simTime += 1.0 / config.fps

        // Minute change: every lit cell of an outgoing digit dissolves in
        // random order while the incoming digit's cells light up in random
        // order; cells shared by both glyphs blink off then back on.
        let (h, m) = currentHM()
        if h != shownHour || m != shownMinute {
            if transitionUntil >= 0 {                    // finish previous
                litDigit = pendingLit
                for i in 0..<offAt.count { offAt[i] = .infinity; onAt[i] = .infinity }
            }
            let newDigits = [h / 10, h % 10, m / 10, m % 10]
            let newLit = computeLit(hour: h, minute: m)
            for slot in 0..<4 where shownDigits[slot] != newDigits[slot] {
                for idx in slotCells(slot) {
                    let wasOn = litDigit[idx], willBeOn = newLit[idx]
                    if wasOn && !willBeOn {
                        offAt[idx] = simTime + randUnit() * 0.9
                    } else if !wasOn && willBeOn {
                        onAt[idx] = simTime + 0.1 + randUnit() * 0.8
                    } else if wasOn && willBeOn {
                        offAt[idx] = simTime + randUnit() * 0.40
                        onAt[idx] = simTime + 0.50 + randUnit() * 0.45
                    }
                }
            }
            pendingLit = newLit
            transitionUntil = simTime + 1.05
            shownHour = h; shownMinute = m
            shownDigits = newDigits
        }
        if transitionUntil >= 0 {
            for i in 0..<litDigit.count {
                if offAt[i] <= simTime { litDigit[i] = false; offAt[i] = .infinity }
                if onAt[i] <= simTime { litDigit[i] = true; onAt[i] = .infinity }
            }
            if simTime >= transitionUntil {
                litDigit = pendingLit
                transitionUntil = -1
            }
        }

        // Ease brightness toward each cell's target (digits + blinking colon).
        let colon: Float = colonOn() ? 1 : 0
        for i in 0..<brightness.count {
            let target: Float = litDigit[i] ? 1 : 0
            brightness[i] += (target - brightness[i]) * 0.28
        }
        for c in colonCells {
            brightness[c] += (colon - brightness[c]) * 0.28
        }
        needsDisplay = true
    }

    /// Harness only: pin the displayed time and colon state for snapshots.
    @objc public func debugSetTime(_ hour: Int, _ minute: Int, colonOn: Bool) {
        overrideHM = (hour, minute)
        overrideColon = colonOn
    }

    // MARK: - Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if levelColors.isEmpty || brightness.count != cols * rows
            || floorImage == nil { rebuildGrid() }

        // 1. Blit the pre-rendered empty lattice (gradient + floor cells).
        if let floorImage {
            ctx.draw(floorImage, in: bounds)
        } else {
            drawBackground(ctx)
        }

        var colonSet = [Bool](repeating: false, count: cols * rows)
        for c in colonCells { colonSet[c] = true }

        let t = Float(simTime)
        let f = CGFloat(config.floor)
        let floorLvl = floorLevel
        let radius = cellSide * 0.28

        // 2. Batch the dynamic (brighter-than-floor) cells: one path per
        //    quantized level, one fill per level present this frame.
        var levelPaths = [CGMutablePath?](repeating: nil, count: colorLevels)
        var bloomCells: [(x: CGFloat, y: CGFloat, lvl: Int)] = []

        for j in 0..<rows {
            let cy = originY + CGFloat(j) * pitch
            let rowBase = j * cols
            for i in 0..<cols {
                let idx = rowBase + i
                var v = brightness[idx]
                // Idle shimmer: subtle brightness noise on lit cells only.
                if v > 0.05 {
                    v += 0.04 * sin(t * 1.7 + shimmerPhase[idx]) * v
                }
                // Config floor (empty cells) -> near-full lit on the theme
                // ramp; 0.75/0.90 keeps the lit top identical at floor 0.10.
                let b = f + (1 - f) * (0.75 / 0.90) * CGFloat(min(max(v, 0), 1))
                let lvl = min(colorLevels - 1, max(0, Int(b * CGFloat(colorLevels - 1))))
                if config.bloom && colonSet[idx] && v > 0.5 {
                    bloomCells.append((originX + CGFloat(i) * pitch, cy, lvl))
                    continue
                }
                if lvl == floorLvl { continue }  // floor blit already shows it
                let rect = CGRect(x: originX + CGFloat(i) * pitch - cellSide / 2,
                                  y: cy - cellSide / 2,
                                  width: cellSide, height: cellSide)
                let path = levelPaths[lvl] ?? CGMutablePath()
                path.addPath(CGPath(roundedRect: rect, cornerWidth: radius,
                                    cornerHeight: radius, transform: nil))
                levelPaths[lvl] = path
            }
        }

        for lvl in 0..<colorLevels {
            guard let path = levelPaths[lvl] else { continue }
            ctx.setFillColor(levelColors[lvl].cgColor)
            ctx.addPath(path)
            ctx.fillPath()
        }

        // 3. Bloomed colon dots: few cells, drawn individually on top so the
        //    shadow renders correctly.
        for cell in bloomCells {
            drawCell(ctx, x: cell.x, y: cell.y,
                     color: levelColors[cell.lvl], bloom: true)
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
        panel.title = "Relógio"
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

        let bloom = NSButton(checkboxWithTitle: "Brilho (bloom) nos dois pontos",
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
        NotificationCenter.default.post(name: .clockConfigChanged, object: nil)
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
