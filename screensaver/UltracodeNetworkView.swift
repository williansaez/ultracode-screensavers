import AppKit
import Darwin
import ScreenSaver

private extension Notification.Name {
    static let netConfigChanged = Notification.Name("UltracodeNetworkConfigChanged")
}

@objc(UltracodeNetworkView)
public final class UltracodeNetworkView: ScreenSaverView {

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

    // MARK: - User configuration

    private struct Config {
        var theme = 0
        var pitch: Double = 26
        var fps: Double = 30
        var floor: Double = 0.10
        var bloom = true
    }

    private static let moduleName = "com.williansaez.ultracode-network"

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

    // MARK: - Network state

    // Digital rain driven by real traffic: download spawns streams falling
    // from the top, upload spawns streams rising from the bottom. Stream
    // density and speed scale with live throughput (log scale, KB/s..GB/s).
    // Heads are bright and deposit into a decaying trail grid, so each
    // stream drags a fading tail. Idle network = sparse drizzle; a download
    // = a dense cascade.

    private struct Drop {
        var col: Int
        var y: Float       // row position (float for smooth motion)
        var speed: Float   // rows per frame
        var up: Bool       // false = download (falls), true = upload (rises)
    }
    private var drops: [Drop] = []
    private var trail: [Float] = []      // display-grid brightness, decays

    private var prevIn: UInt64 = 0
    private var prevOut: UInt64 = 0
    private var havePrev = false
    private var downRate: Float = 0      // bytes/sec, smoothed
    private var upRate: Float = 0
    private var overrideRates: (Float, Float)? = nil
    private var lastSample = CFAbsoluteTimeGetCurrent()
    private var frameCount = 0
    private let pollEvery = 15           // re-read counters every N frames (~0.5s)
    private let trailDecay: Float = 0.84

    private var rngState: UInt64 = 0xD1B54A32D192ED03
    private func nextRand() -> UInt64 {
        rngState ^= rngState << 13
        rngState ^= rngState >> 7
        rngState ^= rngState << 17
        return rngState
    }
    private func rand01() -> Float { Float(nextRand() & 0xFFFFFF) / Float(0x1000000) }

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
            name: .netConfigChanged, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func configChanged() {
        loadConfig()
        rebuildGrid()
        needsDisplay = true
    }

    // MARK: - Traffic counters (getifaddrs)

