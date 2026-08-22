// UltracodeTextWave — réplica fiel do componente "text-wave" (preset `base`) do originkit.dev.
//
// Porta directa da matemática CSS/JS da referência (refs/text-wave/source_1.tsx):
//   tileSize   = max(fontSize, 10) + gap            → 14 + 10 = 24 px
//   cols       = ceil(w / tile) (+1 se ímpar)       rows = ceil(h / tile)
//   xRatio(i)  = ((i + 1) % cols) / (cols + 1)
//   yRatio(i)  = (rows - row) / rows
//   absX/absY  = |ratio - 0.5|
//   l          = sin( absX / cos( sin(absY*2 + 60) * 2.5 ) * 3  -  (t * speedFactor) / 350 )
//   opacity    = max(l, 0.05)
//   t          += 10 * direction por frame a 30 fps (reverse=true → -10), mod 86 400 000
//   speedFactor = speed / 25 = 61 / 25 = 2.44
// Texto do preset: "Text Wave", cor branca (paletteCount=1, todas #FFFFFF), fundo #000000.
// Fonte da referência: Inter 400 14px — não existe no macOS; usa-se a fonte de sistema
// (SF Pro, regular, 14 pt), a sans neo-grotesca mais próxima.
//
// Configuração (ScreenSaverDefaults "com.williansaez.ultracode-textwave"):
//   theme      0 = Base (branco sobre preto, comportamento original);
//              1..3 = rampas de cor do Life (Ultracode lavanda / Doom / Matrix).
//              Nos temas coloridos a opacidade da onda indexa a rampa cold→hot
//              (opacidade baixa → stop frio escuro; alta → stop quente claro) e o
//              glifo é desenhado nessa cor com alpha 1; o fundo continua preto.
//   speedMult  0.25–3.0 (multiplica o avanço de `time`)
//   gridText   texto da grelha (default "Text Wave")
//   noise      dose de jitter de ruído em radianos, 0 = onda pura, máx 4.4 (default 2.2)

import ScreenSaver
import AppKit
import CoreText

private extension Notification.Name {
    static let textWaveConfigChanged = Notification.Name("UltracodeTextWaveConfigChanged")
}

@objc(UltracodeTextWaveView)
public final class UltracodeTextWaveView: ScreenSaverView {

    // MARK: - Parâmetros do preset `base` (portados 1:1)

