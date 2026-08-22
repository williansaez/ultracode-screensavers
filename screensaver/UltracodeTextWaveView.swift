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

import ScreenSaver
import AppKit
import CoreText

final class UltracodeTextWaveView: ScreenSaverView {

    // MARK: - Parâmetros do preset `base` (portados 1:1)

    private let gridText = "Text Wave"
    private let speed: Double = 61
    private let reverse = true
    private let gap: Double = 10
    private let fontSize: Double = 14
    private let backgroundColorRef = CGColor(red: 0, green: 0, blue: 0, alpha: 1) // #000000
    private let baseColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1)         // #FFFFFF

    private var tileSize: Double { max(fontSize, 10) + gap } // 24

    // Relógio da animação (igual ao updateTime da referência)
    private var time: Double = 0

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

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1.0 / 30.0 // frameInterval = 1000/30 na referência
        buildGlyphCache()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        animationTimeInterval = 1.0 / 30.0
        buildGlyphCache()
    }

    private func buildGlyphCache() {
        glyphCache.removeAll()
        for ch in gridText where glyphCache[ch] == nil {
            let attr = NSAttributedString(string: String(ch), attributes: [
                .font: refFont,
                .foregroundColor: NSColor.white,
            ])
            let line = CTLineCreateWithAttributedString(attr)
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            glyphCache[ch] = Glyph(line: line, width: width,
                                   ascent: Double(ascent), descent: Double(descent))
        }
    }

    // MARK: - Ciclo da animação

    override func animateOneFrame() {
        // time = (time + 10 * direction) % 864e5 — o `%` de JS preserva o sinal,
        // tal como truncatingRemainder.
        let direction: Double = reverse ? -1 : 1
        time = (time + 10 * direction).truncatingRemainder(dividingBy: 86_400_000)
        needsDisplay = true
    }

    override var hasConfigureSheet: Bool { false }
    override var configureSheet: NSWindow? { nil }

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

    override func draw(_ rect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let w = Double(bounds.width)
        let h = Double(bounds.height)
        let tile = tileSize

        // Fundo #000000
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
        let textChars = Array(gridText)
        let textLen = max(1, textChars.count)

        ctx.setFillColor(baseColor)

        for i in 0..<n {
            let col = i % cols
            let row = i / cols

            // Rácios exactamente como na referência
            let xRatio = Double((i + 1) % cols) / Double(cols + 1)
            let yRatio = Double(rows - row) / Double(rows)

            // --l = sin(absX / cos(sin(absY*2+60)*2.5) * 3 - t*sf/350) + jitter de ruído:
            // campo de value noise a fluir perturba a fase (±2.2 rad) e parte as
            // bandas simétricas em manchas orgânicas.
            let absX = abs(xRatio - 0.5)
            let absY = abs(yRatio - 0.5)
            let jitter = Self.valueNoise(Double(col) * 0.12 + time * 3.0e-5,
                                         Double(row) * 0.12 + time * 2.2e-5) * 2.2
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
            ctx.setAlpha(CGFloat(opacity))
            ctx.textMatrix = .identity
            ctx.textPosition = CGPoint(x: tx, y: ty)
            CTLineDraw(glyph.line, ctx)
            ctx.restoreGState()
        }
    }

    override func startAnimation() { super.startAnimation() }
    override func stopAnimation() { super.stopAnimation() }
}
