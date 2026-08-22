import ScreenSaver
import AppKit

// Réplica fiel do componente web "line-ripple-background" (originkit.dev, preset `base`).
// Grelha de segmentos curtos orientados por ruído simplex 2D com drift temporal.
// Sem cursor: o campo corre puro (a física de mousemove da referência foi removida
// a pedido — só o estado "idle" do componente).
//
// Parâmetros portados 1:1 do preset:
//   count = 57  → gap = 90 - ((57-1)/99)*82 ≈ 43.62 px
//   movement = 24 → drift = t(ms) * 24 * 8e-6
//   resolution = 10 → comprimento do traço = 6 + (10/10)*20 = 26 px
//   strokeColor #FFFFFF, backgroundColor #000000, stroke-width 1.5, linecap round
//   CURL = 3, BASE_ANGLE = 0, SEED = 0.5, easing do ângulo 0.12/frame @60fps
//
// Configuração (ScreenSaverDefaults "com.williansaez.ultracode-lineripple"):
//   theme    — 0 Base (branco), 1 Ultracode (lavanda), 2 Doom clássico, 3 Matrix.
//              Nos temas coloridos, o tom é UNIFORME (ramp 0.6) e o destaque vem
//              da velocidade de rotação do traço — a girar rápido sobe até ao
//              stop quente. 8 buckets (8 CGPaths por frame) para performance.
//   speed    — 0.25x..3x sobre o drift temporal do ruído (default 1x).
//   count    — densidade da grelha 20..100 (default 57; regenera a grelha).
//   length   — comprimento do traço 12..48 px (default 26).

private extension Notification.Name {
    static let lineRippleConfigChanged =
        Notification.Name("UltracodeLineRippleConfigChanged")
}

// MARK: - Simplex noise 2D (porte exato de createNoise2D do source_1.tsx)

final class SimplexNoise2D {
    private var perm = [Int](repeating: 0, count: 512)
    private var permMod12 = [Int](repeating: 0, count: 512)
    private let grad2: [Double] = [
        1, 1, -1, 1, 1, -1, -1, -1, 1, 0, -1, 0, 1, 0, -1, 0, 0, 1, 0, -1, 0, 1,
        0, -1,
    ]
    private let F2 = 0.5 * (sqrt(3.0) - 1.0)
    private let G2 = (3.0 - sqrt(3.0)) / 6.0
    private let G22 = (3.0 - sqrt(3.0)) / 3.0

    init(seed: Double = 0.5) {
        var p = [Int](repeating: 0, count: 256)
        for i in 0..<256 { p[i] = i }
        func seededRandom(_ index: Double) -> Double {
            let x = sin(index * 12.9898 + seed * 78.233) * 43758.5453
            return x - floor(x)
        }
        var i = 255
        while i > 0 {
            let n = Int(floor(Double(i + 1) * seededRandom(Double(i))))
            let q = p[i]
            p[i] = p[n]
            p[n] = q
            i -= 1
        }
        for i in 0..<512 {
            perm[i] = p[i & 255]
            permMod12[i] = perm[i] % 12
        }
    }

    func noise(_ x: Double, _ y: Double) -> Double {
        let s = (x + y) * F2
        let i = Int(floor(x + s))
        let j = Int(floor(y + s))
        let t = Double(i + j) * G2
        let x0 = x - (Double(i) - t)
        let y0 = y - (Double(j) - t)
        let i1: Int, j1: Int
        if x0 > y0 { i1 = 1; j1 = 0 } else { i1 = 0; j1 = 1 }
        let x1 = x0 - Double(i1) + G2
        let y1 = y0 - Double(j1) + G2
        let x2 = x0 - 1 + G22
        let y2 = y0 - 1 + G22
        let ii = i & 255
        let jj = j & 255
        let gi0 = permMod12[ii + perm[jj]]
        let gi1 = permMod12[ii + i1 + perm[jj + j1]]
        let gi2 = permMod12[ii + 1 + perm[jj + 1]]
        var n0 = 0.0, n1 = 0.0, n2 = 0.0
        var t0 = 0.5 - x0 * x0 - y0 * y0
        if t0 >= 0 {
            t0 *= t0
            n0 = t0 * t0 * (grad2[gi0 * 2] * x0 + grad2[gi0 * 2 + 1] * y0)
        }
        var t1 = 0.5 - x1 * x1 - y1 * y1
        if t1 >= 0 {
            t1 *= t1
            n1 = t1 * t1 * (grad2[gi1 * 2] * x1 + grad2[gi1 * 2 + 1] * y1)
        }
        var t2 = 0.5 - x2 * x2 - y2 * y2
        if t2 >= 0 {
            t2 *= t2
            n2 = t2 * t2 * (grad2[gi2 * 2] * x2 + grad2[gi2 * 2 + 1] * y2)
        }
        return 70 * (n0 + n1 + n2)
    }
}

