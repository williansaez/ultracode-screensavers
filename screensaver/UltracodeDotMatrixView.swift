import ScreenSaver
import AppKit
import simd

private extension Notification.Name {
    static let dotMatrixConfigChanged = Notification.Name("UltracodeDotMatrixConfigChanged")
}

// UltracodeDotMatrix — réplica fiel do componente web "dotmatrix" do
// originkit.dev (preset `base`). Referência: refs/dotmatrix/source_1.tsx.
//
// Pipeline original (WebGL/ogl, 2 passes):
//   1. Pass perlin: hue = |snoise(vec3(uv_aspect * uFrequency, uTime * uSpeed))|,
//      cor = hsv2rgb(hue, 1, 1) renderizada para uma render target.
//   2. Pass dot: o ecrã é dividido em células de uCellSize px; amostra-se a
//      textura perlin no centro da célula, converte-se para luma, aplica-se
//      gamma e bias, e desenha-se um disco cujo raio e cor derivam desse
//      valor (paleta branco → #E07000 → preto) sobre fundo preto.
//
// Como o pass dot só amostra o campo de ruído no centro de cada célula,
// este porte CPU avalia exatamente o mesmo ruído por célula e reproduz a
// matemática do shader literalmente — sem aproximação visual, sem Metal.
//
// Preset `base` → uniforms (via as funções map* do fonte):
//   frequency 1    → uFrequency   = mapLinear(1, 1..10, 0.3..6)  = 0.3
//   speed 6        → uSpeed       = 6 * 0.05                     = 0.3
//   cellSize 20    → uCellSize    = mapLinear(20, 1..100, 6..60) ≈ 16.3636 device px (dpr ≤ 2)
//   gamma 4        → uGamma       = mapLinear(4, 1..20, 0.5..8)  ≈ 1.68421
//   paletteBias 10 → uPaletteBias = 10 * 0.05                    = 0.5
//   colors = ["#FFFFFF", "#E07000", "#000000"], bgColor = "#000000"
//   useGlyphAtlas = false (discos), 30 fps (frameInterval = 1000/30), uValue = 1.
//   O componente original não tem qualquer interação com o rato.

@objc(UltracodeDotMatrixView)
final class UltracodeDotMatrixView: ScreenSaverView {

    // MARK: constantes mapeadas do preset (ver cabeçalho)

    private let uFrequency: Float = 0.3
    private let uSpeed: Float = 0.3
    private let uGamma: Float = 1.6842105263157894

    // DEFAULT_COLORS = ["#FFFFFF", "#E07000", "#000000"], alfas 1
    private let palette: [SIMD3<Float>] = [
        SIMD3<Float>(1, 1, 1),
        SIMD3<Float>(224.0 / 255.0, 112.0 / 255.0, 0),
        SIMD3<Float>(0, 0, 0),
    ]

    // MARK: temas
    //
    // Tema 0 ("Base") mantém a cadeia branco→#E07000→preto exata do shader.
    // Os restantes usam as MESMAS ramps de 8 stops (cold→hot) do Jogo da
    // Vida; como na cadeia base g2 = 0 é o stop mais "aceso" (branco) e
    // g2 = 1 o mais escuro (preto), a ramp é indexada invertida (1 - g2)
    // para preservar o contraste: dots mais acesos = stops quentes.

    private struct Theme {
        let name: String
        let stops: [UInt32]   // cold -> hot (vazio = cadeia base)
    }

