import AppKit
import ScreenSaver

private extension Notification.Name {
    static let cpuConfigChanged = Notification.Name("UltracodeCPUConfigChanged")
}

@objc(UltracodeCPUView)
public final class UltracodeCPUView: ScreenSaverView {

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
        var floor: Double = 0.10
        var bloom = true
    }

    private static let moduleName = "com.williansaez.ultracode-cpu"

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

    /// Pre-rendered empty lattice (background gradient + every cell at the
    /// floor brightness), built once per rebuildGrid() at Retina scale and
    /// blitted as the first drawing step of every frame.
    private var floorImage: CGImage?
    private var floorImageScale: CGFloat = 0

    /// Pre-rendered cell sprite per quantized color level. Dynamic cells
    /// are drawn as one pixel-aligned image blit each instead of a path
    /// fill: CG path filling degrades badly when one path holds many
    /// subpaths sharing scanlines (the per-level "bands" this saver
    /// produces), while aligned blits of a cached raster are ~5x faster
    /// than even individual fills. Cleared whenever the grid rebuilds.
    private var cellSprites: [Int: CGImage] = [:]
    private var cellSpriteMargin: CGFloat = 0
    private var cellSpriteSide: CGFloat = 0

    /// Pre-rendered glow sprite (shadow + cell body) per quantized color
    /// level, so bloomed cells become one image blit each instead of a
    /// per-cell CG shadow pass. Cleared whenever the grid rebuilds.
    private var bloomSprites: [Int: CGImage] = [:]
    private var bloomSpriteMargin: CGFloat = 0
    private var bloomSpriteSide: CGFloat = 0

    // MARK: - CPU state

    // One bar per core; each fills bottom-to-top to that core's live load.
    // Cores spike independently every sample, so the wall of bars is in
    // constant motion. The waterline ripples and the crest glows, like the
    // battery saver but driven by the processor.

    private var targetLoads: [Float] = []   // latest per-core load
    private var shownLoads: [Float] = []     // eased for smooth bars
    private var prevUsed: [UInt64] = []
    private var prevTotal: [UInt64] = []
    private var overrideLoads: [Float]? = nil
    private var phase: Float = 0
    private var frameCount = 0
    private let pollEvery = 8                // re-sample CPU every N frames

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
            name: .cpuConfigChanged, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func configChanged() {
        loadConfig()
        rebuildGrid()
        needsDisplay = true
    }

    // MARK: - CPU sampling (mach host_processor_info)

    private func sampleCPU() -> [Float] {
        var info: processor_info_array_t?
        var infoCnt: mach_msg_type_number_t = 0
        var cpuCount: natural_t = 0
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                     &cpuCount, &info, &infoCnt)
        guard kr == KERN_SUCCESS, let info = info else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(infoCnt) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        let n = Int(cpuCount)
        if prevUsed.count != n {
            prevUsed = .init(repeating: 0, count: n)
            prevTotal = .init(repeating: 0, count: n)
        }
        var loads = [Float](repeating: 0, count: n)
        let ptr = UnsafeBufferPointer(start: info, count: Int(infoCnt))
        let stride = Int(CPU_STATE_MAX)
        for i in 0..<n {
            let base = i * stride
            let user = UInt64(UInt32(bitPattern: ptr[base + Int(CPU_STATE_USER)]))
            let sys  = UInt64(UInt32(bitPattern: ptr[base + Int(CPU_STATE_SYSTEM)]))
            let nice = UInt64(UInt32(bitPattern: ptr[base + Int(CPU_STATE_NICE)]))
            let idle = UInt64(UInt32(bitPattern: ptr[base + Int(CPU_STATE_IDLE)]))
            let used = user + sys + nice
            let total = used + idle
            let du = used >= prevUsed[i] ? used - prevUsed[i] : 0
            let dt = total >= prevTotal[i] ? total - prevTotal[i] : 0
            loads[i] = dt > 0 ? min(1, Float(du) / Float(dt)) : 0
            prevUsed[i] = used; prevTotal[i] = total
        }
        return loads
    }

    private func refreshCPU() {
        if let o = overrideLoads { targetLoads = o; return }
        let loads = sampleCPU()
        if !loads.isEmpty { targetLoads = loads }
        if shownLoads.count != targetLoads.count {
            shownLoads = targetLoads
        }
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

        rebuildFloorImage()

        // Prime the CPU counters so the first visible sample is a real delta.
        _ = sampleCPU()
        refreshCPU()
        shownLoads = targetLoads
    }

    /// Render the entire empty lattice (gradient + floor cells) once into a
    /// CGImage so draw(_:) can blit it instead of filling thousands of
    /// floor cells per frame. Rebuilt by rebuildGrid() on resize/config
    /// change, so the "Brilho do fundo" slider keeps working. Built at the
    /// destination scale (the window's backing scale, or the actual context
    /// scale detected in draw) so the blit is a 1:1 pixel copy.
    private func rebuildFloorImage(scale targetScale: CGFloat? = nil) {
        floorImage = nil
        cellSprites.removeAll()
        bloomSprites.removeAll()
        let scale = targetScale ?? (window?.backingScaleFactor ?? 2)
        floorImageScale = scale
        let pw = Int(bounds.width * scale)
        let ph = Int(bounds.height * scale)
        guard pw > 0, ph > 0, !levelColors.isEmpty,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pw, height: ph,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        ctx.scaleBy(x: scale, y: scale)

        // Same gradient as drawBackground().
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

        // Every cell at the floor color, quantized exactly like the old
        // per-cell path did (b = floor -> level index into levelColors).
        let f = CGFloat(config.floor)
        let floorLvl = min(colorLevels - 1, max(0, Int(f * CGFloat(colorLevels - 1))))
        let radius = cellSide * 0.28
        let path = CGMutablePath()
        for i in 0..<cols {
            let cx = originX + CGFloat(i) * pitch
            for j in 0..<rows {
                let cy = originY + CGFloat(j) * pitch
                path.addRoundedRect(in: CGRect(x: cx - cellSide / 2,
                                               y: cy - cellSide / 2,
                                               width: cellSide,
                                               height: cellSide),
                                    cornerWidth: radius, cornerHeight: radius)
            }
        }
        ctx.setFillColor(levelColors[floorLvl].cgColor)
        ctx.addPath(path)
        ctx.fillPath()
        floorImage = ctx.makeImage()
    }

    /// Plain rounded-rect cell body for the given level, rendered once into
    /// a transparent image and blitted (pixel-aligned) per dynamic cell.
    private func cellSprite(level: Int) -> CGImage? {
        if let s = cellSprites[level] { return s }
        let scale = floorImageScale > 0 ? floorImageScale : 2
        let margin: CGFloat = 1 // room for the antialiased edge
        let side = cellSide + margin * 2
        let px = Int(ceil(side * scale))
        guard px > 0, level >= 0, level < levelColors.count,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let c = CGContext(data: nil, width: px, height: px,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        c.scaleBy(x: scale, y: scale)
        c.setFillColor(levelColors[level].cgColor)
        let path = CGMutablePath()
        path.addRoundedRect(in: CGRect(x: margin, y: margin,
                                       width: cellSide, height: cellSide),
                            cornerWidth: cellSide * 0.28,
                            cornerHeight: cellSide * 0.28)
        c.addPath(path)
        c.fillPath()
        guard let img = c.makeImage() else { return nil }
        cellSpriteMargin = margin
        cellSpriteSide = CGFloat(px) / scale
        cellSprites[level] = img
        return img
    }

    /// Shadow + cell body for a bloomed cell of the given level, rendered
    /// once into a transparent image. Per-cell blits of this sprite
    /// composite exactly like the per-cell shadow fills they replace
    /// (source-over is associative), but cost a fraction of a CG shadow
    /// pass each. Built lazily, cached until the next grid rebuild.
    private func bloomSprite(level: Int) -> CGImage? {
        if let s = bloomSprites[level] { return s }
        let scale = floorImageScale > 0 ? floorImageScale : 2
        let blur = cellSide * 1.2
        let margin = ceil(blur * 1.6)
        let side = cellSide + margin * 2
        let px = Int(ceil(side * scale))
        guard px > 0, level >= 0, level < levelColors.count,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let c = CGContext(data: nil, width: px, height: px,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        c.scaleBy(x: scale, y: scale)
        let color = levelColors[level]
        c.setShadow(offset: .zero, blur: blur,
                    color: color.withAlphaComponent(0.8).cgColor)
        c.setFillColor(color.cgColor)
        let path = CGMutablePath()
        path.addRoundedRect(in: CGRect(x: margin, y: margin,
                                       width: cellSide, height: cellSide),
                            cornerWidth: cellSide * 0.28,
                            cornerHeight: cellSide * 0.28)
        c.addPath(path)
        c.fillPath()
        guard let img = c.makeImage() else { return nil }
        bloomSpriteMargin = margin
        bloomSpriteSide = CGFloat(px) / scale
        bloomSprites[level] = img
        return img
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
        if levelColors.isEmpty { rebuildGrid() }
        frameCount += 1
        phase += 0.08
        if frameCount % pollEvery == 0 { refreshCPU() }
        // Ease each bar toward its target load for fluid motion.
        if shownLoads.count == targetLoads.count {
            for i in 0..<shownLoads.count {
                shownLoads[i] += (targetLoads[i] - shownLoads[i]) * 0.18
            }
        } else {
            shownLoads = targetLoads
        }
        needsDisplay = true
    }

    /// Harness only: pin per-core loads for snapshots.
    @objc public func debugSetLoads(_ loads: [Float]) {
        overrideLoads = loads
        targetLoads = loads
        shownLoads = loads
    }

    // MARK: - Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if levelColors.isEmpty { rebuildGrid() }

        // Match the cached images to the actual destination scale so the
        // blits are 1:1 pixel copies (no per-frame resampling).
        let devScale = abs(ctx.convertToDeviceSpace(CGSize(width: 0, height: 1)).height)
        let scale = devScale > 0.01 ? devScale : 2
        if floorImage == nil || abs(floorImageScale - scale) > 0.001 {
            rebuildFloorImage(scale: scale)
        }

        // Blit the pre-rendered empty lattice (gradient + floor cells) in
        // one call instead of filling thousands of floor cells.
        if let floorImage {
            ctx.draw(floorImage, in: bounds)
        } else {
            drawBackground(ctx)
        }

        let nCores = max(1, shownLoads.count)
        let bloomLevel = Int(CGFloat(colorLevels - 1) * 0.80)

        // Dynamic (non-floor) cells are grouped by their quantized color
        // level and drawn as pixel-aligned blits of one cached sprite per
        // level. Bloomed cells are collected and drawn ON TOP at the end
        // (their glow must layer above the cell bodies).
        var bloomCells: [(x: CGFloat, y: CGFloat, lvl: Int)] = []

        for i in 0..<cols {
            let cx = originX + CGFloat(i) * pitch
            // Which core this column belongs to.
            let core = min(nCores - 1, i * nCores / cols)
            let load = shownLoads.isEmpty ? 0 : shownLoads[core]
            let level = load * Float(rows)

            // Per-column ripple on the waterline; a busy core ripples harder.
            let amp = 0.25 + 0.45 * load
            let wob = amp * sin(Float(i) * 0.7 + phase * 2.0 + Float(core) * 1.3)
            let surface = level + (load > 0.001 && load < 0.999 ? wob : 0)

            for j in 0..<rows {
                let jf = Float(j)

                var b: CGFloat
                var isSurface = false
                if jf <= surface - 1 {
                    let depth = surface > 0.001 ? CGFloat(jf / surface) : 0
                    b = 0.50 + 0.42 * depth
                } else if jf < surface {
                    b = 1.0
                    isSurface = true
                } else {
                    // Floor: the blit already shows it, and every cell above
                    // this one in the column is floor too.
                    break
                }
                let cy = originY + CGFloat(j) * pitch
                let lvl = min(colorLevels - 1, max(0, Int(b * CGFloat(colorLevels - 1))))
                if config.bloom && (isSurface || lvl >= bloomLevel) {
                    bloomCells.append((x: cx, y: cy, lvl: lvl))
                } else if let sprite = cellSprite(level: lvl) {
                    // Align the blit to the device pixel grid so CG takes
                    // its fast (non-interpolating) path. The shift is at
                    // most half a device pixel, uniform across the grid.
                    let dx = ((cx - cellSide / 2 - cellSpriteMargin) * scale).rounded() / scale
                    let dy = ((cy - cellSide / 2 - cellSpriteMargin) * scale).rounded() / scale
                    ctx.draw(sprite, in: CGRect(x: dx, y: dy,
                                                width: cellSpriteSide,
                                                height: cellSpriteSide))
                } else {
                    drawCell(ctx, x: cx, y: cy, color: levelColors[lvl], bloom: false)
                }
            }
        }

        for c in bloomCells {
            if let sprite = bloomSprite(level: c.lvl) {
                let dx = ((c.x - cellSide / 2 - bloomSpriteMargin) * scale).rounded() / scale
                let dy = ((c.y - cellSide / 2 - bloomSpriteMargin) * scale).rounded() / scale
                ctx.draw(sprite, in: CGRect(x: dx, y: dy,
                                            width: bloomSpriteSide,
                                            height: bloomSpriteSide))
            } else {
                drawCell(ctx, x: c.x, y: c.y, color: levelColors[c.lvl], bloom: true)
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
        panel.title = "Processador"
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

        let bloom = NSButton(checkboxWithTitle: "Brilho (bloom) na crista das barras",
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
        NotificationCenter.default.post(name: .cpuConfigChanged, object: nil)
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
