import AppKit
import ScreenSaver
import IOKit.ps

private extension Notification.Name {
    static let batteryConfigChanged = Notification.Name("UltracodeBatteryConfigChanged")
}

@objc(UltracodeBatteryView)
public final class UltracodeBatteryView: ScreenSaverView {

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

    // Fixed Apple-standard battery colors — no theme option on this saver.
    // Green = normal charge / charging, yellow = Low Power Mode,
    // red = low battery (<= 20%).
    private static let greenStops: [UInt32] = [
        0x2F3A31, 0x2C4A33, 0x2C633C, 0x2F8447,
        0x34A854, 0x30D158, 0x7FE89A, 0xD6FFDE,
    ]
    private static let yellowStops: [UInt32] = [
        0x3A372C, 0x4C4428, 0x685B29, 0x8A782D,
        0xB59B33, 0xE0BE3F, 0xFFD60A, 0xFFF3B0,
    ]
    private static let redStops: [UInt32] = [
        0x3A2C2B, 0x55241F, 0x782A22, 0xA23128,
        0xCC3A2F, 0xFF453A, 0xFF8A7A, 0xFFD2C9,
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
        var pitch: Double = 26
        var fps: Double = 30
        var floor: Double = 0.10
        var bloom = true
    }

    private static let moduleName = "com.williansaez.ultracode-battery"

