import ScreenSaver
import AppKit

// Réplica fiel do componente web "line-ripple-background" (originkit.dev, preset `base`).
// Grelha de segmentos curtos orientados por ruído simplex 2D com drift temporal;
// um "cursor" autónomo (Lissajous com rajadas de velocidade) dobra e empurra os
// segmentos com exatamente a mesma física do original (mousemove → substituído).
//
// Parâmetros portados 1:1 do preset:
//   count = 57  → gap = 90 - ((57-1)/99)*82 ≈ 43.62 px
//   movement = 24 → drift = t(ms) * 24 * 8e-6
//   force = 4, resolution = 10 → comprimento do traço = 6 + (10/10)*20 = 26 px
//   strokeColor #FFFFFF, backgroundColor #000000, stroke-width 1.5, linecap round
//   CURL = 3, BASE_ANGLE = 0, SEED = 0.5, easing do ângulo 0.12/frame @60fps

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

    // Constantes do preset `base`
    private let strokeColor = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    private let backgroundColor = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
    private let count = 57.0
    private let movement = 24.0
    private let force = 4.0
    private let resolution = 10.0
    private let curl = 3.0
    private let baseAngle = 0.0

    private struct Point {
        var x: Double
        var y: Double
        var angle: Double = 0
        var cx: Double = 0   // cursor.x (deslocamento)
        var cy: Double = 0
        var cvx: Double = 0  // cursor.vx
        var cvy: Double = 0
    }

    private struct Mouse {
        var x = -10.0, y = 0.0
        var lx = 0.0, ly = 0.0
        var sx = 0.0, sy = 0.0
        var vs = 0.0
        var set = false
    }

    private var noise = SimplexNoise2D(seed: 0.5)
    private var points: [Point] = []
    private var mouse = Mouse()
    private var timeMs: Double = 0
    private var lissajousPhase: Double = 0
    private var builtSize: CGSize = .zero

    public override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1.0 / 60.0
        wantsLayer = true
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        animationTimeInterval = 1.0 / 60.0
        wantsLayer = true
    }

    public override var isFlipped: Bool { true }
    public override var hasConfigureSheet: Bool { false }
    public override var configureSheet: NSWindow? { nil }

    // MARK: setLines (idêntico ao original)

    private func rebuildPointsIfNeeded() {
        let w = Double(bounds.width), h = Double(bounds.height)
        guard w > 0, h > 0 else { return }
        if builtSize == bounds.size, !points.isEmpty { return }
        builtSize = bounds.size

        let c = max(1.0, min(100.0, count))
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

    // MARK: cursor autónomo (substitui mousemove)

    // Lissajous com envelope de velocidade: períodos lentos + rajadas rápidas,
    // imitando o gesto humano que dá origem aos "ripples" na referência.
    private func updateAutonomousMouse(dt: Double) {
        let w = Double(bounds.width), h = Double(bounds.height)
        let t = timeMs / 1000.0
        // rajadas: fator de velocidade 0.35 … ~2.9 (ciclo ~57 s)
        let burst = 0.35 + 2.5 * pow(0.5 + 0.5 * sin(t * 0.11), 3)
        lissajousPhase += burst * dt
        let px = w * (0.5 + 0.40 * sin(lissajousPhase * 0.90 + 0.7))
        let py = h * (0.5 + 0.38 * sin(lissajousPhase * 1.30))
        mouse.x = px
        mouse.y = py
        if !mouse.set {
            mouse.sx = px; mouse.sy = py
            mouse.lx = px; mouse.ly = py
            mouse.set = true
        }
    }

    // MARK: tick (porte de movePoints + suavização do rato)

    public override func animateOneFrame() {
        rebuildPointsIfNeeded()
        let dt = 1.0 / 60.0
        timeMs += dt * 1000.0

        updateAutonomousMouse(dt: dt)

        // suavização exatamente como no tick original
        mouse.sx += (mouse.x - mouse.sx) * 0.1
        mouse.sy += (mouse.y - mouse.sy) * 0.1
        let mdx = mouse.x - mouse.lx
        let mdy = mouse.y - mouse.ly
        let md = (mdx * mdx + mdy * mdy).squareRoot()
        mouse.vs += (md - mouse.vs) * 0.1
        mouse.vs = min(100, mouse.vs)
        mouse.lx = mouse.x
        mouse.ly = mouse.y

        movePoints(time: timeMs)
        needsDisplay = true
    }

    private func movePoints(time: Double) {
        let drift = time * movement * 8e-6
        let dirX = cos(baseAngle) * drift
        let dirY = sin(baseAngle) * drift

        for idx in points.indices {
            var p = points[idx]
            let n = noise.noise(p.x * 0.004 - dirX, p.y * 0.004 - dirY)
            let target = baseAngle + n * Double.pi * curl

            let dx = p.x - mouse.sx
            let dy = p.y - mouse.sy
            let d = (dx * dx + dy * dy).squareRoot()
            let l = max(175.0, mouse.vs)
            var bend = 0.0
            if d < l {  // hover = true no preset
                let s = 1 - d / l
                let influence = (force / 10) * 0.02
                let tangent = atan2(dy, dx) + Double.pi / 2
                bend = (tangent - target) * s * (0.4 + mouse.vs * influence)

                let f = cos(d * 0.001) * s
                let push = (force / 10) * 7e-4
                let ang = atan2(dy, dx)
                p.cvx += cos(ang) * f * l * mouse.vs * push
                p.cvy += sin(ang) * f * l * mouse.vs * push
            }

            var diff = target + bend - p.angle
            while diff > Double.pi { diff -= 2 * Double.pi }
            while diff < -Double.pi { diff += 2 * Double.pi }
            p.angle += diff * 0.12

            p.cvx += (0 - p.cx) * 0.01
            p.cvy += (0 - p.cy) * 0.01
            p.cvx *= 0.95
            p.cvy *= 0.95
            p.cx += p.cvx
            p.cy += p.cvy
            p.cx = min(50, max(-50, p.cx))
            p.cy = min(50, max(-50, p.cy))

            points[idx] = p
        }
    }

    // MARK: draw (porte de drawLines)

    public override func draw(_ rect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        ctx.setFillColor(backgroundColor.cgColor)
        ctx.fill(bounds)

        let half = (6 + (resolution / 10) * 20) / 2  // = 13 → traço de 26 px
        ctx.setStrokeColor(strokeColor.cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineCap(.round)

        let path = CGMutablePath()
        for p in points {
            let cx = p.x + p.cx
            let cy = p.y + p.cy
            let ux = cos(p.angle) * half
            let uy = sin(p.angle) * half
            path.move(to: CGPoint(x: cx - ux, y: cy - uy))
            path.addLine(to: CGPoint(x: cx + ux, y: cy + uy))
        }
        ctx.addPath(path)
        ctx.strokePath()
    }

    public override func startAnimation() {
        super.startAnimation()
        rebuildPointsIfNeeded()
    }
}
