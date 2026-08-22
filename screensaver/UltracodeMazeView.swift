import AppKit
import ScreenSaver

private extension Notification.Name {
    static let mazeConfigChanged = Notification.Name("UltracodeMazeConfigChanged")
}

@objc(UltracodeMazeView)
public final class UltracodeMazeView: ScreenSaverView {

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

    private static let moduleName = "com.williansaez.ultracode-maze"

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
    private var accentColors: [NSColor] = []   // solution path (contrast accent)
    private let colorLevels = 32

    /// Quantized level the empty "floor" brightness maps to; cells at this
    /// level are covered by the pre-rendered floor blit and skipped in draw.
    private var floorLevel = 0
    /// Bg gradient + full empty lattice, pre-rendered once per rebuildGrid().
    private var floorImage: CGImage?
    /// One rounded-rect sprite per quantized color (ramp + accent banks),
    /// stamped in draw(_:) when a single color level holds more cells than
    /// spriteThreshold (compound-path fills scale poorly past ~1k subpaths).
    private var cellSprites: [CGImage?] = []
    private var spriteScale: CGFloat = 2
    private static let spriteThreshold = 1024

    // MARK: - Maze state
    //
    // A classic odd lattice maze mapped onto the display cells: maze nodes sit
    // every 2 cells, the cells between them are walls until carved. The saver
    // loops generate (recursive backtracker) -> solve (BFS + path trace) ->
    // hold -> dissolve, then starts a fresh maze.

    private enum Phase { case generating, solving, tracing, holding, dissolving }
    private var phase: Phase = .generating

    private var mazeCols = 0          // logical maze nodes horizontally
    private var mazeRows = 0
    private var offX = 0              // display-cell offset of the lattice
    private var offY = 0

    private var carved: [Bool] = []   // display cells that are passage
    private var base: [CGFloat] = []  // persistent brightness per display cell
    private var flash: [CGFloat] = [] // decaying overlay (fresh carve)
    private var isPath: [Bool] = []   // solution path cells (pulse in hold)

    // generation
    private var visited: [Bool] = []
    private var stack: [Int] = []
    private var headCell = -1         // display cell of the carving head

    // solving (BFS)
    private var bfsParent: [Int32] = []
    private var bfsFrontier: [Int] = []
    private var startNode = 0
    private var goalNode = 0

    // tracing
    private var pathCells: [Int] = []
    private var traceIdx = 0
    private var tipCell = -1

    // hold / dissolve
    private var holdLeft = 0
    private var dissolveList: [Int] = []
    private var dissolveFramesLeft = 0

    private var tick = 0
    private var pulsePhase: CGFloat = 0