// MARK: - View

@objc(UltracodeLineRippleView)
public final class UltracodeLineRippleView: ScreenSaverView {

    // MARK: Color helpers (mesmo padrão do UltracodeLifeView)

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
        let stops: [UInt32]?   // cold -> hot; nil = Base (branco uniforme)
    }

    private static let themes: [Theme] = [
        Theme(name: "Base", stops: nil),
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

    private func ramp(_ v: CGFloat, stops: [RGB]) -> RGB {
        let x = min(max(v, 0), 1) * CGFloat(stops.count - 1)
        let i = min(Int(x), stops.count - 2)
        return RGB.lerp(stops[i], stops[i + 1], x - CGFloat(i))
    }

    // MARK: User configuration

    private struct Config {
        var theme = 0
        var speed = 1.0    // multiplicador do drift temporal (0.25..3)
        var count = 57.0   // densidade da grelha (20..100)
        var length = 26.0  // comprimento do traço em px (12..48)
    }

    private static let moduleName = "com.williansaez.ultracode-lineripple"

    private static func makeDefaults() -> ScreenSaverDefaults? {
        let d = ScreenSaverDefaults(forModuleWithName: moduleName)
        d?.register(defaults: [
            "theme": 0,
            "speed": 1.0,
            "count": 57.0,
            "length": 26.0,
        ])
        return d
    }

    private var config = Config()

    /// 8 cores pré-computadas (uma por bucket) para o tema ativo; vazio = Base.
    private static let bucketCount = 8
    private var bucketColors: [CGColor] = []

    private func loadConfig() {
        guard let d = Self.makeDefaults() else { return }
        config.theme = min(max(d.integer(forKey: "theme"), 0), Self.themes.count - 1)
        config.speed = min(max(d.double(forKey: "speed"), 0.25), 3.0)
        config.count = min(max(d.double(forKey: "count"), 20.0), 100.0)
        config.length = min(max(d.double(forKey: "length"), 12.0), 48.0)
        rebuildBucketColors()
    }

    private func rebuildBucketColors() {
        guard let hexes = Self.themes[config.theme].stops else {
            bucketColors = []
            return
        }
        let stops = hexes.map(RGB.init)
        bucketColors = (0..<Self.bucketCount).map { b in
            // bucket 0 = tom base uniforme (ramp 0.6, tom médio-claro visível);
            // buckets seguintes sobem até ao stop mais quente — o destaque por
            // velocidade de rotação acende os traços em movimento rápido
            let t = 0.6 + 0.4 * CGFloat(b) / CGFloat(Self.bucketCount - 1)
            return ramp(t, stops: stops).color.cgColor
        }
    }

    // Constantes do preset `base`
    private let strokeColor = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    private let backgroundColor = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
    private let movement = 24.0
    private let curl = 3.0
    private let baseAngle = 0.0

    private struct Point {
        var x: Double
        var y: Double
        var angle: Double = 0
        var spd: Double = 0   // velocidade angular suavizada (EMA) para o destaque
    }

    private var noise = SimplexNoise2D(seed: 0.5)
    private var points: [Point] = []
    private var timeMs: Double = 0
    private var builtSize: CGSize = .zero
    private var builtCount: Double = 0

    public override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        animationTimeInterval = 1.0 / 60.0
        wantsLayer = true
        loadConfig()
        NotificationCenter.default.addObserver(
            self, selector: #selector(configChanged),
            name: .lineRippleConfigChanged, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func configChanged() {
        loadConfig()
        rebuildPointsIfNeeded()
        needsDisplay = true
    }

    public override var isFlipped: Bool { true }

    // MARK: setLines (idêntico ao original; count configurável)

    private func rebuildPointsIfNeeded() {
        let w = Double(bounds.width), h = Double(bounds.height)
        guard w > 0, h > 0 else { return }
        if builtSize == bounds.size, builtCount == config.count, !points.isEmpty {
            return
        }
        builtSize = bounds.size
        builtCount = config.count

        let c = max(1.0, min(100.0, config.count))
        let gap = 90.0 - ((c - 1) / 99.0) * 82.0
        let cols = Int(ceil((w + gap) / gap))
        let rows = Int(ceil((h + gap) / gap))
        let xStart = (w - gap * Double(cols - 1)) / 2
        let yStart = (h - gap * Double(rows - 1)) / 2

        points.removeAll(keepingCapacity: true)
        points.reserveCapacity(cols * rows)
        for i in 0..<cols {
            for j in 0..<rows {
                points.append(Point(x: xStart + gap * Double(i),
                                    y: yStart + gap * Double(j)))
            }
        }
    }

    // MARK: tick (porte de movePoints)

    public override func animateOneFrame() {
        rebuildPointsIfNeeded()
        timeMs += 1000.0 / 60.0
        movePoints(time: timeMs)
        needsDisplay = true
    }

    private func movePoints(time: Double) {
        let drift = time * movement * 8e-6 * config.speed
        let dirX = cos(baseAngle) * drift
        let dirY = sin(baseAngle) * drift

        for idx in points.indices {
            var p = points[idx]
            let n = noise.noise(p.x * 0.004 - dirX, p.y * 0.004 - dirY)
            let target = baseAngle + n * Double.pi * curl

            var diff = target - p.angle
            while diff > Double.pi { diff -= 2 * Double.pi }
            while diff < -Double.pi { diff += 2 * Double.pi }
            let delta = diff * 0.12
            p.angle += delta
            p.spd = p.spd * 0.85 + abs(delta) * 0.15

            points[idx] = p
        }
    }

    // MARK: draw (porte de drawLines)

    public override func draw(_ rect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        ctx.setFillColor(backgroundColor.cgColor)
        ctx.fill(bounds)

        let half = config.length / 2
        ctx.setLineWidth(1.5)
        ctx.setLineCap(.round)

        if bucketColors.isEmpty {
            // Base: um único path branco, como no preset original.
            ctx.setStrokeColor(strokeColor.cgColor)
            let path = CGMutablePath()
            for p in points {
                let ux = cos(p.angle) * half
                let uy = sin(p.angle) * half
                path.move(to: CGPoint(x: p.x - ux, y: p.y - uy))
                path.addLine(to: CGPoint(x: p.x + ux, y: p.y + uy))
            }
            ctx.addPath(path)
            ctx.strokePath()
            return
        }

        // Tema colorido: tom base uniforme, destaque pela VELOCIDADE de rotação
        // do traço (spd 0 → tom base; a girar rápido → stop quente). 8 buckets
        // (um CGPath por bucket) para manter a performance.
        let buckets = Self.bucketCount
        let paths = (0..<buckets).map { _ in CGMutablePath() }
        for p in points {
            let t = min(p.spd / 0.05, 1)
            let b = min(Int(t * Double(buckets)), buckets - 1)
            let ux = cos(p.angle) * half
            let uy = sin(p.angle) * half
            paths[b].move(to: CGPoint(x: p.x - ux, y: p.y - uy))
            paths[b].addLine(to: CGPoint(x: p.x + ux, y: p.y + uy))
        }
        for b in 0..<buckets where !paths[b].isEmpty {
            ctx.setStrokeColor(bucketColors[b])
            ctx.addPath(paths[b])
            ctx.strokePath()
        }
    }

    public override func startAnimation() {
        loadConfig()
        super.startAnimation()
        rebuildPointsIfNeeded()
    }

    // MARK: - Configure sheet

    private var sheet: NSPanel?
    private var themePopup: NSPopUpButton?
    private var speedSlider: NSSlider?
    private var densitySlider: NSSlider?
    private var lengthSlider: NSSlider?

    public override var hasConfigureSheet: Bool { true }

    public override var configureSheet: NSWindow? {
        if let sheet { return sheet }
        loadConfig()

        // Frames fixos, zero Auto Layout: o sheet é medido e apresentado
        // remotamente (legacyScreenSaver -> Definições do Sistema) antes de
        // qualquer passo de layout; painéis com autolayout colapsam aí.
        let W: CGFloat = 440, H: CGFloat = 212
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                            styleMask: [.titled],
                            backing: .buffered, defer: false)
        panel.title = "Ondulação de Linhas"
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

        _ = label("Tema:", row: 164)
        let popup = NSPopUpButton(frame: NSRect(x: 178, y: 158, width: 244, height: 26),
                                  pullsDown: false)
        popup.addItems(withTitles: Self.themes.map(\.name))
        popup.selectItem(at: config.theme)
        content.addSubview(popup)

        _ = label("Velocidade:", row: 126)
        let sSlider = slider(config.speed, 0.25, 3.0, row: 126)
        _ = label("Densidade:", row: 88)
        let dSlider = slider(config.count, 20, 100, row: 88)
        _ = label("Comprimento do traço:", row: 50)
        let lSlider = slider(config.length, 12, 48, row: 50)

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
        speedSlider = sSlider
        densitySlider = dSlider
        lengthSlider = lSlider
        return panel
    }

    @objc private func sheetOK(_ sender: Any?) {
        if let d = Self.makeDefaults() {
            d.set(themePopup?.indexOfSelectedItem ?? 0, forKey: "theme")
            d.set(speedSlider?.doubleValue ?? 1.0, forKey: "speed")
            d.set(densitySlider?.doubleValue ?? 57.0, forKey: "count")
            d.set(lengthSlider?.doubleValue ?? 26.0, forKey: "length")
            d.synchronize()
        }
        NotificationCenter.default.post(name: .lineRippleConfigChanged, object: nil)
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
