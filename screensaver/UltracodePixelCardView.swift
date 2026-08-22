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
    private let gap: Double = 6
    private let pixelSize: Double = 2
    private let presetSpeed: Double = 80          // → efetivo 0.16 via throttle 0.002
    private let durationMs: Double = 800          // transition.duration 0.8 s
    private let easeFn = cubicBezier(0, 0, 0.58, 1) // "easeOut"
    private let cardBackground = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)          // #000000
    // Paleta do preset: rgba(255,255,255,1), rgba(255,255,255,0.8), rgba(255,255,255,0.6)
    private let paletteAlphas: [CGFloat] = [1.0, 0.8, 0.6]

    // Sem ciclo: aparece uma vez (varrimento radial) e fica em shimmer perpétuo.
    private var nowMs: Double = 0             // relógio de simulação (1000/60 por frame)

    private var pixels: [PCPixel] = []
    private var cardRect: CGRect = .zero
    private var builtForSize: CGSize = .zero

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1.0 / 60.0
        wantsLayer = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        animationTimeInterval = 1.0 / 60.0
    }

    override var hasConfigureSheet: Bool { false }
    override var configureSheet: NSWindow? { nil }

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
        let effSpeed = min(max(presetSpeed, 0), 100) * 0.002   // getEffectiveSpeed
        var pxs: [PCPixel] = []
        pxs.reserveCapacity(Int(w / gap + 1) * Int(h / gap + 1))
        var idx = 0
        var x: Double = 0
        while x < w {
            var y: Double = 0
            while y < h {
                let colorIndex = idx % paletteAlphas.count
                idx += 1
                // appearFrom = "middle"
                let dx = x - w / 2
                let dy = y - h / 2
                let delay = (dx * dx + dy * dy).squareRoot()
                pxs.append(PCPixel(canvasW: w, canvasH: h, x: x, y: y,
                                   colorIndex: colorIndex, speed: effSpeed,
                                   delay: delay, maxPx: max(0.1, pixelSize)))
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
        for (i, alpha) in paletteAlphas.enumerated() where !rectsByColor[i].isEmpty {
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha))
            ctx.fill(rectsByColor[i])
        }
    }

    override func startAnimation() { super.startAnimation() }
    override func stopAnimation() { super.stopAnimation() }
}