    private static let themes: [Theme] = [
        Theme(name: "Base (laranja)", stops: []),
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

    private static func stopsToSIMD(_ stops: [UInt32]) -> [SIMD3<Float>] {
        stops.map { hex in
            SIMD3<Float>(Float((hex >> 16) & 0xFF) / 255,
                         Float((hex >> 8) & 0xFF) / 255,
                         Float(hex & 0xFF) / 255)
        }
    }

    /// Interpolação linear ao longo dos 8 stops (t em [0, 1]).
    private static func ramp(_ t: Float, stops: [SIMD3<Float>]) -> SIMD3<Float> {
        let x = min(max(t, 0), 1) * Float(stops.count - 1)
        let i = min(Int(x), stops.count - 2)
        return mix(stops[i], stops[i + 1], t: x - Float(i))
    }

    // MARK: configuração do utilizador

    private struct Config {
        var theme = 0
        var speed: Double = 1.0           // multiplicador 0.25x–3x do z do ruído
        var cellSize: Double = 16.363636363636363  // px físicos, 10–32
        var paletteBias: Double = 0.5     // 0.0–0.8
    }

    private static let moduleName = "com.williansaez.ultracode-dotmatrix"

    private static func makeDefaults() -> ScreenSaverDefaults? {
        let d = ScreenSaverDefaults(forModuleWithName: moduleName)
        d?.register(defaults: [
            "theme": 0,
            "speed": 1.0,
            "cellSize": 16.363636363636363,
            "paletteBias": 0.5,
        ])
        return d
    }

    private var config = Config()
    private var themeStops: [SIMD3<Float>] = []  // vazio = cadeia base

    private func loadConfig() {
        guard let d = Self.makeDefaults() else { return }
        config.theme = min(max(d.integer(forKey: "theme"), 0), Self.themes.count - 1)
        config.speed = min(max(d.double(forKey: "speed"), 0.25), 3.0)
        config.cellSize = min(max(d.double(forKey: "cellSize"), 10.0), 32.0)
        config.paletteBias = min(max(d.double(forKey: "paletteBias"), 0.0), 0.8)
        themeStops = Self.stopsToSIMD(Self.themes[config.theme].stops)
    }

    private var time: Float = 0  // segundos, espelha uTime = rAF ms * 0.001

    // MARK: ciclo de vida

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        animationTimeInterval = 1.0 / 30.0
        loadConfig()
        NotificationCenter.default.addObserver(
            self, selector: #selector(configChanged),
            name: .dotMatrixConfigChanged, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func configChanged() {
        loadConfig()
        needsDisplay = true
    }

    override func startAnimation() {
        loadConfig()
        super.startAnimation()
    }

    override func animateOneFrame() {
        // O multiplicador de velocidade escala o avanço do tempo acumulado,
        // por isso mudar a velocidade não salta no campo de ruído.
        time += Float(animationTimeInterval * config.speed)
        needsDisplay = true
    }

    // MARK: desenho

    override func draw(_ rect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let w = bounds.width
        let h = bounds.height
        guard w > 0, h > 0 else { return }

        // bgColor #000000
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(bounds)

        // uCellSize é expresso em pixels físicos do framebuffer; o canvas web
        // usa dpr = min(devicePixelRatio, 2). Converter para pontos preserva a
        // densidade visual do browser no mesmo ecrã.
        let dpr = min(window?.backingScaleFactor ?? 1, 2)
        let cell = max(CGFloat(config.cellSize) / dpr, 1)
        let uPaletteBias = Float(config.paletteBias)
        let stops = themeStops  // vazio = cadeia base branco→laranja→preto

        let cols = Int(ceil(w / cell))
        let rows = Int(ceil(h / cell))
        let aspect = Float(w / max(h, 1))
        let zNoise = time * uSpeed
        let invW = Float(1.0 / w)
        let invH = Float(1.0 / h)

        for row in 0..<rows {
            let cy = (CGFloat(row) + 0.5) * cell
            for col in 0..<cols {
                let cx = (CGFloat(col) + 0.5) * cell

                // uv = cellCenter / uResolution (limitado como CLAMP_TO_EDGE),
                // depois corrigido pelo aspeto exatamente como no shader perlin.
                var u = min(max(Float(cx) * invW, 0), 1)
                let v = min(max(Float(cy) * invH, 0), 1)
                u = (u - 0.5) * aspect + 0.5

                // hue = abs(snoise(vec3(uv * uFrequency, uTime * uSpeed)))
                let hue = abs(Self.snoise(SIMD3<Float>(u * uFrequency, v * uFrequency, zNoise)))
                let rgb = Self.hsv2rgb(SIMD3<Float>(hue, 1, 1))  // uValue = 1

                // gray = luma ^ gamma
                var gray = 0.3 * rgb.x + 0.59 * rgb.y + 0.11 * rgb.z
                gray = powf(min(max(gray, 0.0001), 1), uGamma)

                let g2 = min(max(gray + uPaletteBias, 0), 1)

                // radius = clamp(gray + bias) * 0.5 em unidades de célula
                let radius = CGFloat(g2) * 0.5 * cell
                if radius <= 0 { continue }

                let c: SIMD3<Float>
                if stops.isEmpty {
                    // interpolação da paleta de 3 cores (cadeia mix do shader)
                    let scaled = g2 * 2                          // g2 * (cnt - 1)
                    let i0 = min(max(Int(floor(scaled)), 0), 1)  // clamp(i0, 0, cnt-2)
                    let f = scaled - Float(i0)
                    c = mix(palette[i0], palette[i0 + 1], t: f)
                } else {
                    // ramp de 8 stops (cold→hot) indexada invertida: na cadeia
                    // base g2 = 0 é o stop mais aceso, por isso 1 - g2 mapeia
                    // os dots mais acesos para os stops quentes do tema.
                    c = Self.ramp(1 - g2, stops: stops)
                }

                ctx.setFillColor(CGColor(red: CGFloat(c.x), green: CGFloat(c.y),
                                         blue: CGFloat(c.z), alpha: 1))
                ctx.fillEllipse(in: CGRect(x: cx - radius, y: cy - radius,
                                           width: radius * 2, height: radius * 2))
            }
        }
    }

    // MARK: folha de configuração

    private var sheet: NSPanel?
    private var themePopup: NSPopUpButton?
    private var speedSlider: NSSlider?
    private var cellSlider: NSSlider?
    private var biasSlider: NSSlider?

    override var hasConfigureSheet: Bool { true }

    override var configureSheet: NSWindow? {
        if let sheet { return sheet }
        loadConfig()

        // Frames fixos, zero Auto Layout: a folha é medida e apresentada
        // remotamente (legacyScreenSaver -> Definições do Sistema) antes de
        // qualquer passagem de layout; painéis com autolayout colapsam lá.
        let W: CGFloat = 440, H: CGFloat = 212
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                            styleMask: [.titled],
                            backing: .buffered, defer: false)
        panel.title = "Matriz de Pontos"
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
        _ = label("Tamanho da célula:", row: 88)
        let cSlider = slider(config.cellSize, 10.0, 32.0, row: 88)
        _ = label("Contraste da paleta:", row: 50)
        let bSlider = slider(config.paletteBias, 0.0, 0.8, row: 50)

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
        cellSlider = cSlider
        biasSlider = bSlider
        return panel
    }

    @objc private func sheetOK(_ sender: Any?) {
        if let d = Self.makeDefaults() {
            d.set(themePopup?.indexOfSelectedItem ?? 0, forKey: "theme")
            d.set(speedSlider?.doubleValue ?? 1.0, forKey: "speed")
            d.set(cellSlider?.doubleValue ?? 16.363636363636363, forKey: "cellSize")
            d.set(biasSlider?.doubleValue ?? 0.5, forKey: "paletteBias")
            d.synchronize()
        }
        NotificationCenter.default.post(name: .dotMatrixConfigChanged, object: nil)
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

    // MARK: portes GLSL (literais do fragment shader de referência)

    // hsv2rgb do shader perlin: K = vec4(1, 2/3, 1/3, 3)
    private static func hsv2rgb(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let kxyz = SIMD3<Float>(1.0, 2.0 / 3.0, 1.0 / 3.0)
        let f = SIMD3<Float>(repeating: c.x) + kxyz
        let fr = f - floor(f)                                // fract(c.xxx + K.xyz)
        let p = abs(fr * 6.0 - SIMD3<Float>(repeating: 3.0)) // - K.www
        let clamped = simd_clamp(p - SIMD3<Float>(repeating: 1.0),
                                 SIMD3<Float>(repeating: 0),
                                 SIMD3<Float>(repeating: 1))
        return c.z * mix(SIMD3<Float>(repeating: 1.0), clamped, t: c.y)
    }

    // GLSL step(edge, x) = x < edge ? 0 : 1
    @inline(__always)
    private static func glslStep(_ edge: SIMD3<Float>, _ x: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(x.x < edge.x ? 0 : 1, x.y < edge.y ? 0 : 1, x.z < edge.z ? 0 : 1)
    }

    @inline(__always)
    private static func mod289(_ x: SIMD3<Float>) -> SIMD3<Float> {
        x - floor(x * (1.0 / 289.0)) * 289.0
    }

    @inline(__always)
    private static func mod289(_ x: SIMD4<Float>) -> SIMD4<Float> {
        x - floor(x * (1.0 / 289.0)) * 289.0
    }

    @inline(__always)
    private static func permute(_ x: SIMD4<Float>) -> SIMD4<Float> {
        mod289(((x * 34.0) + 1.0) * x)
    }

    @inline(__always)
    private static func taylorInvSqrt(_ r: SIMD4<Float>) -> SIMD4<Float> {
        1.79284291400159 - 0.85373472095314 * r
    }

    // snoise 3D (Ashima/McEwan), portado linha a linha do fragment shader.
    private static func snoise(_ v: SIMD3<Float>) -> Float {
        let Cx: Float = 1.0 / 6.0
        let Cy: Float = 1.0 / 3.0
        let D = SIMD4<Float>(0.0, 0.5, 1.0, 2.0)

        var i = floor(v + SIMD3<Float>(repeating: (v.x + v.y + v.z) * Cy))
        let x0 = v - i + SIMD3<Float>(repeating: (i.x + i.y + i.z) * Cx)

        let g = glslStep(SIMD3<Float>(x0.y, x0.z, x0.x), x0)  // step(x0.yzx, x0.xyz)
        let l = SIMD3<Float>(repeating: 1.0) - g
        let lzxy = SIMD3<Float>(l.z, l.x, l.y)
        let i1 = simd_min(g, lzxy)
        let i2 = simd_max(g, lzxy)

        let x1 = x0 - i1 + SIMD3<Float>(repeating: Cx)
        let x2 = x0 - i2 + SIMD3<Float>(repeating: Cy)
        let x3 = x0 - SIMD3<Float>(repeating: D.y)

        i = mod289(i)
        let p = permute(permute(permute(
            SIMD4<Float>(repeating: i.z) + SIMD4<Float>(0.0, i1.z, i2.z, 1.0))
            + SIMD4<Float>(repeating: i.y) + SIMD4<Float>(0.0, i1.y, i2.y, 1.0))
            + SIMD4<Float>(repeating: i.x) + SIMD4<Float>(0.0, i1.x, i2.x, 1.0))

        let n_: Float = 0.142857142857
        let ns = n_ * SIMD3<Float>(D.w, D.y, D.z) - SIMD3<Float>(D.x, D.z, D.x)

        let j = p - 49.0 * floor(p * ns.z * ns.z)
        let x_ = floor(j * ns.z)
        let y_ = floor(j - 7.0 * x_)
        let x = x_ * ns.x + SIMD4<Float>(repeating: ns.y)
        let y = y_ * ns.x + SIMD4<Float>(repeating: ns.y)
        let h = SIMD4<Float>(repeating: 1.0) - abs(x) - abs(y)

        let b0 = SIMD4<Float>(x.x, x.y, y.x, y.y)
        let b1 = SIMD4<Float>(x.z, x.w, y.z, y.w)
        let s0 = floor(b0) * 2.0 + 1.0
        let s1 = floor(b1) * 2.0 + 1.0
        // sh = -step(h, vec4(0.0)) → componente = (h > 0) ? 0 : -1
        let sh = SIMD4<Float>(h.x > 0 ? 0 : -1, h.y > 0 ? 0 : -1,
                              h.z > 0 ? 0 : -1, h.w > 0 ? 0 : -1)

        let a0 = SIMD4<Float>(b0.x, b0.z, b0.y, b0.w)
            + SIMD4<Float>(s0.x, s0.z, s0.y, s0.w) * SIMD4<Float>(sh.x, sh.x, sh.y, sh.y)
        let a1 = SIMD4<Float>(b1.x, b1.z, b1.y, b1.w)
            + SIMD4<Float>(s1.x, s1.z, s1.y, s1.w) * SIMD4<Float>(sh.z, sh.z, sh.w, sh.w)

        var p0 = SIMD3<Float>(a0.x, a0.y, h.x)
        var p1 = SIMD3<Float>(a0.z, a0.w, h.y)
        var p2 = SIMD3<Float>(a1.x, a1.y, h.z)
        var p3 = SIMD3<Float>(a1.z, a1.w, h.w)

        let norm = taylorInvSqrt(SIMD4<Float>(dot(p0, p0), dot(p1, p1), dot(p2, p2), dot(p3, p3)))
        p0 *= norm.x
        p1 *= norm.y
        p2 *= norm.z
        p3 *= norm.w

        var m = simd_max(0.6 - SIMD4<Float>(dot(x0, x0), dot(x1, x1), dot(x2, x2), dot(x3, x3)),
                         SIMD4<Float>(repeating: 0.0))
        m = m * m
        return 42.0 * dot(m * m, SIMD4<Float>(dot(p0, x0), dot(p1, x1), dot(p2, x2), dot(p3, x3)))
    }
}
