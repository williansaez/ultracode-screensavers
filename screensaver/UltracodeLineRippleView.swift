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
    private let resolution = 10.0
    private let curl = 3.0
    private let baseAngle = 0.0

    private struct Point {
        var x: Double
        var y: Double
        var angle: Double = 0
    }

    private var noise = SimplexNoise2D(seed: 0.5)
    private var points: [Point] = []
    private var timeMs: Double = 0
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

    // MARK: tick (porte de movePoints)

    public override func animateOneFrame() {
        rebuildPointsIfNeeded()
        timeMs += 1000.0 / 60.0
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

            var diff = target - p.angle
            while diff > Double.pi { diff -= 2 * Double.pi }
            while diff < -Double.pi { diff += 2 * Double.pi }
            p.angle += diff * 0.12

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
            let ux = cos(p.angle) * half
            let uy = sin(p.angle) * half
            path.move(to: CGPoint(x: p.x - ux, y: p.y - uy))
            path.addLine(to: CGPoint(x: p.x + ux, y: p.y + uy))
        }
        ctx.addPath(path)
        ctx.strokePath()
    }

    public override func startAnimation() {
        super.startAnimation()
        rebuildPointsIfNeeded()
    }
}
