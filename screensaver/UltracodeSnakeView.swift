import AppKit
import ScreenSaver

private extension Notification.Name {
    static let snakeConfigChanged = Notification.Name("UltracodeSnakeConfigChanged")
}

@objc(UltracodeSnakeView)
public final class UltracodeSnakeView: ScreenSaverView {

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

    /// Suite-wide contrast accent: lavanda -> amarelo, Doom -> azul,
    /// Matrix -> vermelho. Used by anything that must pop from the ramp.
    private func contrastAccent(forTheme t: Int) -> RGB {
        switch t {
        case 1: return RGB(0x3A8DFF)
        case 2: return RGB(0xFF453A)
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

    private static let moduleName = "com.williansaez.ultracode-snake"

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

    // MARK: - Grid

    private var cols = 0
    private var rows = 0
    private var pitch: CGFloat = 26
    private var cellSide: CGFloat = 18
    private var originX: CGFloat = 0
    private var originY: CGFloat = 0

    private var levelColors: [NSColor] = []
    private let colorLevels = 32

    // MARK: - Snake state

    // Self-playing Snake. The whole grid is the board; the edges are walls.
    // The snake is a deque of cell indices (head first). Each sim step the AI
    // BFSes the shortest path to the food avoiding its own body; if no safe
    // path exists it chases its own tail to stay alive. Eating grows the
    // snake by 3 and fires a glow wave down the body. Death (rare) flashes
    // the body white-ish and dissolves it over ~1s before a respawn.

    private enum Phase { case playing, dying }

    private var snake: [Int] = []          // cell indices, head at [0]
    private var food = -1
    private var pendingGrowth = 0
    private var phaseState: Phase = .playing
    private var deathTick = 0
    private var deathTotal = 30
    private var waveTick = -1              // frames since last eat, -1 = idle
    private var waveTotal = 6              // ~0.2 s worth of frames
    private var tailChaseStreak = 0        // consecutive survival moves
    private var frameCount = 0
    private var pulse: CGFloat = 0

    // MARK: - RNG (xorshift64)

    private var rngState: UInt64 = 0x9E3779B97F4A7C15

    private func rand64() -> UInt64 {
        rngState ^= rngState << 13
        rngState ^= rngState >> 7
        rngState ^= rngState << 17
        return rngState
    }

    private func randInt(_ n: Int) -> Int {
        n > 0 ? Int(rand64() % UInt64(n)) : 0
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
        let seed = UInt64(Date().timeIntervalSince1970 * 1000)
        rngState = seed == 0 ? 0x9E3779B97F4A7C15 : seed
        loadConfig()
        NotificationCenter.default.addObserver(
            self, selector: #selector(configChanged),
            name: .snakeConfigChanged, object: nil)
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
        rows = max(6, Int(bounds.height / pitch) + 1)
        originX = (bounds.width - CGFloat(cols - 1) * pitch) / 2
        originY = (bounds.height - CGFloat(rows - 1) * pitch) / 2

        let stops = Self.themes[config.theme].stops.map(RGB.init)
        let f = CGFloat(config.floor)
        levelColors = (0..<colorLevels).map { l in
            let b = f + (1 - f) * CGFloat(l) / CGFloat(colorLevels - 1)
            return ramp(b, stops: stops).color
        }

        waveTotal = max(3, Int(config.fps * 0.2))
        deathTotal = max(10, Int(config.fps))
        respawnSnake()
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

    // MARK: - Game logic

    private func respawnSnake() {
        let len = 6
        let y = rows / 2
        let xHead = min(cols - 2, max(len, cols / 2 + len / 2))
        snake = (0..<len).map { y * cols + max(0, xHead - $0) }
        pendingGrowth = 0
        phaseState = .playing
        deathTick = 0
        waveTick = -1
        tailChaseStreak = 0
        spawnFood()
    }

    private func spawnFood() {
        let total = cols * rows
        guard total - snake.count > 0 else { food = -1; return }
        var occupied = [Bool](repeating: false, count: total)
        for c in snake { occupied[c] = true }
        for _ in 0..<64 {
            let c = randInt(total)
            if !occupied[c] { food = c; return }
        }
        let off = randInt(total)
        for k in 0..<total {
            let c = (off + k) % total
            if !occupied[c] { food = c; return }
        }
        food = -1
    }

    /// BFS shortest path from start to goal on the grid, around blocked
    /// cells (the goal itself may be blocked: the tail counts as reachable).
    /// Returns the full path [start, ..., goal], or nil.
    private func bfs(from start: Int, to goal: Int, blocked: [Bool]) -> [Int]? {
        if start == goal { return [start] }
        let total = cols * rows
        var prev = [Int32](repeating: -1, count: total)
        var queue = [start]
        prev[start] = Int32(start)
        var qi = 0
        while qi < queue.count {
            let c = queue[qi]; qi += 1
            let x = c % cols, y = c / cols
            let neighbors = [
                x + 1 < cols ? c + 1 : -1,
                x - 1 >= 0 ? c - 1 : -1,
                y + 1 < rows ? c + cols : -1,
                y - 1 >= 0 ? c - cols : -1,
            ]
            for n in neighbors {
                if n < 0 || prev[n] != -1 { continue }
                if blocked[n] && n != goal { continue }
                prev[n] = Int32(c)
                if n == goal {
                    var path = [n]
                    var cur = n
                    while cur != start {
                        cur = Int(prev[cur])
                        path.append(cur)
                    }
                    return path.reversed()
                }
                queue.append(n)
            }
        }
        return nil
    }

    /// Walk the snake virtually along the path to the food (growing by 3 at
    /// the end) and check it can still reach its own tail afterwards.
    private func pathIsSafe(_ path: [Int]) -> Bool {
        var body = snake
        var grow = pendingGrowth
        for step in path.dropFirst() {
            body.insert(step, at: 0)
            if grow > 0 { grow -= 1 } else { body.removeLast() }
        }
        // after eating, the tail stays put for 3 steps; conservative check:
        var blocked = [Bool](repeating: false, count: cols * rows)
        for c in body { blocked[c] = true }
        let tail = body[body.count - 1]
        return bfs(from: body[0], to: tail, blocked: blocked) != nil
    }

    private func stepSnake() {
        guard snake.count > 1, food >= 0 else { return }
        let total = cols * rows
        let head = snake[0]
        let tail = snake[snake.count - 1]

        var blocked = [Bool](repeating: false, count: total)
        for c in snake { blocked[c] = true }
        // The tail vacates its cell this step unless the snake is growing.
        if pendingGrowth == 0 { blocked[tail] = false }

        var next = -1
        let foodPath = bfs(from: head, to: food, blocked: blocked)
        if let path = foodPath, path.count >= 2, pathIsSafe(path) {
            next = path[1]
            tailChaseStreak = 0
            debugFoodPathTaken += 1
        } else if tailChaseStreak > 4 * (cols + rows),
                  let path = foodPath, path.count >= 2 {
            // Stall-breaker: chasing the tail forever means a permanent
            // loop. Gamble on the unsafe food path; a death dissolves and
            // respawns gracefully anyway.
            next = path[1]
            tailChaseStreak = 0
            debugFoodPathTaken += 1
        } else {
            // Tail-follow survival. Plain shortest-path-to-tail can lock the
            // snake into a closed loop forever, so among the SAFE neighbor
            // moves (tail still reachable afterwards) pick the one that
            // keeps the head FARTHEST from the tail: the snake sweeps wide
            // instead of spinning, and food paths reopen.
            var bestDist = -1
            let x = head % cols, y = head / cols
            let neighbors = [
                x + 1 < cols ? head + 1 : -1,
                x - 1 >= 0 ? head - 1 : -1,
                y + 1 < rows ? head + cols : -1,
                y - 1 >= 0 ? head - cols : -1,
            ]
            for nb in neighbors where nb >= 0 && !blocked[nb] {
                var body2 = snake
                body2.insert(nb, at: 0)
                if nb != food {
                    if pendingGrowth == 0 { body2.removeLast() }
                }
                var blocked2 = [Bool](repeating: false, count: total)
                for c in body2 { blocked2[c] = true }
                let tail2 = body2[body2.count - 1]
                if let p = bfs(from: nb, to: tail2, blocked: blocked2),
                   p.count > bestDist {
                    bestDist = p.count
                    next = nb
                }
            }
            if next >= 0 {
                tailChaseStreak += 1
                debugTailChaseTaken += 1
            }
        }

        // Final safety net: refuse to step into a body cell; otherwise take
        // any free neighbor; with nowhere to go, die.
        if next < 0 || blocked[next] {
            next = -1
            let x = head % cols, y = head / cols
            let neighbors = [
                x + 1 < cols ? head + 1 : -1,
                x - 1 >= 0 ? head - 1 : -1,
                y + 1 < rows ? head + cols : -1,
                y - 1 >= 0 ? head - cols : -1,
            ]
            for n in neighbors where n >= 0 && !blocked[n] {
                next = n
                break
            }
            if next >= 0 { debugPanicTaken += 1 }
        }
        guard next >= 0 else {
            phaseState = .dying
            deathTick = 0
            debugDeaths += 1
            return
        }

        snake.insert(next, at: 0)
        if next == food {
            pendingGrowth += 3
            waveTick = 0
            debugEats += 1
            spawnFood()
        }
        if pendingGrowth > 0 {
            pendingGrowth -= 1
        } else {
            snake.removeLast()
        }

        // No win-reset: the run only ends when the snake actually dies.
        // (spawnFood() returning no spot on a full board starves the snake
        // into a corner eventually, which is a death like any other.)
    }

    // MARK: - Debug (offline harness only)

    @objc public var debugLength: Int { snake.count }
    @objc public var debugEats = 0
    @objc public var debugDeaths = 0
    @objc public var debugFoodPathTaken = 0
    @objc public var debugTailChaseTaken = 0
    @objc public var debugPanicTaken = 0

    // MARK: - Frame

    public override func animateOneFrame() {
        if levelColors.isEmpty { rebuildGrid() }
        frameCount += 1
        pulse += 0.15
        switch phaseState {
        case .playing:
            // One sim move every 2nd frame: moves/s scales with the fps dial.
            if frameCount % 2 == 0 { stepSnake() }
            if waveTick >= 0 {
                waveTick += 1
                if waveTick > waveTotal { waveTick = -1 }
            }
        case .dying:
            deathTick += 1
            if deathTick >= deathTotal { respawnSnake() }
        }
        needsDisplay = true
    }

    // MARK: - Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if levelColors.isEmpty { rebuildGrid() }

        drawBackground(ctx)

        let total = cols * rows
        var bodyIndex = [Int32](repeating: -1, count: total)
        for (i, c) in snake.enumerated() where c >= 0 && c < total {
            bodyIndex[c] = Int32(i)
        }
        let n = snake.count
        let dying = phaseState == .dying
        let deathT = dying ? CGFloat(deathTick) / CGFloat(max(1, deathTotal)) : 0
        let wavePos: CGFloat = waveTick >= 0
            ? CGFloat(waveTick) / CGFloat(max(1, waveTotal)) * CGFloat(n)
            : -100
        let f = CGFloat(config.floor)

        for i in 0..<cols {
            let cx = originX + CGFloat(i) * pitch
            for j in 0..<rows {
                let cy = originY + CGFloat(j) * pitch
                let idx = j * cols + i
                let bi = Int(bodyIndex[idx])

                var b: CGFloat = f
                var bloom = false
                if bi >= 0 {
                    if dying {
                        // White-ish flash that dissolves back into the grid.
                        b = 0.98 + (f - 0.98) * deathT
                    } else if bi == 0 {
                        b = 0.95
                        bloom = config.bloom
                    } else {
                        // Body gradient down the ramp toward the tail.
                        let t = CGFloat(bi) / CGFloat(max(1, n - 1))
                        b = 0.90 - 0.45 * t
                        if abs(CGFloat(bi) - wavePos) < 1.6 {
                            b = min(1.0, b + 0.35)
                            bloom = config.bloom
                        }
                    }
                }
                var foodCell = false
                if bi < 0 && idx == food && food >= 0 {
                    // Food: theme contrast accent, soft pulse, bloom.
                    b = 0.86 + 0.12 * (0.5 + 0.5 * sin(pulse * 2))
                    bloom = config.bloom && !dying
                    foodCell = true
                }

                let color: NSColor
                if foodCell {
                    let a = contrastAccent(forTheme: config.theme)
                    color = NSColor(srgbRed: a.r * b, green: a.g * b,
                                    blue: a.b * b, alpha: 1)
                } else {
                    let lvl = min(colorLevels - 1,
                                  max(0, Int(b * CGFloat(colorLevels - 1))))
                    color = levelColors[lvl]
                }
                drawCell(ctx, x: cx, y: cy, color: color, bloom: bloom)
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
        panel.title = "Snake"
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

        let bloom = NSButton(checkboxWithTitle: "Brilho (bloom) na cabeça e na comida",
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
        NotificationCenter.default.post(name: .snakeConfigChanged, object: nil)
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