    private static func makeDefaults() -> ScreenSaverDefaults? {
        let d = ScreenSaverDefaults(forModuleWithName: moduleName)
        d?.register(defaults: [
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

    private var greenColors: [NSColor] = []
    private var yellowColors: [NSColor] = []
    private var redColors: [NSColor] = []
    private var floorColor = RGB(0x34313A).color   // neutral empty-cell color (scales with config.floor)
    private let colorLevels = 32

    // Pre-rendered empty lattice (bg gradient + every cell at the floor
    // color), blitted once per frame instead of filling thousands of
    // floor cells individually. Rebuilt by rebuildGrid().
    private var floorImage: CGImage?

    // Pre-rendered LIT lattice (bg gradient + every cell at the solid lit
    // color of the active palette). The charge gauge is a contiguous block
    // of identical cells, so the lit region is one clipped blit of this
    // image — CoreGraphics' CPU rasterizer fills ~20k rounded-rect subpaths
    // at ~15 µs/cell, but blits the same area in ~0.2 ms. Built lazily and
    // cached per palette (green/yellow/red switch only on state changes).
    private var litImage: CGImage?
    private var litImagePalette = -1   // 0 = green, 1 = yellow, 2 = red

    // MARK: - Battery state

    // The grid is a solid, linear charge gauge: cells light bottom-to-top,
    // row by row (left-to-right within the boundary row), exactly to the
    // battery's level — each cell is one fixed slice of charge, so cells
    // visibly switch off one by one as the battery drains and back on as it
    // charges. While charging, the next cell to light pulses. Below 20% the
    // lit cells recolor amber and breathe as a warning.

    private var targetPct: Float = 1.0     // latest reading (1% steps from IOKit)
    private var shownPct: Float = 1.0       // glides toward target continuously
    private var charging = false
    private var lowPowerMode = false
    private var overridePct: Float? = nil   // harness only
    private var overrideLPM: Bool? = nil    // harness only
    private var phase: Float = 0
    private var frameCount = 0
    private let pollEvery = 120             // re-read battery every N frames (~4s)

    // macOS reports charge in whole-percent steps, but 1% spans several
    // cells, so snapping to each reading kills cells in batches and the
    // boundary fade is never seen. Instead shownPct GLIDES between readings
    // at the battery's estimated real drain/charge rate, so cells die one
    // by one and the boundary cell visibly loses color through its slice.
    private var glideRatePerSec: Float = 0.01 / 120   // default: 1% per 2 min
    private var prevTarget: Float = -1
    private var lastTargetChange = CFAbsoluteTimeGetCurrent()

    // Dying-bulb flicker for the cell that's next to turn off while
    // discharging: jittery brightness with short random dropouts.
    private var flicker: CGFloat = 1
    private var dropoutFrames = 0

    private var rngState: UInt64 = 0x9E3779B97F4A7C15
    private func nextRand() -> UInt64 {
        rngState ^= rngState << 13
        rngState ^= rngState >> 7
        rngState ^= rngState << 17
        return rngState
    }
    private func rand01() -> CGFloat { CGFloat(nextRand() & 0xFFFFFF) / CGFloat(0x1000000) }

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
            name: .batteryConfigChanged, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func configChanged() {
        loadConfig()
        rebuildGrid()
        needsDisplay = true
    }

    // MARK: - Battery read

    /// Fine-grained read from the AppleSmartBattery IORegistry service:
    /// raw capacity in mAh (~0.02% steps) instead of the whole-percent
    /// IOPS API. "Charging" here means plugged in (ExternalConnected).
    private func readSmartBattery() -> (Float, Bool)? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        func prop(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(
                service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        guard let cur = prop("AppleRawCurrentCapacity") as? Int,
              let mx = prop("AppleRawMaxCapacity") as? Int, mx > 0 else { return nil }
        let plugged = (prop("ExternalConnected") as? Bool) ?? false
        return (min(1, max(0, Float(cur) / Float(mx))), plugged)
    }

    /// Coarse fallback (whole-percent steps) via IOPS power sources.
    private func readBattery() -> (Float, Bool)? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, ps)?
                    .takeUnretainedValue() as? [String: Any] else { continue }
            guard let cur = desc[kIOPSCurrentCapacityKey as String] as? Int,
                  let mx = desc[kIOPSMaxCapacityKey as String] as? Int, mx > 0
            else { continue }
            let pct = min(1, max(0, Float(cur) / Float(mx)))
            let state = desc[kIOPSPowerSourceStateKey as String] as? String
            let charging = (state == (kIOPSACPowerValue as String))
            return (pct, charging)
        }
        return nil
    }

    private func refreshBattery() {
        lowPowerMode = overrideLPM ?? ProcessInfo.processInfo.isLowPowerModeEnabled
        if let o = overridePct { targetPct = o; return }
        if let (pct, chg) = readSmartBattery() ?? readBattery() {
            targetPct = pct
            charging = chg
        } else {
            // Desktop / no battery: show a full, plugged-in grid.
            targetPct = 1.0
            charging = true
        }
        updateGlideRate()
    }

    /// Estimate the real drain/charge speed from consecutive 1%-step
    /// readings, so the glide tracks reality.
    private func updateGlideRate() {
        let now = CFAbsoluteTimeGetCurrent()
        if prevTarget < 0 {
            prevTarget = targetPct
            lastTargetChange = now
            return
        }
        let dPct = abs(targetPct - prevTarget)
        guard dPct > 0.0005 else { return }
        let dT = Float(now - lastTargetChange)
        if dT > 1 {
            let r = dPct / dT
            // Clamp: 1% per 10 min .. 1% per 10 s.
            glideRatePerSec = min(max(r, 0.01 / 600), 0.01 / 10)
        }
        prevTarget = targetPct
        lastTargetChange = now
    }

    // MARK: - Layout

    private func rebuildGrid() {
        pitch = isPreview ? 9 : CGFloat(config.pitch)
        cellSide = pitch * 0.70
        cols = max(4, Int(bounds.width / pitch) + 1)
        rows = max(4, Int(bounds.height / pitch) + 1)
        originX = (bounds.width - CGFloat(cols - 1) * pitch) / 2
        originY = (bounds.height - CGFloat(rows - 1) * pitch) / 2

        let f = CGFloat(config.floor)
        func buildColors(_ hexStops: [UInt32]) -> [NSColor] {
            let stops = hexStops.map(RGB.init)
            return (0..<colorLevels).map { l in
                let b = f + (1 - f) * CGFloat(l) / CGFloat(colorLevels - 1)
                return ramp(b, stops: stops).color
            }
        }
        greenColors = buildColors(Self.greenStops)
        yellowColors = buildColors(Self.yellowStops)
        redColors = buildColors(Self.redStops)

        // Neutral empty-cell floor follows the configured floor level: at 0
        // it equals bgTop (grid invisible), and at the default 0.10 the lerp
        // lands EXACTLY on the legacy 0x34313A.
        floorColor = RGB.lerp(RGB(0x232126), RGB(0x676176),
                              min(max(f * 2.5, 0), 1)).color
        rebuildFloorImage()
        litImage = nil
        litImagePalette = -1

        refreshBattery()
        shownPct = targetPct
    }

    /// Renders the entire lattice (background gradient + all cells at the
    /// given color) into a Retina-scale CGImage.
    private func renderLattice(cellColor: NSColor) -> CGImage? {
        let w = bounds.width, h = bounds.height
        guard w >= 1, h >= 1 else { return nil }
        let scale = window?.backingScaleFactor ?? 2
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil,
                                  width: Int(w * scale), height: Int(h * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.scaleBy(x: scale, y: scale)

        // Background gradient — identical to drawBackground().
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

        // Every cell at the given color. Cells are filled per-cell: the CPU
        // rasterizer's fast path beats one giant multi-subpath fill here.
        let corner = cellSide * 0.28
        ctx.setFillColor(cellColor.cgColor)
        for j in 0..<rows {
            let cy = originY + CGFloat(j) * pitch
            for i in 0..<cols {
                let cx = originX + CGFloat(i) * pitch
                let rect = CGRect(x: cx - cellSide / 2, y: cy - cellSide / 2,
                                  width: cellSide, height: cellSide)
                ctx.addPath(CGPath(roundedRect: rect, cornerWidth: corner,
                                   cornerHeight: corner, transform: nil))
                ctx.fillPath()
            }
        }
        return ctx.makeImage()
    }

    /// Pre-renders the empty lattice. draw(_:) blits it as the first step,
    /// so per-frame work covers only the lit cells.
    private func rebuildFloorImage() {
        floorImage = renderLattice(cellColor: floorColor)
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
        if greenColors.isEmpty { rebuildGrid() }
        frameCount += 1
        phase += 0.06
        if frameCount % pollEvery == 0 { refreshBattery() }

        // Glide toward the target at the estimated real rate: cells die or
        // light ONE BY ONE and the boundary cell fades through its slice.
        // Big jumps (startup, plug/unplug) catch up quickly instead.
        let diff = targetPct - shownPct
        if abs(diff) > 0.04 {
            shownPct += diff * 0.08
        } else if diff != 0 {
            let step = glideRatePerSec * Float(animationTimeInterval)
            shownPct += diff > 0 ? min(diff, step) : max(diff, -step)
        }

        // Dying-bulb flicker: mostly bright but jittery, with occasional
        // short dropouts to near-dark — like a tube about to burn out.
        if dropoutFrames > 0 {
            dropoutFrames -= 1
            flicker = 0.10 + rand01() * 0.15
        } else {
            flicker = 0.60 + rand01() * 0.40
            if rand01() < 0.07 { dropoutFrames = 1 + Int(rand01() * 4) }
        }

        needsDisplay = true
    }

    /// Harness only: pin the battery level/charging for snapshots.
    @objc public func debugSetBattery(_ pct: Float, charging chg: Bool) {
        overridePct = pct
        targetPct = pct
        shownPct = pct
        charging = chg
    }

    /// Harness only: pin Low Power Mode for snapshots.
    @objc public func debugSetLowPower(_ on: Bool) {
        overrideLPM = on
        lowPowerMode = on
    }

    /// Harness only: move the target WITHOUT snapping shownPct, to exercise
    /// the glide path.
    @objc public func debugSetTarget(_ pct: Float) {
        overridePct = pct
        targetPct = pct
    }

    /// Harness only.
    @objc public func debugShownPct() -> Float { shownPct }

    // MARK: - Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if greenColors.isEmpty { rebuildGrid() }
        if floorImage == nil { rebuildFloorImage() }

        // One blit paints the background gradient AND every cell at the
        // empty floor color; only lit cells are drawn on top of it.
        if let floor = floorImage {
            ctx.draw(floor, in: bounds)
        } else {
            drawBackground(ctx)
        }

        // Apple-standard state colors: red <= 20%, yellow in Low Power Mode,
        // green otherwise (including while charging).
        let low = shownPct <= 0.20
        let paletteIndex = low ? 2 : (lowPowerMode ? 1 : 0)
        let palette = low ? redColors : (lowPowerMode ? yellowColors : greenColors)
        let f = CGFloat(config.floor)

        // Solid linear gauge: each cell is one fixed slice of charge, always
        // at FULL brightness while lit. The boundary cell burns solid until
        // its slice is nearly spent, then flickers like a dying bulb for the
        // last stretch and switches off.
        let total = cols * rows
        guard total > 0 else { return }
        let exact = CGFloat(shownPct) * CGFloat(total)
        let fullCells = min(total, Int(exact))
        let frac = min(1, max(0, exact - CGFloat(fullCells)))
        // While charging, the cell currently filling pulses on and off.
        let chargePulse = CGFloat(0.18 + 0.62 * (0.5 + 0.5 * sin(phase * 2.6)))

        // The solid fill (cells 0..<fullCells, all at the same lit color) is
        // a contiguous block of full rows plus part of one row: blit the
        // pre-rendered lit lattice clipped to exactly that region. The clip
        // edges run through the gaps between cells and the lit image carries
        // the same background gradient, so no seams or cut cells appear.
        // (CG's CPU rasterizer fills ~20k rounded-rect subpaths at ~15 µs
        // each — batched path fills cannot reach 60 fps here; blits can.)
        let solidLevel = min(colorLevels - 1,
                             max(0, Int(0.82 * CGFloat(colorLevels - 1))))
        var firstDynamic = 0    // first cell index NOT covered by the lit blit
        if fullCells > 0 {
            if litImage == nil || litImagePalette != paletteIndex {
                litImage = renderLattice(cellColor: palette[solidLevel])
                litImagePalette = paletteIndex
            }
            if let lit = litImage {
                let fullRows = fullCells / cols     // rows completely lit
                let partial = fullCells % cols      // lit cells in row fullRows
                let yCut = min(bounds.height,
                               max(0, originY + (CGFloat(fullRows) - 0.5) * pitch))
                var clip: [CGRect] = []
                if fullRows > 0 {
                    clip.append(CGRect(x: 0, y: 0,
                                       width: bounds.width, height: yCut))
                }
                if partial > 0 {
                    let xCut = min(bounds.width,
                                   max(0, originX + (CGFloat(partial) - 0.5) * pitch))
                    clip.append(CGRect(x: 0, y: yCut, width: xCut, height: pitch))
                }
                if !clip.isEmpty {
                    ctx.saveGState()
                    ctx.clip(to: clip)
                    ctx.draw(lit, in: bounds)
                    ctx.restoreGState()
                }
                firstDynamic = fullCells
            }
        }

        // Remaining dynamic cells — normally just the boundary cell (or the
        // whole solid block if the lit image could not be built): batched
        // into ONE fill path per quantized color level instead of one path
        // fill per cell. Cells at the floor level are skipped (the floor
        // blit already shows them); bloomed cells are drawn individually on
        // top, after the batched fills.
        var levelPaths: [Int: CGMutablePath] = [:]
        var bloomCells: [(x: CGFloat, y: CGFloat, color: NSColor)] = []
        let corner = cellSide * 0.28
        let lastDynamic = min(fullCells, total - 1)

        // n = fill order index (row 0 = bottom).
        for n in stride(from: firstDynamic, through: lastDynamic, by: 1) {
            let i = n % cols
            let j = n / cols
            let cx = originX + CGFloat(i) * pitch
            let cy = originY + CGFloat(j) * pitch

            var b: CGFloat
            var glow = false
            if n < fullCells {
                b = 0.82                    // solid, always full brightness
            } else if n == fullCells && n < total {
                if charging {
                    b = chargePulse         // cell "charging in"
                    glow = true
                } else if frac > 0.30 {
                    b = 0.82                // still burning solid
                } else {
                    // Last stretch of the slice: dying-bulb flicker,
                    // then out.
                    b = 0.82 * flicker
                    glow = flicker > 0.75
                }
            } else {
                b = f                       // empty (configured floor)
            }

            // Empty cells keep the neutral dark floor; the state color
            // applies only to lit cells.
            let isFloor = b <= f + 0.02
            let color = isFloor ? floorColor
                : palette[min(colorLevels - 1, max(0, Int(b * CGFloat(colorLevels - 1))))]
            // Bloom only on the boundary cell — blooming the whole solid
            // fill would mean thousands of shadows per frame. Bloomed cells
            // are drawn individually, on top, after the batched fills.
            if config.bloom && glow {
                bloomCells.append((cx, cy, color))
            } else if !isFloor {
                let level = min(colorLevels - 1,
                                max(0, Int(b * CGFloat(colorLevels - 1))))
                let rect = CGRect(x: cx - cellSide / 2, y: cy - cellSide / 2,
                                  width: cellSide, height: cellSide)
                let cell = CGPath(roundedRect: rect, cornerWidth: corner,
                                  cornerHeight: corner, transform: nil)
                if let path = levelPaths[level] {
                    path.addPath(cell)
                } else {
                    let path = CGMutablePath()
                    path.addPath(cell)
                    levelPaths[level] = path
                }
            }
        }

        for (level, path) in levelPaths {
            ctx.setFillColor(palette[level].cgColor)
            ctx.addPath(path)
            ctx.fillPath()
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
    private var pitchSlider: NSSlider?
    private var fpsSlider: NSSlider?
    private var floorSlider: NSSlider?
    private var bloomCheck: NSButton?
    private var pitchDetentValues: [Double] = []

    /// Pitches in [8, 80] where the gauge grid has NO cut cells on the main
    /// screen. Grid math is untouched (cols = Int(w/p)+1, centered): edge
    /// cells stay fully inside whenever the fractional parts of w/p and h/p
    /// are >= the cell-side fraction (0.7). Scan that condition and take the
    /// center of each valid band as a slider detent.
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

        // Fixed frames, no autolayout (legacyScreenSaver presents the sheet
        // remotely before any layout pass; autolayout panels collapse there).
        // No theme row: this saver always uses the Apple battery colors.
        let W: CGFloat = 440, H: CGFloat = 214
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                            styleMask: [.titled],
                            backing: .buffered, defer: false)
        panel.title = "Bateria"
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

        // Detented spacing slider: only positions with no cut cells.
        let detents = Self.pitchDetents()
        pitchDetentValues = detents
        let nearest = detents.enumerated().min {
            abs($0.element - config.pitch) < abs($1.element - config.pitch)
        }!.offset
        _ = label("Espaçamento da grelha:", row: 166)
        let pSlider = slider(Double(nearest), 0, Double(detents.count - 1), row: 166)
        pSlider.numberOfTickMarks = detents.count
        pSlider.allowsTickMarkValuesOnly = true
        _ = label("Velocidade (fps):", row: 128)
        let fSlider = slider(config.fps, 15, 60, row: 128)
        _ = label("Brilho do fundo:", row: 90)
        let flSlider = slider(config.floor, 0.0, 0.30, row: 90)

        let bloom = NSButton(checkboxWithTitle: "Brilho (bloom) nas células cheias",
                             target: nil, action: nil)
        bloom.state = config.bloom ? .on : .off
        bloom.frame = NSRect(x: 180, y: 58, width: 248, height: 20)
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
        pitchSlider = pSlider
        fpsSlider = fSlider
        floorSlider = flSlider
        bloomCheck = bloom
        return panel
    }

    @objc private func sheetOK(_ sender: Any?) {
        if let d = Self.makeDefaults() {
            // The pitch slider carries a detent INDEX; translate to points.
            let idx = Int((pitchSlider?.doubleValue ?? 0).rounded())
            let pitch = pitchDetentValues.indices.contains(idx)
                ? pitchDetentValues[idx] : 26.0
            d.set(pitch, forKey: "pitch")
            d.set(fpsSlider?.doubleValue ?? 30.0, forKey: "fps")
            d.set(floorSlider?.doubleValue ?? 0.10, forKey: "floorLevel")
            d.set(bloomCheck?.state == .on, forKey: "bloom")
            d.synchronize()
        }
        NotificationCenter.default.post(name: .batteryConfigChanged, object: nil)
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