    private var rngState: UInt64 = 0x243F6A8885A308D3
    private func nextRand() -> UInt64 {
        rngState ^= rngState << 13
        rngState ^= rngState >> 7
        rngState ^= rngState << 17
        return rngState
    }
    private func randInt(_ n: Int) -> Int { Int(nextRand() % UInt64(max(1, n))) }

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
            name: .mazeConfigChanged, object: nil)
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
        cols = max(7, Int(bounds.width / pitch) + 1)
        rows = max(7, Int(bounds.height / pitch) + 1)
        originX = (bounds.width - CGFloat(cols - 1) * pitch) / 2
        originY = (bounds.height - CGFloat(rows - 1) * pitch) / 2

        let stops = Self.themes[config.theme].stops.map(RGB.init)
        let f = CGFloat(config.floor)
        levelColors = (0..<colorLevels).map { l in
            let b = f + (1 - f) * CGFloat(l) / CGFloat(colorLevels - 1)
            return ramp(b, stops: stops).color
        }
        // The ramp's darkest stop is brighter than the background, so below
        // the legacy 0.10 floor ease the wall (empty-cell) level into the bg:
        // at f = 0 the uncarved grid vanishes; at f >= 0.10 it sits on the
        // ramp exactly as before. Only the floor level is touched -- carved
        // passages (base >= 0.35) never map this low.
        floorLevel = min(colorLevels - 1,
                         max(0, Int(f * CGFloat(colorLevels - 1))))
        if f < 0.10 {
            let bgMid = RGB.lerp(bgTop, bgBottom, 0.5)
            let onRamp = f + (1 - f) * CGFloat(floorLevel) / CGFloat(colorLevels - 1)
            levelColors[floorLevel] =
                RGB.lerp(bgMid, ramp(onRamp, stops: stops), f / 0.10).color
        }
        let a = contrastAccent(forTheme: config.theme)
        accentColors = (0..<colorLevels).map { l in
            let b = f + (1 - f) * CGFloat(l) / CGFloat(colorLevels - 1)
            return NSColor(srgbRed: a.r * b, green: a.g * b, blue: a.b * b, alpha: 1)
        }

        mazeCols = max(2, (cols - 1) / 2)
        mazeRows = max(2, (rows - 1) / 2)
        // Lattice footprint is 2*mazeCols+1 display cells; center it.
        offX = max(0, (cols - (2 * mazeCols + 1)) / 2)
        offY = max(0, (rows - (2 * mazeRows + 1)) / 2)

        rngState = 0x243F6A8885A308D3 &+ UInt64(tick &* 2654435761) &+ 0x9E3779B97F4A7C15
        resetMaze()
        rebuildFloorImage()
        rebuildCellSprites()
    }

    /// Pre-render one cell sprite per quantized color at Retina scale.
    /// Rebuilt with the grid so theme, pitch and floor changes stay live.
    private func rebuildCellSprites() {
        spriteScale = window?.backingScaleFactor ?? 2
        cellSprites = .init(repeating: nil, count: colorLevels * 2)
        let px = Int(ceil(cellSide * spriteScale))
        guard px > 0, !levelColors.isEmpty,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return }
        let corner = cellSide * 0.28
        for key in 0..<(colorLevels * 2) {
            guard let ctx = CGContext(data: nil, width: px, height: px,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { continue }
            ctx.scaleBy(x: spriteScale, y: spriteScale)
            let color = key < colorLevels ? levelColors[key]
                                          : accentColors[key - colorLevels]
            ctx.setFillColor(color.cgColor)
            ctx.addPath(CGPath(
                roundedRect: CGRect(x: 0, y: 0,
                                    width: cellSide, height: cellSide),
                cornerWidth: corner, cornerHeight: corner, transform: nil))
            ctx.fillPath()
            cellSprites[key] = ctx.makeImage()
        }
    }

    /// Pre-render the background gradient plus EVERY cell at the floor color
    /// into a Retina-scale CGImage. draw(_:) blits it as the first step each
    /// frame instead of filling thousands of floor cells. Rebuilt whenever
    /// rebuildGrid() runs, so resize, theme and the "Brilho do fundo" slider
    /// stay live.
    private func rebuildFloorImage() {
        floorImage = nil
        let scale = window?.backingScaleFactor ?? 2
        let pxW = Int((bounds.width * scale).rounded())
        let pxH = Int((bounds.height * scale).rounded())
        guard pxW > 0, pxH > 0, !levelColors.isEmpty,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pxW, height: pxH,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        ctx.scaleBy(x: scale, y: scale)

        // Same gradient as drawBackground(_:).
        let colors = [bgTop.color.cgColor, bgBottom.color.cgColor] as CFArray
        if let grad = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(grad,
                                   start: CGPoint(x: 0, y: bounds.height),
                                   end: CGPoint(x: 0, y: 0),
                                   options: [])
        } else {
            ctx.setFillColor(bgTop.color.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height))
        }

        let corner = cellSide * 0.28
        let half = cellSide / 2
        let lattice = CGMutablePath()
        for j in 0..<rows {
            let cy = originY + CGFloat(j) * pitch
            for i in 0..<cols {
                let cx = originX + CGFloat(i) * pitch
                lattice.addPath(CGPath(
                    roundedRect: CGRect(x: cx - half, y: cy - half,
                                        width: cellSide, height: cellSide),
                    cornerWidth: corner, cornerHeight: corner, transform: nil))
            }
        }
        ctx.setFillColor(levelColors[floorLevel].cgColor)
        ctx.addPath(lattice)
        ctx.fillPath()
        floorImage = ctx.makeImage()
    }

    private func nodeCell(_ mx: Int, _ my: Int) -> Int {
        (offY + 2 * my + 1) * cols + (offX + 2 * mx + 1)
    }

    private func resetMaze() {
        let n = cols * rows
        carved = .init(repeating: false, count: n)
        base = .init(repeating: CGFloat(config.floor), count: n)
        flash = .init(repeating: 0, count: n)
        isPath = .init(repeating: false, count: n)

        let m = mazeCols * mazeRows
        visited = .init(repeating: false, count: m)
        // Start carving from a random node so each maze grows differently.
        let s = randInt(m)
        visited[s] = true
        stack = [s]
        let c = nodeCell(s % mazeCols, s / mazeCols)
        carved[c] = true
        base[c] = 0.35
        headCell = c

        bfsParent = []
        bfsFrontier = []
        pathCells = []
        traceIdx = 0
        tipCell = -1
        holdLeft = 0
        dissolveList = []
        dissolveFramesLeft = 0
        phase = .generating
        // Solve corner-to-corner: top-left node to bottom-right node
        // (display y grows upward; visually this is bottom-left -> top-right,
        // an equivalent diagonal crossing).
        startNode = 0
        goalNode = mazeCols * mazeRows - 1
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

    // MARK: - Simulation phases

    /// Carve with an iterative recursive backtracker; ~3-6 fresh cells/frame.
    private func stepGenerate() {
        let targetCells = 3 + randInt(4)
        var carvedThisFrame = 0
        var ops = 0
        while carvedThisFrame < targetCells && ops < 80 {
            ops += 1
            guard let cur = stack.last else {
                // Maze complete: move to the solving phase.
                phase = .solving
                let m = mazeCols * mazeRows
                bfsParent = .init(repeating: -2, count: m)  // -2 = unvisited
                bfsParent[startNode] = -1                    // -1 = root
                bfsFrontier = [startNode]
                let c = nodeCell(startNode % mazeCols, startNode / mazeCols)
                base[c] = max(base[c], 0.45)
                headCell = -1
                return
            }
            let mx = cur % mazeCols, my = cur / mazeCols
            // Collect unvisited lattice neighbours.
            var choices: [(Int, Int)] = []   // (neighbor node, wall display cell)
            let deltas = [(1, 0), (-1, 0), (0, 1), (0, -1)]
            for (dx, dy) in deltas {
                let nx = mx + dx, ny = my + dy
                guard nx >= 0, nx < mazeCols, ny >= 0, ny < mazeRows else { continue }
                let nn = ny * mazeCols + nx
                if !visited[nn] {
                    let wall = (offY + 2 * my + 1 + dy) * cols + (offX + 2 * mx + 1 + dx)
                    choices.append((nn, wall))
                }
            }
            if choices.isEmpty {
                stack.removeLast()
                if let top = stack.last {
                    headCell = nodeCell(top % mazeCols, top / mazeCols)
                }
                continue
            }
            let (next, wall) = choices[randInt(choices.count)]
            visited[next] = true
            stack.append(next)
            let nc = nodeCell(next % mazeCols, next / mazeCols)
            for c in [wall, nc] {
                carved[c] = true
                base[c] = 0.35
                flash[c] = 0.70
            }
            headCell = nc
            carvedThisFrame += 2
        }
    }

    /// Expand the BFS frontier a few layers per frame, painting visited
    /// passages faintly brighter, until the goal is reached.
    private func stepSolve() {
        let layersPerFrame = 3
        for _ in 0..<layersPerFrame {
            guard !bfsFrontier.isEmpty else { break }
            var nextFrontier: [Int] = []
            var reached = false
            for node in bfsFrontier {
                let mx = node % mazeCols, my = node / mazeCols
                let deltas = [(1, 0), (-1, 0), (0, 1), (0, -1)]
                for (dx, dy) in deltas {
                    let nx = mx + dx, ny = my + dy
                    guard nx >= 0, nx < mazeCols, ny >= 0, ny < mazeRows else { continue }
                    let nn = ny * mazeCols + nx
                    guard bfsParent[nn] == -2 else { continue }
                    let wall = (offY + 2 * my + 1 + dy) * cols + (offX + 2 * mx + 1 + dx)
                    guard carved[wall] else { continue }   // no opening here
                    bfsParent[nn] = Int32(node)
                    base[wall] = max(base[wall], 0.45)
                    let nc = nodeCell(nx, ny)
                    base[nc] = max(base[nc], 0.45)
                    nextFrontier.append(nn)
                    if nn == goalNode { reached = true }
                }
            }
            bfsFrontier = nextFrontier
            if reached {
                buildPath()
                phase = .tracing
                traceIdx = 0
                return
            }
        }
        if bfsFrontier.isEmpty && phase == .solving {
            // Should not happen in a perfect maze, but never stall.
            buildPath()
            phase = pathCells.isEmpty ? .holding : .tracing
            holdLeft = Int(4 * config.fps)
        }
    }

    /// Reconstruct goal->start via parents, then list display cells start->goal.
    private func buildPath() {
        guard bfsParent.indices.contains(goalNode), bfsParent[goalNode] != -2 else {
            pathCells = []
            return
        }
        var nodes: [Int] = []
        var cur = goalNode
        while cur != -1 {
            nodes.append(cur)
            cur = Int(bfsParent[cur])
            if nodes.count > mazeCols * mazeRows + 1 { break }   // safety
        }
        nodes.reverse()
        pathCells = []
        pathCells.reserveCapacity(nodes.count * 2)
        for (i, node) in nodes.enumerated() {
            let mx = node % mazeCols, my = node / mazeCols
            if i > 0 {
                let prev = nodes[i - 1]
                let px = prev % mazeCols, py = prev / mazeCols
                let wall = (offY + py + my + 1) * cols + (offX + px + mx + 1)
                pathCells.append(wall)
            }
            pathCells.append(nodeCell(mx, my))
        }
    }

    /// Light the solution path ~8 cells per frame, start to goal.
    private func stepTrace() {
        let perFrame = 8
        var lit = 0
        while traceIdx < pathCells.count && lit < perFrame {
            let c = pathCells[traceIdx]
            base[c] = 0.90
            isPath[c] = true
            tipCell = c
            traceIdx += 1
            lit += 1
        }
        if traceIdx >= pathCells.count {
            phase = .holding
            holdLeft = Int(4 * config.fps)
            tipCell = -1
        }
    }

    private func stepHold() {
        holdLeft -= 1
        if holdLeft <= 0 {
            // Gather every lit cell and dissolve them in random order.
            // "Lit" means above the configurable wall floor.
            let floorB = CGFloat(config.floor)
            dissolveList = (0..<(cols * rows)).filter { base[$0] > floorB + 0.02 }
            for i in stride(from: dissolveList.count - 1, to: 0, by: -1) {
                let j = randInt(i + 1)
                dissolveList.swapAt(i, j)
            }
            dissolveFramesLeft = max(1, Int(1.5 * config.fps))
            phase = .dissolving
        }
    }

    private func stepDissolve() {
        guard dissolveFramesLeft > 0 else {
            resetMaze()
            return
        }
        let perFrame = max(1, dissolveList.count / dissolveFramesLeft)
        for _ in 0..<perFrame {
            guard let c = dissolveList.popLast() else { break }
            base[c] = CGFloat(config.floor)
            flash[c] = 0
            isPath[c] = false
        }
        dissolveFramesLeft -= 1
        if dissolveList.isEmpty {
            resetMaze()
        }
    }

    // MARK: - Frame

    public override func animateOneFrame() {
        if levelColors.isEmpty || base.count != cols * rows { rebuildGrid() }
        tick += 1
        pulsePhase += 0.12

        switch phase {
        case .generating: stepGenerate()
        case .solving:    stepSolve()
        case .tracing:    stepTrace()
        case .holding:    stepHold()
        case .dissolving: stepDissolve()
        }

        // Fresh-carve flashes settle back toward the passage brightness.
        for i in 0..<flash.count where flash[i] > 0 {
            flash[i] -= 0.06
            if flash[i] < 0.36 { flash[i] = 0 }
        }
        needsDisplay = true
    }

    /// Harness only: current phase, for offline snapshot pacing.
    @objc public var debugPhaseName: String {
        switch phase {
        case .generating: return "generating"
        case .solving:    return "solving"
        case .tracing:    return "tracing"
        case .holding:    return "holding"
        case .dissolving: return "dissolving"
        }
    }

    // MARK: - Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if levelColors.isEmpty || base.count != cols * rows { rebuildGrid() }
        if floorImage == nil { rebuildFloorImage() }

        // 1) Blit the pre-rendered floor (bg gradient + empty lattice); the
        // per-cell loop below then skips every cell still at the floor level.
        let skipFloor: Bool
        if let floorImage {
            ctx.draw(floorImage, in: bounds)
            skipFloor = true
        } else {
            drawBackground(ctx)   // degenerate bounds: keep the old path
            skipFloor = false
        }

        let holding = phase == .holding
        let pulse = 0.84 + 0.13 * sin(pulsePhase)
        let corner = cellSide * 0.28
        let half = cellSide / 2

        // 2) Group dynamic cells by quantized color (ramp bank
        // 0..<colorLevels, accent bank colorLevels..<2*colorLevels).
        // Bloomed cells are few and need the shadow, so they are drawn
        // individually on top via drawCell().
        var byColor = [[CGPoint]](repeating: [], count: colorLevels * 2)
        var bloomCells: [(x: CGFloat, y: CGFloat, color: NSColor)] = []

        for j in 0..<rows {
            let cy = originY + CGFloat(j) * pitch
            let rowBase = j * cols
            for i in 0..<cols {
                let idx = rowBase + i
                var b = base[idx]
                if holding && isPath[idx] { b = pulse }
                if flash[idx] > b { b = flash[idx] }
                var bloomCell = false
                if config.bloom {
                    if idx == headCell && phase == .generating {
                        b = 1.0; bloomCell = true
                    } else if idx == tipCell && phase == .tracing {
                        b = 1.0; bloomCell = true
                    } else if flash[idx] >= 0.62 {
                        bloomCell = true
                    }
                }
                let lvl = min(colorLevels - 1,
                              max(0, Int(b * CGFloat(colorLevels - 1))))
                let onPath = isPath[idx]
                let cx = originX + CGFloat(i) * pitch
                if bloomCell {
                    bloomCells.append((cx, cy,
                                       onPath ? accentColors[lvl] : levelColors[lvl]))
                    continue
                }
                if skipFloor && !onPath && lvl == floorLevel { continue }
                byColor[onPath ? colorLevels + lvl : lvl]
                    .append(CGPoint(x: cx, y: cy))
            }
        }

        // 3) One fill per color level. Normal-sized groups build ONE
        // compound CGPath and fill it with a single call (this covers every
        // frame at the default pitch). Very large groups -- only possible at
        // small pitch, e.g. ~5k carved cells sharing a level at pitch 8 --
        // stamp a pre-rendered sprite instead: CG compound-path filling
        // measured ~2.4 us/cell here vs ~0.45 us/cell for sprite blits,
        // which is the difference between ~32 ms and <10 ms per frame.
        for key in byColor.indices {
            let pts = byColor[key]
            if pts.isEmpty { continue }
            if pts.count > Self.spriteThreshold, key < cellSprites.count,
               let sprite = cellSprites[key] {
                let w = CGFloat(sprite.width) / spriteScale
                let h = CGFloat(sprite.height) / spriteScale
                for p in pts {
                    ctx.draw(sprite, in: CGRect(x: p.x - half, y: p.y - half,
                                                width: w, height: h))
                }
            } else {
                let batch = CGMutablePath()
                for p in pts {
                    batch.addPath(CGPath(
                        roundedRect: CGRect(x: p.x - half, y: p.y - half,
                                            width: cellSide, height: cellSide),
                        cornerWidth: corner, cornerHeight: corner,
                        transform: nil))
                }
                let color = key < colorLevels ? levelColors[key]
                                              : accentColors[key - colorLevels]
                ctx.setFillColor(color.cgColor)
                ctx.addPath(batch)
                ctx.fillPath()
            }
        }
        for cell in bloomCells {
            drawCell(ctx, x: cell.x, y: cell.y, color: cell.color, bloom: true)
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
        panel.title = "Labirinto"
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

        let bloom = NSButton(checkboxWithTitle: "Brilho (bloom) na cabeça e no caminho",
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
        NotificationCenter.default.post(name: .mazeConfigChanged, object: nil)
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