    /// Total in/out bytes across all non-loopback interfaces.
    private func readCounters() -> (UInt64, UInt64) {
        var totalIn: UInt64 = 0, totalOut: UInt64 = 0
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return (0, 0) }
        defer { freeifaddrs(addrs) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            defer { p = cur.pointee.ifa_next }
            guard let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_LINK),
                  let dataPtr = cur.pointee.ifa_data else { continue }
            let name = String(cString: cur.pointee.ifa_name)
            if name.hasPrefix("lo") { continue }
            let data = dataPtr.assumingMemoryBound(to: if_data.self).pointee
            totalIn &+= UInt64(data.ifi_ibytes)
            totalOut &+= UInt64(data.ifi_obytes)
        }
        return (totalIn, totalOut)
    }

    private func refreshRates() {
        if let (d, u) = overrideRates { downRate = d; upRate = u; return }
        let now = CFAbsoluteTimeGetCurrent()
        let dt = Float(max(0.05, now - lastSample))
        let (inB, outB) = readCounters()
        if havePrev {
            // Counters are 32-bit on many interfaces and wrap; ignore negatives.
            let dIn = inB >= prevIn ? Float(inB - prevIn) : 0
            let dOut = outB >= prevOut ? Float(outB - prevOut) : 0
            // Smooth so single bursts don't flicker.
            downRate += (dIn / dt - downRate) * 0.5
            upRate += (dOut / dt - upRate) * 0.5
        }
        prevIn = inB; prevOut = outB
        havePrev = true
        lastSample = now
    }

    /// bytes/sec -> 0..1 on a log scale: ~10 KB/s registers, ~50 MB/s saturates.
    private func rate01(_ r: Float) -> Float {
        if r < 1024 { return 0 }
        let v = log10(r / 1024)          // 0 at 1 KB/s
        return min(1, max(0, v / 4.7))   // 1 at ~50 MB/s
    }

    // MARK: - Layout

    private func rebuildGrid() {
        pitch = isPreview ? 9 : CGFloat(config.pitch)
        cellSide = pitch * 0.70
        cols = max(4, Int(bounds.width / pitch) + 1)
        rows = max(4, Int(bounds.height / pitch) + 1)
        originX = (bounds.width - CGFloat(cols - 1) * pitch) / 2
        originY = (bounds.height - CGFloat(rows - 1) * pitch) / 2

        trail = .init(repeating: 0, count: cols * rows)
        drops.removeAll(keepingCapacity: true)

        let stops = Self.themes[config.theme].stops.map(RGB.init)
        let f = CGFloat(config.floor)
        levelColors = (0..<colorLevels).map { l in
            let b = f + (1 - f) * CGFloat(l) / CGFloat(colorLevels - 1)
            return ramp(b, stops: stops).color
        }

        havePrev = false
        refreshRates()
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
        if trail.isEmpty { rebuildGrid() }
        frameCount += 1
        if frameCount % pollEvery == 0 { refreshRates() }

        let down = rate01(downRate)
        let up = rate01(upRate)

        // Spawn: a faint idle drizzle plus traffic-driven streams.
        let downSpawn = 0.06 + down * Float(cols) * 0.30
        let upSpawn = up * Float(cols) * 0.22
        var acc = downSpawn
        while acc >= 1 || (acc > 0 && rand01() < acc) {
            drops.append(Drop(col: Int(rand01() * Float(cols)) % max(1, cols),
                              y: Float(rows), speed: 0.35 + 0.5 * down + rand01() * 0.3,
                              up: false))
            acc -= 1
            if acc < 0 { break }
        }
        acc = upSpawn
        while acc >= 1 || (acc > 0 && rand01() < acc) {
            drops.append(Drop(col: Int(rand01() * Float(cols)) % max(1, cols),
                              y: -1, speed: 0.35 + 0.5 * up + rand01() * 0.3,
                              up: true))
            acc -= 1
            if acc < 0 { break }
        }

        // Decay trails, advance heads, deposit.
        for i in 0..<trail.count { trail[i] *= trailDecay }
        var alive: [Drop] = []
        alive.reserveCapacity(drops.count)
        for var d in drops {
            d.y += d.up ? d.speed : -d.speed
            if d.y < -2 || d.y > Float(rows) + 2 { continue }
            let row = Int(d.y.rounded())
            if row >= 0 && row < rows {
                let idx = row * cols + d.col
                trail[idx] = 1.0
                // Soften the cell just behind the head for a comet core.
                let behind = d.up ? row - 1 : row + 1
                if behind >= 0 && behind < rows {
                    let j = behind * cols + d.col
                    if trail[j] < 0.78 { trail[j] = 0.78 }
                }
            }
            alive.append(d)
        }
        drops = alive
        // Hard cap so a saturated link can't grow the array unbounded.
        if drops.count > cols * 6 { drops.removeFirst(drops.count - cols * 6) }

        needsDisplay = true
    }

    /// Harness only: pin throughput (bytes/sec) for snapshots.
    @objc public func debugSetRates(down: Float, up: Float) {
        overrideRates = (down, up)
        downRate = down
        upRate = up
    }

    // MARK: - Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if trail.isEmpty { rebuildGrid() }

        drawBackground(ctx)

        let bloomLevel = Int(CGFloat(colorLevels - 1) * 0.86)
        let f = CGFloat(config.floor)
        for j in 0..<rows {
            let cy = originY + CGFloat(j) * pitch
            let rowBase = j * cols
            for i in 0..<cols {
                let v = trail[rowBase + i]
                let b = max(f, CGFloat(v))
                let lvl = min(colorLevels - 1, max(0, Int(b * CGFloat(colorLevels - 1))))
                let cx = originX + CGFloat(i) * pitch
                drawCell(ctx, x: cx, y: cy, color: levelColors[lvl],
                         bloom: config.bloom && lvl >= bloomLevel)
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

        // Fixed frames, no autolayout (legacyScreenSaver presents the sheet
        // remotely before any layout pass; autolayout panels collapse there).
        let W: CGFloat = 440, H: CGFloat = 250
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                            styleMask: [.titled],
                            backing: .buffered, defer: false)
        panel.title = "Rede"
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

        let bloom = NSButton(checkboxWithTitle: "Brilho (bloom) nas cabeças",
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
        NotificationCenter.default.post(name: .netConfigChanged, object: nil)
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
