import Accelerate
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
    // CGColor twins of levelColors for the batched per-level CG fills.
    private var levelCGColors: [CGColor] = []
    // Pre-rendered empty lattice (bg gradient + every cell at floor
    // brightness). Blitted once per frame instead of filling thousands
    // of floor cells individually. Rebuilt by rebuildGrid(), so it
    // tracks resizes and the "Brilho do fundo" slider.
    private var floorImage: CGImage?

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
        levelCGColors = levelColors.map(\.cgColor)
        rebuildFloorImage()
        rebuildSprites()
    }

    /// Renders the whole empty lattice (background gradient + every cell
    /// at floor brightness) into a Retina-scale CGImage, once per grid
    /// rebuild. draw(_:) blits it as its first step.
    private func rebuildFloorImage() {
        floorImage = nil
        let w = bounds.width, h = bounds.height
        guard w >= 1, h >= 1, !levelCGColors.isEmpty,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return }
        let scale = window?.backingScaleFactor ?? 2
        guard let ctx = CGContext(
            data: nil,
            width: Int(w * scale), height: Int(h * scale),
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        ctx.scaleBy(x: scale, y: scale)

        // Same background gradient as drawBackground().
        let colors = [bgTop.color.cgColor, bgBottom.color.cgColor] as CFArray
        if let grad = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(grad,
                                   start: CGPoint(x: 0, y: h),
                                   end: CGPoint(x: 0, y: 0),
                                   options: [])
        } else {
            ctx.setFillColor(bgTop.color.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }

        // Every cell at floor brightness, batched into a single fill.
        let radius = cellSide * 0.28
        let path = CGMutablePath()
        for j in 0..<rows {
            let cy = originY + CGFloat(j) * pitch
            for i in 0..<cols {
                let cx = originX + CGFloat(i) * pitch
                path.addPath(CGPath(
                    roundedRect: CGRect(x: cx - cellSide / 2, y: cy - cellSide / 2,
                                        width: cellSide, height: cellSide),
                    cornerWidth: radius, cornerHeight: radius, transform: nil))
            }
        }
        ctx.setFillColor(levelCGColors[0])
        ctx.addPath(path)
        ctx.fillPath()

        floorImage = ctx.makeImage()
    }

    // MARK: - Sprite compositor

    // The dynamic cells are batched by quantized heat level: each level
    // gets ONE pre-rendered sprite tile (rounded cell at the level color;
    // bloom levels additionally get a body+glow tile with the CG shadow
    // baked in), kept as raw premultiplied-RGBA pixels at backing scale.
    // draw() composites the frame's dynamic cells into a reusable scratch
    // buffer on the CPU (vImage premultiplied alpha-over, in the exact
    // row-major order of the old per-cell CG fills — "over" is associative,
    // so compositing into the buffer first and blitting once is pixel-
    // equivalent) and then draws the composite with a single CG blit.
    // Rationale: per-cell CG path fills measure ~4 us/cell and per-cell
    // shadowed bloom draws ~16 us/cell (~90 ms/frame total at pitch 8);
    // the CPU compositor brings the same image to a few ms.
    private final class SpriteTile {
        let ctx: CGContext            // owns the pixel storage
        let data: UnsafeMutableRawPointer
        let w: Int, h: Int, rowBytes: Int
        let padPx: Int                // margin around the cell box (glow spill)
        init?(sidePx: CGFloat, phaseX: CGFloat, phaseY: CGFloat, padPx: Int,
              draw: (CGContext, CGRect) -> Void) {
            let w = padPx * 2 + Int((phaseX + sidePx).rounded(.up)) + 1
            let h = padPx * 2 + Int((phaseY + sidePx).rounded(.up)) + 1
            guard w > 0, h > 0,
                  let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let c = CGContext(
                      data: nil, width: w, height: h,
                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let d = c.data else { return nil }
            draw(c, CGRect(x: CGFloat(padPx) + phaseX, y: CGFloat(padPx) + phaseY,
                           width: sidePx, height: sidePx))
            self.ctx = c; self.data = d; self.w = w; self.h = h
            self.rowBytes = c.bytesPerRow; self.padPx = padPx
        }
    }

    private var cellSprites: [SpriteTile?] = []
    private var bloomSprites: [SpriteTile?] = []
    private var frameBuf: [UInt8] = []
    private var bufW = 0
    private var bufH = 0
    private var bufScale: CGFloat = 2

    private func rebuildSprites() {
        cellSprites = []
        bloomSprites = []
        frameBuf = []
        guard !levelCGColors.isEmpty, bounds.width >= 1, bounds.height >= 1 else { return }
        let scale = window?.backingScaleFactor ?? 2
        bufScale = scale
        bufW = Int(bounds.width * scale)
        bufH = Int(bounds.height * scale)
        guard bufW > 0, bufH > 0 else { return }

        let sidePx = cellSide * scale
        let radiusPx = cellSide * 0.28 * scale
        // Sub-pixel phase of cell (0,0)'s box, baked into the tiles so the
        // integer-pixel stamping lands exactly where the CG path fills did.
        // (pitch*scale is integral for the slider detents, so the phase is
        // shared by every cell; for fractional pitches the drift stays
        // under one device pixel.)
        let phaseX = ((originX - cellSide / 2) * scale).truncatingRemainder(dividingBy: 1)
        let phaseY = ((originY - cellSide / 2) * scale).truncatingRemainder(dividingBy: 1)
        let px = phaseX < 0 ? phaseX + 1 : phaseX
        let py = phaseY < 0 ? phaseY + 1 : phaseY

        let bloomCut = Int(CGFloat(levels - 1) * 0.82)
        let blurPx = cellSide * 1.2 * scale
        let bloomPadPx = Int((blurPx * 2).rounded(.up)) + 1

        cellSprites = (0..<levels).map { h in
            SpriteTile(sidePx: sidePx, phaseX: px, phaseY: py, padPx: 0) { c, rect in
                c.setFillColor(self.levelCGColors[h])
                c.addPath(CGPath(roundedRect: rect, cornerWidth: radiusPx,
                                 cornerHeight: radiusPx, transform: nil))
                c.fillPath()
            }
        }
        bloomSprites = (0..<levels).map { h in
            guard h >= bloomCut else { return nil }
            return SpriteTile(sidePx: sidePx, phaseX: px, phaseY: py,
                              padPx: bloomPadPx) { c, rect in
                c.setShadow(offset: .zero, blur: blurPx,
                            color: self.levelColors[h].withAlphaComponent(0.8).cgColor)
                c.setFillColor(self.levelCGColors[h])
                c.addPath(CGPath(roundedRect: rect, cornerWidth: radiusPx,
                                 cornerHeight: radiusPx, transform: nil))
                c.fillPath()
            }
        }
        if cellSprites.contains(where: { $0 == nil }) {
            // Sprite build failed; draw() falls back to per-cell paths.
            cellSprites = []
            bloomSprites = []
            return
        }
        frameBuf = [UInt8](repeating: 0, count: bufW * bufH * 4)
    }

    /// Alpha-over blend of one tile into the scratch buffer at integer
    /// device-pixel coordinates, clipped to the buffer width and to the
    /// row band cleared for this frame.
    private func stamp(_ tile: SpriteTile, x: Int, topRow: Int,
                       rowLo: Int, rowHi: Int,
                       base: UnsafeMutableRawPointer) {
        var sx = 0, sy = 0, w = tile.w, h = tile.h, dx = x, dy = topRow
        if dx < 0 { sx = -dx; w += dx; dx = 0 }
        if dy < rowLo { sy = rowLo - dy; h -= rowLo - dy; dy = rowLo }
        if dx + w > bufW { w = bufW - dx }
        if dy + h > rowHi { h = rowHi - dy }
        guard w > 0, h > 0 else { return }
        var src = vImage_Buffer(data: tile.data + sy * tile.rowBytes + sx * 4,
                                height: vImagePixelCount(h),
                                width: vImagePixelCount(w),
                                rowBytes: tile.rowBytes)
        var dst = vImage_Buffer(data: base + (dy * bufW + dx) * 4,
                                height: vImagePixelCount(h),
                                width: vImagePixelCount(w),
                                rowBytes: bufW * 4)
        // _BGRA8888 == the C macro vImagePremultipliedAlphaBlend_RGBA8888:
        // the premultiplied over-blend only cares that alpha is byte 3.
        vImagePremultipliedAlphaBlend_BGRA8888(&src, &dst, &dst,
                                               vImage_Flags(kvImageNoFlags))
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
        if heat.isEmpty || floorImage == nil { rebuildGrid() }

        // 1. Floor: one blit of the pre-rendered empty lattice replaces the
        //    background gradient plus thousands of floor-cell fills. Both
        //    the view's context and the image are bottom-up, so no flip.
        if let floorImage {
            ctx.draw(floorImage, in: bounds)
        } else {
            drawBackground(ctx)   // degenerate bounds; keep the bg at least
        }

        let bloomCut = Int(CGFloat(levels - 1) * 0.82)

        // Fallback (sprite build failed): classic one-path-per-cell drawing
        // for the dynamic cells, floor cells still come from the blit.
        guard !cellSprites.isEmpty, !frameBuf.isEmpty else {
            for j in 0..<rows {
                let cy = originY + CGFloat(j) * pitch
                let rowBase = j * cols
                for i in 0..<cols {
                    let h = min(heat[rowBase + i], levels - 1)
                    if h == 0 { continue }
                    drawCell(ctx, x: originX + CGFloat(i) * pitch, y: cy,
                             color: levelColors[h],
                             bloom: config.bloom && h >= bloomCut)
                }
            }
            return
        }

        // 2. Dynamic cells (anything brighter than the floor), batched by
        //    quantized level via the sprite compositor. Cells at the floor
        //    level are skipped (the blit already shows them). First find
        //    the affected row band so only that part of the scratch buffer
        //    is cleared, composited and re-blitted.
        var minJ = Int.max, maxJ = Int.min
        for j in 0..<rows {
            let rowBase = j * cols
            for i in 0..<cols where heat[rowBase + i] > 0 {
                if j < minJ { minJ = j }
                maxJ = j
                break
            }
        }
        guard minJ <= maxJ else { return }   // everything sits at the floor

        let s = bufScale
        let cellHalf = cellSide / 2
        let padPx = config.bloom ? (bloomSprites.compactMap { $0 }.first?.padPx ?? 0) : 0
        let loPt = originY + CGFloat(minJ) * pitch - cellHalf
        let hiPt = originY + CGFloat(maxJ) * pitch + cellHalf
        let ry0 = max(0, bufH - Int((hiPt * s).rounded(.up)) - padPx - 3)
        let ry1 = min(bufH, bufH - Int((loPt * s).rounded(.down)) + padPx + 3)
        guard ry0 < ry1 else { return }
        let bandH = ry1 - ry0

        frameBuf.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            memset(base + ry0 * bufW * 4, 0, bandH * bufW * 4)

            // Same row-major order as the old per-cell draws; premultiplied
            // alpha-over is associative, so the final single blit composites
            // exactly like the individual draws did (bloom glows included,
            // ON TOP of the plain cells they overlap).
            for j in minJ...maxJ {
                let cy = originY + CGFloat(j) * pitch
                let pyBottom = Int(((cy - cellHalf) * s).rounded(.down))
                let rowBase = j * cols
                for i in 0..<cols {
                    let h = min(heat[rowBase + i], levels - 1)
                    if h == 0 { continue }
                    let cx = originX + CGFloat(i) * pitch
                    let pxLeft = Int(((cx - cellHalf) * s).rounded(.down))
                    var tile: SpriteTile? = cellSprites[h]
                    if config.bloom && h >= bloomCut, let b = bloomSprites[h] {
                        tile = b
                    }
                    guard let tile else { continue }
                    stamp(tile, x: pxLeft - tile.padPx,
                          topRow: bufH - (pyBottom - tile.padPx) - tile.h,
                          rowLo: ry0, rowHi: ry1, base: base)
                }
            }

            // 3. One blit of the composited band, on top of the floor.
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let provider = CGDataProvider(
                      dataInfo: nil, data: base + ry0 * bufW * 4,
                      size: bandH * bufW * 4, releaseData: { _, _, _ in }),
                  let img = CGImage(
                      width: bufW, height: bandH,
                      bitsPerComponent: 8, bitsPerPixel: 32,
                      bytesPerRow: bufW * 4, space: space,
                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                      provider: provider, decode: nil,
                      shouldInterpolate: false, intent: .defaultIntent)
            else { return }
            ctx.draw(img, in: CGRect(x: 0, y: CGFloat(bufH - ry1) / s,
                                     width: CGFloat(bufW) / s,
                                     height: CGFloat(bandH) / s))
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