    private let speed: Double = 61
    private let reverse = true
    private let gap: Double = 10
    private let fontSize: Double = 14
    private let backgroundColorRef = CGColor(red: 0, green: 0, blue: 0, alpha: 1) // #000000
    private let baseColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1)         // #FFFFFF

    private var tileSize: Double { max(fontSize, 10) + gap } // 24

    // Relógio da animação (igual ao updateTime da referência)
    private var time: Double = 0

    // MARK: - Temas (stops idênticos ao UltracodeLife)

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
        var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }
    }

    private struct Theme {
        let name: String
        let stops: [UInt32]   // cold -> hot; vazio = Base (branco com alpha)
    }

    private static let themes: [Theme] = [
        Theme(name: "Base (branco)", stops: []),
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

    private static func ramp(_ v: CGFloat, stops: [RGB]) -> RGB {
        let x = min(max(v, 0), 1) * CGFloat(stops.count - 1)
        let i = min(Int(x), stops.count - 2)
        return RGB.lerp(stops[i], stops[i + 1], x - CGFloat(i))
    }

    /// LUT de 64 cores (opacidade 0..1 → cold..hot). Vazia no tema Base.
    private var themeLUT: [CGColor] = []

    // MARK: - Configuração do utilizador

    private struct Config {
        var theme = 0
        var speedMult: Double = 1.0
        var text = "Text Wave"
        var noise: Double = 2.2
    }

    private static let moduleName = "com.williansaez.ultracode-textwave"

    private static func makeDefaults() -> ScreenSaverDefaults? {
        let d = ScreenSaverDefaults(forModuleWithName: moduleName)
        d?.register(defaults: [
            "theme": 0,
            "speedMult": 1.0,
            "gridText": "Text Wave",
            "noise": 2.2,
        ])
        return d
    }

    private var config = Config()

    private func loadConfig() {
        guard let d = Self.makeDefaults() else { return }
        config.theme = min(max(d.integer(forKey: "theme"), 0), Self.themes.count - 1)
        config.speedMult = min(max(d.double(forKey: "speedMult"), 0.25), 3.0)
        let raw = d.string(forKey: "gridText") ?? "Text Wave"
        config.text = raw.isEmpty ? "Text Wave" : raw
        config.noise = min(max(d.double(forKey: "noise"), 0.0), 4.4)

        let stops = Self.themes[config.theme].stops.map(RGB.init)
        if stops.isEmpty {
            themeLUT = []
        } else {
            themeLUT = (0..<64).map {
                Self.ramp(CGFloat($0) / 63.0, stops: stops).cgColor
            }
        }
        buildGlyphCache()
    }

    // MARK: - Cache de glifos (CTLine por carácter único)

    private struct Glyph {
        let line: CTLine
        let width: Double
        let ascent: Double
        let descent: Double
    }
    private var glyphCache: [Character: Glyph] = [:]
    private lazy var refFont: NSFont =
        NSFont(name: "Inter-Regular", size: fontSize)
        ?? NSFont(name: "Inter", size: fontSize)
        ?? NSFont.systemFont(ofSize: fontSize, weight: .regular)

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
        animationTimeInterval = 1.0 / 30.0 // frameInterval = 1000/30 na referência
        loadConfig()
        NotificationCenter.default.addObserver(
            self, selector: #selector(configChanged),
            name: .textWaveConfigChanged, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func configChanged() {
        loadConfig() // reconstrói LUT do tema e cache de glifos (texto pode ter mudado)
        needsDisplay = true
    }

    private func buildGlyphCache() {
        glyphCache.removeAll()
        for ch in config.text where glyphCache[ch] == nil {
            // Cor do glifo tirada do contexto (fill color), para permitir
            // tanto o branco do tema Base como as rampas dos temas coloridos.
            let attr = NSAttributedString(string: String(ch), attributes: [
                .font: refFont,
                kCTForegroundColorFromContextAttributeName as NSAttributedString.Key: true,
            ])
            let line = CTLineCreateWithAttributedString(attr)
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            glyphCache[ch] = Glyph(line: line, width: width,
                                   ascent: Double(ascent), descent: Double(descent))
        }
    }

    // MARK: - Ciclo da animação

    public override func animateOneFrame() {
        // time = (time + 10 * direction) % 864e5 — o `%` de JS preserva o sinal,
        // tal como truncatingRemainder. O multiplicador de velocidade do
        // utilizador (0.25x–3x) escala o avanço do relógio.
        let direction: Double = reverse ? -1 : 1
        time = (time + 10 * direction * config.speedMult)
            .truncatingRemainder(dividingBy: 86_400_000)
        needsDisplay = true
    }

    // MARK: - Ruído (jitter de fase; torna o movimento menos regular)

    private static func hash(_ x: Int, _ y: Int) -> Double {
        var h = UInt64(bitPattern: Int64(x)) &* 0x9E3779B97F4A7C15
        h ^= UInt64(bitPattern: Int64(y)) &* 0xC2B2AE3D27D4EB4F
        h = (h ^ (h >> 31)) &* 0xD6E8FEB86659FD93
        h ^= h >> 32
        return Double(h % 100_000) / 50_000.0 - 1.0
    }

    private static func valueNoise(_ x: Double, _ y: Double) -> Double {
        let xf = floor(x), yf = floor(y)
        let xi = Int(xf), yi = Int(yf)
        let fx = x - xf, fy = y - yf
        let sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy)
        let a = hash(xi, yi), b = hash(xi + 1, yi)
        let c = hash(xi, yi + 1), d = hash(xi + 1, yi + 1)
        return a + (b - a) * sx + (c - a) * sy + (a - b - c + d) * sx * sy
    }

    // MARK: - Desenho

    public override func draw(_ rect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let w = Double(bounds.width)
        let h = Double(bounds.height)
        let tile = tileSize

        // Fundo #000000 (em todos os temas)
        ctx.setFillColor(backgroundColorRef)
        ctx.fill(bounds)

        // Grelha (idêntica ao cálculo cols/rows da referência)
        let rawCols = Int(ceil(w / tile))
        let cols = max(1, rawCols) + (rawCols % 2 == 1 ? 1 : 0)
        let rows = max(1, Int(ceil(h / tile)))
        let n = cols * rows

        // Contentor centrado: translate(-50%, -50%) a partir de 50%/50%
        let gridW = Double(cols) * tile
        let gridH = Double(rows) * tile
        let originX = (w - gridW) / 2
        let originYTop = (h - gridH) / 2 // margem no topo, em coordenadas "web" (y para baixo)

        let speedFactor = speed / 25 // --speed-factor
        let phase = (time * speedFactor) / 350
        let textChars = Array(config.text)
        let textLen = max(1, textChars.count)
        let noiseAmp = config.noise
        let themed = !themeLUT.isEmpty

        ctx.setFillColor(baseColor)

        for i in 0..<n {
            let col = i % cols
            let row = i / cols

            // Rácios exactamente como na referência
            let xRatio = Double((i + 1) % cols) / Double(cols + 1)
            let yRatio = Double(rows - row) / Double(rows)

            // --l = sin(absX / cos(sin(absY*2+60)*2.5) * 3 - t*sf/350) + jitter de ruído:
            // campo de value noise a fluir perturba a fase (0..±4.4 rad, configurável;
            // 0 = onda pura) e parte as bandas simétricas em manchas orgânicas.
            let absX = abs(xRatio - 0.5)
            let absY = abs(yRatio - 0.5)
            let jitter = noiseAmp == 0 ? 0 :
                Self.valueNoise(Double(col) * 0.12 + time * 3.0e-5,
                                Double(row) * 0.12 + time * 2.2e-5) * noiseAmp
            let l = sin(absX / cos(sin(absY * 2 + 60) * 2.5) * 3 - phase + jitter)
            let opacity = max(l, 0.05)

            guard let glyph = glyphCache[textChars[i % textLen]] else { continue }

            // Posição da célula (web: y cresce para baixo) → coordenadas AppKit (y para cima)
            let cellLeft = originX + Double(col) * tile
            let cellTopWeb = originYTop + Double(row) * tile
            let cellBottom = h - cellTopWeb - tile

            // Carácter centrado na célula (flex center da referência)
            let tx = cellLeft + (tile - glyph.width) / 2
            let ty = cellBottom + (tile - (glyph.ascent + glyph.descent)) / 2 + glyph.descent

            ctx.saveGState()
            if themed {
                // A opacidade da onda indexa a rampa cold→hot; glifo com alpha 1.
                let idx = min(63, max(0, Int(opacity * 63)))
                ctx.setFillColor(themeLUT[idx])
            } else {
                // Tema Base: branco com alpha = opacidade (comportamento original).
                ctx.setFillColor(baseColor)
                ctx.setAlpha(CGFloat(opacity))
            }
            ctx.textMatrix = .identity
            ctx.textPosition = CGPoint(x: tx, y: ty)
            CTLineDraw(glyph.line, ctx)
            ctx.restoreGState()
        }
    }

    public override func startAnimation() {
        loadConfig()
        super.startAnimation()
    }
    public override func stopAnimation() { super.stopAnimation() }

    // MARK: - Configure sheet

    private var sheet: NSPanel?
    private var themePopup: NSPopUpButton?
    private var textField: NSTextField?
    private var speedSlider: NSSlider?
    private var noiseSlider: NSSlider?

    public override var hasConfigureSheet: Bool { true }

    public override var configureSheet: NSWindow? {
        if let sheet { return sheet }
        loadConfig()

        // Frames fixos, zero autolayout: a sheet é medida e apresentada
        // remotamente (legacyScreenSaver -> Definições do Sistema) antes de
        // qualquer passo de layout; painéis com autolayout colapsam aí.
        let W: CGFloat = 440, H: CGFloat = 212
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                            styleMask: [.titled],
                            backing: .buffered, defer: false)
        panel.title = "Text Wave"
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

        _ = label("Texto:", row: 126)
        let field = NSTextField(string: config.text)
        field.frame = NSRect(x: 180, y: 122, width: 240, height: 24)
        field.placeholderString = "Text Wave"
        content.addSubview(field)

        _ = label("Velocidade:", row: 88)
        let sSlider = slider(config.speedMult, 0.25, 3.0, row: 88)

        _ = label("Ruído (jitter):", row: 56)
        let nSlider = slider(config.noise, 0.0, 4.4, row: 56)

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
        textField = field
        speedSlider = sSlider
        noiseSlider = nSlider
        return panel
    }

    @objc private func sheetOK(_ sender: Any?) {
        if let d = Self.makeDefaults() {
            d.set(themePopup?.indexOfSelectedItem ?? 0, forKey: "theme")
            d.set(speedSlider?.doubleValue ?? 1.0, forKey: "speedMult")
            let text = textField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            d.set(text.isEmpty ? "Text Wave" : text, forKey: "gridText")
            d.set(noiseSlider?.doubleValue ?? 2.2, forKey: "noise")
            d.synchronize()
        }
        NotificationCenter.default.post(name: .textWaveConfigChanged, object: nil)
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
