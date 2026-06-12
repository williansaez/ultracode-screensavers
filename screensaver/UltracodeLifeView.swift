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

    /// Pre-rendered empty lattice (bg gradient + every cell at floor
    /// brightness), kept as a CGImage (single blit in the fallback path)
    /// and as raw pixels (bulk-copied by the compositor fast path).
    private var floorImage: CGImage?

    // MARK: Software compositor caches
    //
    // At pitch 8 the lattice has ~24k cells and any per-cell CoreGraphics
    // call (path fill, CGLayer stamp, image stamp) costs 1-25 us -- far
    // over a 16 ms frame budget. The fast path composes the frame in a
    // pixel buffer instead: floor pixels are bulk-copied, dynamic cells
    // are stamped from small pre-rendered tiles (one per quantized color
    // level), and the finished frame is drawn with a single ctx.draw.
    // Bloom halos are alpha-blended into a half-resolution overlay (a
    // Gaussian halo survives upsampling) and composited with one more draw.
    private var fbScale: CGFloat = 2
    private var fbW = 0, fbH = 0
    private var bufSpace: CGColorSpace?     // working space of all buffers
    private var floorPixels: [UInt8] = []   // RGBA premultiplied
    private var frameBuf: [UInt8] = []
    private var coreTiles: [UInt8] = []     // flat: alive levels then trail levels
    private var coreTileCount = 0
    private var tilePx = 0
    private var tileSpans: [(lo: Int, hi: Int)] = []   // non-empty px per tile row
    private var cellPxX: [Int] = []         // tile origin per column (device px)
    private var cellPxY: [Int] = []         // tile origin per row (top-down px)
    private let haloScale: CGFloat = 0.5
    private var haloW = 0, haloH = 0
    private var haloBuf: [UInt8] = []
    private var haloTiles: [UInt8] = []     // flat, indexed by newborn age (0 unused)
    private var haloTilePx = 0
    private var haloPxX: [Int] = []
    private var haloPxY: [Int] = []

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

        rebuildRenderCaches()
        reseed()
    }

    // MARK: - Render caches

    /// Buffers are rendered and tagged in the destination's color space when
    /// the view is attached to a window: a full-screen color conversion per
    /// composite costs several ms per frame otherwise.
    private func compositorSpace() -> CGColorSpace {
        if let s = window?.colorSpace?.cgColorSpace, s.model == .rgb,
           s.numberOfComponents == 3,
           CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                     bytesPerRow: 4, space: s,
                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) != nil {
            return s
        }
        return CGColorSpace(name: CGColorSpace.sRGB)!
    }

    private func rebuildRenderCaches() {
        bufSpace = compositorSpace()
        rebuildFloorImage()
        rebuildCoreTiles()
        rebuildHaloTiles()
        rebuildPixelTables()
        frameBuf = floorPixels.isEmpty
            ? [] : [UInt8](repeating: 0, count: floorPixels.count)
        haloBuf = (haloW > 0 && haloH > 0 && !haloTiles.isEmpty)
            ? [UInt8](repeating: 0, count: haloW * haloH * 4) : []
    }

    /// Renders the entire empty lattice (background gradient + floor cells)
    /// once at Retina scale. Rebuilt with the grid, so resize and the
    /// "Brilho do fundo" slider keep working.
    private func rebuildFloorImage() {
        floorImage = nil
        floorPixels = []
        let w = bounds.width, h = bounds.height
        guard w >= 1, h >= 1 else { return }
        fbScale = window?.backingScaleFactor ?? 2
        fbW = Int((w * fbScale).rounded())
        fbH = Int((h * fbScale).rounded())
        var pixels = [UInt8](repeating: 0, count: fbW * fbH * 4)
        let ok: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let space = bufSpace,
                  let ctx = CGContext(data: raw.baseAddress,
                                      width: fbW, height: fbH,
                                      bitsPerComponent: 8, bytesPerRow: fbW * 4,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.scaleBy(x: fbScale, y: fbScale)

            // Same gradient as drawBackground.
            let colors = [bgTop.color.cgColor, bgBottom.color.cgColor] as CFArray
            if let grad = CGGradient(colorsSpace: space, colors: colors,
                                     locations: [0, 1]) {
                ctx.drawLinearGradient(grad,
                                       start: CGPoint(x: 0, y: h),
                                       end: CGPoint(x: 0, y: 0),
                                       options: [])
            } else {
                ctx.setFillColor(bgTop.color.cgColor)
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            }

            // Every cell at floor brightness.
            let r = cellSide * 0.28
            ctx.setFillColor(floorColor.cgColor)
            for j in 0..<rows {
                let cy = originY + CGFloat(j) * pitch
                for i in 0..<cols {
                    let cx = originX + CGFloat(i) * pitch
                    ctx.addPath(CGPath(roundedRect: CGRect(x: cx - cellSide / 2,
                                                           y: cy - cellSide / 2,
                                                           width: cellSide,
                                                           height: cellSide),
                                       cornerWidth: r, cornerHeight: r,
                                       transform: nil))
                    ctx.fillPath()
                }
            }
            floorImage = ctx.makeImage()
            return true
        }
        if ok { floorPixels = pixels }
    }

    /// One small RGBA tile per quantized color level (alive ages then trail
    /// steps): the same rounded rect drawCell fills, pre-rendered at Retina
    /// scale with 1 pt of padding for the antialiased edge.
    private func rebuildCoreTiles() {
        coreTiles = []
        tileSpans = []
        coreTileCount = 0
        let pad: CGFloat = 1
        let sidePt = cellSide + 2 * pad
        tilePx = Int((sidePt * fbScale).rounded(.up))
        guard tilePx > 0, fbW > 0, let space = bufSpace else { return }
        let r = cellSide * 0.28
        let levels = aliveColors + trailColors
        let stride = tilePx * tilePx * 4
        var tiles = [UInt8](repeating: 0, count: levels.count * stride)
        let ok: Bool = tiles.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return false }
            for (idx, color) in levels.enumerated() {
                guard let ctx = CGContext(data: base + idx * stride,
                                          width: tilePx, height: tilePx,
                                          bitsPerComponent: 8, bytesPerRow: tilePx * 4,
                                          space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return false }
                ctx.scaleBy(x: fbScale, y: fbScale)
                ctx.setFillColor(color.cgColor)
                ctx.addPath(CGPath(roundedRect: CGRect(x: pad, y: pad,
                                                       width: cellSide,
                                                       height: cellSide),
                                   cornerWidth: r, cornerHeight: r, transform: nil))
                ctx.fillPath()
            }
            return true
        }
        guard ok else { return }
        coreTiles = tiles
        coreTileCount = levels.count
        // All levels share the alpha shape; cache each row's covered span.
        tileSpans = (0..<tilePx).map { ty in
            var lo = -1, hi = 0
            for tx in 0..<tilePx where tiles[(ty * tilePx + tx) * 4 + 3] != 0 {
                if lo < 0 { lo = tx }
                hi = tx + 1
            }
            return (max(lo, 0), hi)
        }
    }

    /// Bloom tiles per newborn age: the exact drawCell(bloom: true) render
    /// (rounded cell + shadow halo), pre-rendered at half resolution -- a
    /// Gaussian halo survives the upsample. NB: CG shadow blur is specified
    /// in device space, so it is scaled by the tile's device scale to match
    /// the look of the direct render.
    private func rebuildHaloTiles() {
        haloTiles = []
        haloTilePx = 0
        haloW = 0
        haloH = 0
        let w = bounds.width, h = bounds.height
        guard w >= 1, h >= 1, aliveColors.count > 2,
              let space = bufSpace else { return }
        let blur = cellSide * 1.2
        let margin = blur * 1.5 + 1   // halo alpha is ~0 beyond ~1.0x blur
        let sidePt = cellSide + 2 * margin
        let px = Int((sidePt * haloScale).rounded(.up))
        guard px > 0 else { return }
        let r = cellSide * 0.28
        let stride = px * px * 4
        var tiles = [UInt8](repeating: 0, count: 3 * stride)   // age 0 unused
        let ok: Bool = tiles.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return false }
            for age in 1...2 {
                guard let ctx = CGContext(data: base + age * stride,
                                          width: px, height: px,
                                          bitsPerComponent: 8, bytesPerRow: px * 4,
                                          space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return false }
                ctx.scaleBy(x: haloScale, y: haloScale)
                let color = aliveColors[age]
                ctx.setShadow(offset: .zero, blur: blur * haloScale,
                              color: color.withAlphaComponent(0.8).cgColor)
                ctx.setFillColor(color.cgColor)
                ctx.addPath(CGPath(roundedRect: CGRect(x: margin, y: margin,
                                                       width: cellSide,
                                                       height: cellSide),
                                   cornerWidth: r, cornerHeight: r, transform: nil))
                ctx.fillPath()
            }
            return true
        }
        guard ok else { return }
        haloTiles = tiles
        haloTilePx = px
        haloW = Int((w * haloScale).rounded(.up))
        haloH = Int((h * haloScale).rounded(.up))
    }

    /// Per-column / per-row tile origins in device pixels (top-down rows,
    /// matching CGImage memory order).
    private func rebuildPixelTables() {
        let h = bounds.height
        let tHalf = CGFloat(tilePx) / 2
        let hHalf = CGFloat(haloTilePx) / 2
        cellPxX = (0..<cols).map {
            Int(((originX + CGFloat($0) * pitch) * fbScale - tHalf).rounded())
        }
        cellPxY = (0..<rows).map {
            Int(((h - (originY + CGFloat($0) * pitch)) * fbScale - tHalf).rounded())
        }
        haloPxX = (0..<cols).map {
            Int(((originX + CGFloat($0) * pitch) * haloScale - hHalf).rounded())
        }
        haloPxY = (0..<rows).map {
            Int(((h - (originY + CGFloat($0) * pitch)) * haloScale - hHalf).rounded())
        }
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
        if state.isEmpty || floorImage == nil { rebuildGrid() }

        guard !frameBuf.isEmpty, !coreTiles.isEmpty,
              frameBuf.count == floorPixels.count else {
            drawLegacy(ctx)
            return
        }

        // 1. Compose the frame in the pixel buffer: floor blit (bulk copy
        //    of the pre-rendered lattice), then dynamic cells stamped from
        //    their per-color-level tiles. Cells at the floor level are
        //    skipped -- the copy already shows them.
        var bloomCells: [(i: Int, j: Int, age: Int)] = []
        let aliveLevelCount = aliveColors.count
        let bloomOn = config.bloom

        frameBuf.withUnsafeMutableBytes { rawFrame in
            guard let fBase = rawFrame.baseAddress else { return }
            _ = floorPixels.withUnsafeBytes { rawFloor in
                memcpy(fBase, rawFloor.baseAddress!, rawFloor.count)
            }
            let f = fBase.assumingMemoryBound(to: UInt8.self)
            coreTiles.withUnsafeBytes { rawTiles in
                let tiles = rawTiles.baseAddress!.assumingMemoryBound(to: UInt8.self)
                for j in 0..<rows {
                    let py = cellPxY[j]
                    if py + tilePx <= 0 || py >= fbH { continue }
                    let rowBase = j * cols
                    for i in 0..<cols {
                        let s = state[rowBase + i]
                        if s == 0 { continue }
                        let level: Int
                        if s > 0 {
                            level = min(s, aliveAgeCap)
                            if bloomOn && s <= 2 { bloomCells.append((i, j, s)) }
                        } else {
                            level = aliveLevelCount + min(-s, trailLength) - 1
                        }
                        stampCore(f, tiles, level: level, px: cellPxX[i], py: py)
                    }
                }
            }
        }

        // 2. One draw for the whole lattice.
        drawPixelBuffer(ctx, frameBuf, width: fbW, height: fbH,
                        scale: fbScale, opaque: true)

        // 3. Bloomed newborns on top: their halos are blended into the
        //    half-resolution overlay and composited in one draw.
        guard !bloomCells.isEmpty else { return }
        if haloBuf.isEmpty || haloTiles.isEmpty {
            for c in bloomCells {
                drawCell(ctx,
                         x: originX + CGFloat(c.i) * pitch,
                         y: originY + CGFloat(c.j) * pitch,
                         color: aliveColors[min(c.age, aliveAgeCap)], bloom: true)
            }
            return
        }
        haloBuf.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            memset(base, 0, raw.count)
            let h = base.assumingMemoryBound(to: UInt8.self)
            haloTiles.withUnsafeBytes { rawTiles in
                let tiles = rawTiles.baseAddress!.assumingMemoryBound(to: UInt8.self)
                for c in bloomCells {
                    stampHalo(h, tiles, age: c.age,
                              px: haloPxX[c.i], py: haloPxY[c.j])
                }
            }
        }
        drawPixelBuffer(ctx, haloBuf, width: haloW, height: haloH,
                        scale: haloScale, opaque: false)
    }

    /// Stamps one cell tile into the frame buffer. Opaque pixels are stored
    /// directly; antialiased edge pixels are src-over blended (premultiplied).
    private func stampCore(_ f: UnsafeMutablePointer<UInt8>,
                           _ tiles: UnsafePointer<UInt8>,
                           level: Int, px: Int, py: Int) {
        if px + tilePx <= 0 || px >= fbW { return }
        let t = tiles + level * tilePx * tilePx * 4
        let ty0 = max(0, -py), ty1 = min(tilePx, fbH - py)
        for ty in ty0..<ty1 {
            var lo = tileSpans[ty].lo, hi = tileSpans[ty].hi
            if px + lo < 0 { lo = -px }
            if px + hi > fbW { hi = fbW - px }
            if lo >= hi { continue }
            let dRow = ((py + ty) * fbW + px) << 2
            let tRow = (ty * tilePx) << 2
            for tx in lo..<hi {
                let ti = tRow + (tx << 2)
                let sa = t[ti + 3]
                if sa == 255 {
                    let v = UnsafeRawPointer(t + ti).load(as: UInt32.self)
                    UnsafeMutableRawPointer(f + dRow + (tx << 2))
                        .storeBytes(of: v, as: UInt32.self)
                } else if sa != 0 {
                    let di = dRow + (tx << 2)
                    let inv = UInt16(255 - sa)
                    f[di]     = t[ti]     &+ UInt8((UInt16(f[di])     &* inv) / 255)
                    f[di + 1] = t[ti + 1] &+ UInt8((UInt16(f[di + 1]) &* inv) / 255)
                    f[di + 2] = t[ti + 2] &+ UInt8((UInt16(f[di + 2]) &* inv) / 255)
                    f[di + 3] = 255
                }
            }
        }
    }

    /// Src-over blends one bloom tile into the halo overlay buffer.
    private func stampHalo(_ h: UnsafeMutablePointer<UInt8>,
                           _ tiles: UnsafePointer<UInt8>,
                           age: Int, px: Int, py: Int) {
        if px + haloTilePx <= 0 || px >= haloW { return }
        let t = tiles + age * haloTilePx * haloTilePx * 4
        let ty0 = max(0, -py), ty1 = min(haloTilePx, haloH - py)
        let tx0 = max(0, -px), tx1 = min(haloTilePx, haloW - px)
        for ty in ty0..<ty1 {
            let dRow = ((py + ty) * haloW + px) << 2
            let tRow = (ty * haloTilePx) << 2
            for tx in tx0..<tx1 {
                let ti = tRow + (tx << 2)
                let sa = t[ti + 3]
                if sa == 0 { continue }
                let di = dRow + (tx << 2)
                if sa == 255 {
                    let v = UnsafeRawPointer(t + ti).load(as: UInt32.self)
                    UnsafeMutableRawPointer(h + di).storeBytes(of: v, as: UInt32.self)
                } else {
                    let inv = UInt16(255 - sa)
                    h[di]     = t[ti]     &+ UInt8((UInt16(h[di])     &* inv) / 255)
                    h[di + 1] = t[ti + 1] &+ UInt8((UInt16(h[di + 1]) &* inv) / 255)
                    h[di + 2] = t[ti + 2] &+ UInt8((UInt16(h[di + 2]) &* inv) / 255)
                    h[di + 3] = t[ti + 3] &+ UInt8((UInt16(h[di + 3]) &* inv) / 255)
                }
            }
        }
    }

    /// Wraps a pixel buffer in a no-copy CGImage and draws it, top-aligned,
    /// scaled back to points.
    private func drawPixelBuffer(_ ctx: CGContext, _ buf: [UInt8],
                                 width: Int, height: Int, scale: CGFloat,
                                 opaque: Bool) {
        guard width > 0, height > 0, buf.count >= width * height * 4,
              let space = bufSpace else { return }
        buf.withUnsafeBytes { raw in
            guard let base = raw.baseAddress,
                  let data = CFDataCreateWithBytesNoCopy(
                      kCFAllocatorDefault,
                      base.assumingMemoryBound(to: UInt8.self),
                      raw.count, kCFAllocatorNull),
                  let provider = CGDataProvider(data: data) else { return }
            let info = opaque
                ? CGImageAlphaInfo.noneSkipLast.rawValue
                : CGImageAlphaInfo.premultipliedLast.rawValue
            guard let img = CGImage(width: width, height: height,
                                    bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: width * 4, space: space,
                                    bitmapInfo: CGBitmapInfo(rawValue: info),
                                    provider: provider, decode: nil,
                                    shouldInterpolate: true,
                                    intent: .defaultIntent) else { return }
            let wPt = CGFloat(width) / scale, hPt = CGFloat(height) / scale
            ctx.draw(img, in: CGRect(x: 0, y: bounds.height - hPt,
                                     width: wPt, height: hPt))
        }
    }

    /// Original per-cell path, used only if the compositor buffers could
    /// not be built (e.g. zero-sized bounds).
    private func drawLegacy(_ ctx: CGContext) {
        if let floorImage {
            ctx.draw(floorImage, in: bounds)
        } else {
            drawBackground(ctx)
        }
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
                } else if floorImage == nil {
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
