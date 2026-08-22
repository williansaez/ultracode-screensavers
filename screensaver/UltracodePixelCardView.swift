// UltracodePixelCard — réplica fiel do componente "pixelcard" (preset `base`)
// do originkit.dev (refs/pixelcard/source_1.tsx).
//
// Parâmetros portados 1:1 do preset:
//   gap = 6 px (passo da grelha)
//   pixelSize = 2 px (maxSizeInteger; maxSize aleatório em [0.5, 2])
//   speed = 80  → efetivo 80 * 0.002 = 0.16; por píxel rand(0.1,0.9) * 0.16
//   colors = branco a 100%, 80% e 60% de alpha, ciclado por índice
//   appearFrom = "middle" (delay = distância euclidiana ao centro)
//   transition = tween 0.8 s, ease "easeOut" = cubic-bezier(0, 0, 0.58, 1)
//   fundo #000000; fullscreen (borda/raio do card removidos a pedido)
//
// O trigger original é hover (enter/leave). Convertido para ciclo autónomo:
//   appear (varrimento radial) e depois shimmer perpétuo — sem disappear/pausa
//   (ciclo removido a pedido; o hover leave do original não é replicado).

import ScreenSaver
import AppKit

private extension Notification.Name {
    static let pixelCardConfigChanged = Notification.Name("UltracodePixelCardConfigChanged")
}

// MARK: - Easing (porta do cubicBezier do componente)

private func cubicBezier(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> (Double) -> Double {
    let cx = 3 * x1
    let bx = 3 * (x2 - x1) - cx
    let ax = 1 - cx - bx
    let cy = 3 * y1
    let by = 3 * (y2 - y1) - cy
    let ay = 1 - cy - by
    func fx(_ t: Double) -> Double { ((ax * t + bx) * t + cx) * t }
    func dfx(_ t: Double) -> Double { (3 * ax * t + 2 * bx) * t + cx }
    return { x in
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        var t = x
        for _ in 0..<8 {
            let e = fx(t) - x
            let d = dfx(t)
            if abs(e) < 1e-5 || d == 0 { break }
            t -= e / d
        }
        return ((ay * t + by) * t + cy) * t
    }
}

// MARK: - Pixel (porta da classe Pixel do componente)

private final class PCPixel {
    let x: Double
    let y: Double
    let colorIndex: Int
    let speed: Double
    var size: Double = 0
    let minSize: Double
    let maxSizeInteger: Double
    let maxSize: Double
    let delay: Double
    var counter: Double = 0
    let counterStep: Double
    var isReverse = false
    var isShimmer = false
    var growStart: Double? = nil

    init(canvasW: Double, canvasH: Double, x: Double, y: Double,
         colorIndex: Int, speed: Double, delay: Double, maxPx: Double) {
        self.x = x
        self.y = y
        self.colorIndex = colorIndex
        self.speed = Double.random(in: 0.1...0.9) * speed
        let factor = maxPx / 2
        self.minSize = 0.5 * factor
        self.maxSizeInteger = maxPx
        self.maxSize = Double.random(in: (0.5 * factor)...maxPx)
        self.delay = delay
        self.counterStep = Double.random(in: 0..<4) + (canvasW + canvasH) * 0.01
    }

    func appear(now: Double, durationMs: Double, ease: (Double) -> Double) {
        if counter <= delay {
            counter += counterStep
            return
        }
        if !isShimmer {
            if growStart == nil { growStart = now }
            let p = durationMs > 0 ? min(1, (now - growStart!) / durationMs) : 1
            size = ease(p) * maxSize
            if p >= 1 {
                isShimmer = true
                // fase inicial aleatória: mata a coerência radial (pulso) — twinkle puro
                size = Double.random(in: minSize...maxSize)
                isReverse = Bool.random()
            }
        }
        if isShimmer { shimmer() }
    }

    private func shimmer() {
        if size >= maxSize {
            isReverse = true
        } else if size <= minSize {
            isReverse = false
        }
        if isReverse { size -= speed } else { size += speed }
    }
}

// MARK: - View

@objc(UltracodePixelCardView)
final class UltracodePixelCardView: ScreenSaverView {

    // Preset `base` do originkit.dev
    private let presetSpeed: Double = 80          // → efetivo 0.16 via throttle 0.002
    private let durationMs: Double = 800          // transition.duration 0.8 s
    private let easeFn = cubicBezier(0, 0, 0.58, 1) // "easeOut"
    private let cardBackground = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)          // #000000
    // Paleta do preset (tema Base): rgba(255,255,255,1), 0.8 e 0.6
    private let paletteAlphas: [CGFloat] = [1.0, 0.8, 0.6]

    // MARK: - Temas
    //
    // stops == nil → "Base": branco com os 3 alphas do preset original.
    // Com stops (ramps do UltracodeLife, cold→hot): os 3 níveis de opacidade
    // viram 3 cores da ramp — stop 7 (mais quente) para os píxeis mais opacos,
    // depois 5 e 4. Fundo mantém-se preto.
    private struct Theme {
        let name: String
        let stops: [UInt32]?   // cold -> hot (mesmas ramps do Life), nil = Base
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

    /// Índices na ramp para os 3 níveis (colorIndex 0 = mais opaco → mais quente).
    private static let rampPicks = [7, 5, 4]

    /// Cores efetivas dos 3 níveis, derivadas do tema ativo.
    private var paletteColors: [CGColor] = []

    private func rebuildPalette() {
        let theme = Self.themes[config.theme]
        if let stops = theme.stops {
            paletteColors = Self.rampPicks.map { i -> CGColor in
                let hex = stops[i]
                return CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                               green: CGFloat((hex >> 8) & 0xFF) / 255,
                               blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
            }
        } else {
            paletteColors = paletteAlphas.map {
                CGColor(srgbRed: 1, green: 1, blue: 1, alpha: $0)
            }
        }
    }

    // MARK: - Configuração do utilizador

    private struct Config {
        var theme = 0             // índice em themes
        var speed: Double = 1.0   // multiplicador do shimmer (0.25x–3x)
        var gap: Double = 6       // passo da grelha (4–12 px)
        var pixelSize: Double = 2 // tamanho máx. do píxel (1–4 px)
    }

    private static let moduleName = "com.williansaez.ultracode-pixelcard"

    private static func makeDefaults() -> ScreenSaverDefaults? {
        let d = ScreenSaverDefaults(forModuleWithName: moduleName)
        d?.register(defaults: [
            "theme": 0,
            "speed": 1.0,
            "gap": 6.0,
            "pixelSize": 2.0,
        ])
        return d
    }

    private var config = Config()

    private func loadConfig() {
        guard let d = Self.makeDefaults() else { return }
        config.theme = min(max(d.integer(forKey: "theme"), 0), Self.themes.count - 1)
        config.speed = min(max(d.double(forKey: "speed"), 0.25), 3.0)
        config.gap = min(max(d.double(forKey: "gap"), 4.0), 12.0)
        config.pixelSize = min(max(d.double(forKey: "pixelSize"), 1.0), 4.0)
        rebuildPalette()
    }

    // Sem ciclo: aparece uma vez (varrimento radial) e fica em shimmer perpétuo.
    private var nowMs: Double = 0             // relógio de simulação (1000/60 por frame)

    private var pixels: [PCPixel] = []
    private var cardRect: CGRect = .zero
    private var builtForSize: CGSize = .zero

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1.0 / 60.0
        wantsLayer = false
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        animationTimeInterval = 1.0 / 60.0
        commonInit()
    }

    private func commonInit() {
        loadConfig()
        NotificationCenter.default.addObserver(
            self, selector: #selector(configChanged),
            name: .pixelCardConfigChanged, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func configChanged() {
        loadConfig()
        // Reconstruir a grelha (gap/tamanho/velocidade estão cozidos nos píxeis).
        builtForSize = .zero
        pixels = []
        needsDisplay = true
    }

    // MARK: grelha

    private func rebuildIfNeeded() {
        let size = bounds.size
        guard size.width > 4, size.height > 4 else { return }
        if size == builtForSize && !pixels.isEmpty { return }
        builtForSize = size

        // Enquadramento: fullscreen — o efeito cobre o ecrã inteiro (sem card).
        cardRect = CGRect(origin: .zero, size: size)
        let cw = size.width
        let ch = size.height

        let w = Double(cw), h = Double(ch)
        let gap = config.gap
        // getEffectiveSpeed × multiplicador do utilizador (0.25x–3x)
        let effSpeed = min(max(presetSpeed, 0), 100) * 0.002 * config.speed
        var pxs: [PCPixel] = []
        pxs.reserveCapacity(Int(w / gap + 1) * Int(h / gap + 1))
        var idx = 0
        var x: Double = 0
        while x < w {
            var y: Double = 0
            while y < h {
                let colorIndex = idx % Self.rampPicks.count
                idx += 1
                // appearFrom = "middle"
                let dx = x - w / 2
                let dy = y - h / 2
                let delay = (dx * dx + dy * dy).squareRoot()
                pxs.append(PCPixel(canvasW: w, canvasH: h, x: x, y: y,
                                   colorIndex: colorIndex, speed: effSpeed,
                                   delay: delay, maxPx: max(0.1, config.pixelSize)))
                y += gap
            }
            x += gap
        }
        pixels = pxs
    }

    // MARK: animação

    override func animateOneFrame() {
        nowMs += 1000.0 / 60.0
        rebuildIfNeeded()
        guard !pixels.isEmpty else { return }

        for p in pixels { p.appear(now: nowMs, durationMs: durationMs, ease: easeFn) }
        setNeedsDisplay(bounds)
    }

    // MARK: desenho

    override func draw(_ rect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        rebuildIfNeeded()

        // Fundo preto do efeito, ecrã inteiro
        ctx.setFillColor(cardBackground.cgColor)
        ctx.fill(bounds)

        guard !pixels.isEmpty else { return }

        // Agrupar rects por cor (3 passagens em vez de 1 setFill por píxel)
        var rectsByColor: [[CGRect]] = [[], [], []]
        let ox = cardRect.minX, oy = cardRect.minY
        for p in pixels where p.size > 0.01 {
            let s = CGFloat(p.size)
            let centerOffset = CGFloat(p.maxSizeInteger) * 0.5 - s * 0.5
            rectsByColor[p.colorIndex].append(
                CGRect(x: ox + CGFloat(p.x) + centerOffset,
                       y: oy + CGFloat(p.y) + centerOffset,
                       width: s, height: s))
        }
        if paletteColors.count < 3 { rebuildPalette() }
        for (i, color) in paletteColors.enumerated() where !rectsByColor[i].isEmpty {
            ctx.setFillColor(color)
            ctx.fill(rectsByColor[i])
        }
    }

    override func startAnimation() {
        loadConfig()
        builtForSize = .zero
        pixels = []
        super.startAnimation()
    }
    override func stopAnimation() { super.stopAnimation() }

    // MARK: - Folha de configuração

    private var sheet: NSPanel?
    private var themePopup: NSPopUpButton?
    private var speedSlider: NSSlider?
    private var gapSlider: NSSlider?
    private var sizeSlider: NSSlider?

    override var hasConfigureSheet: Bool { true }

    override var configureSheet: NSWindow? {
        if let sheet { return sheet }
        loadConfig()

        // Frames fixos, sem autolayout: a folha é medida e apresentada
        // remotamente (legacyScreenSaver -> Definições do Sistema) antes de
        // qualquer passagem de layout; painéis com autolayout colapsam aí.
        let W: CGFloat = 440, H: CGFloat = 250
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                            styleMask: [.titled],
                            backing: .buffered, defer: false)
        panel.title = "Pixel Card"
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

        _ = label("Velocidade do brilho:", row: 164)
        let sSlider = slider(config.speed, 0.25, 3.0, row: 164)
        _ = label("Espaçamento da grelha:", row: 126)
        let gSlider = slider(config.gap, 4.0, 12.0, row: 126)
        gSlider.numberOfTickMarks = 9
        gSlider.allowsTickMarkValuesOnly = true
        _ = label("Tamanho máx. do píxel:", row: 88)
        let pSlider = slider(config.pixelSize, 1.0, 4.0, row: 88)
        pSlider.numberOfTickMarks = 7
        pSlider.allowsTickMarkValuesOnly = true

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
        gapSlider = gSlider
        sizeSlider = pSlider
        return panel
    }

    @objc private func sheetOK(_ sender: Any?) {
        if let d = Self.makeDefaults() {
            d.set(themePopup?.indexOfSelectedItem ?? 0, forKey: "theme")
            d.set(speedSlider?.doubleValue ?? 1.0, forKey: "speed")
            d.set(gapSlider?.doubleValue ?? 6.0, forKey: "gap")
            d.set(sizeSlider?.doubleValue ?? 2.0, forKey: "pixelSize")
            d.synchronize()
        }
        NotificationCenter.default.post(name: .pixelCardConfigChanged, object: nil)
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
