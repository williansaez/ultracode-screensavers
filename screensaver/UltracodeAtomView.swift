import AppKit
import ScreenSaver

private extension Notification.Name {
    static let atomConfigChanged = Notification.Name("UltracodeAtomConfigChanged")
}

@objc(UltracodeAtomView)
public final class UltracodeAtomView: ScreenSaverView {

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

    /// Suite-wide contrast accent: lavanda -> amarelo, Doom -> azul,
    /// Matrix -> vermelho. Used by anything that must pop from the ramp.
    private func contrastAccent(forTheme t: Int) -> RGB {
        switch t {
        case 1: return RGB(0x3A8DFF)
        case 2: return RGB(0xFF453A)
        default: return RGB(0xFFD60A)
        }
    }

    // MARK: - User configuration

    private struct Config {
        var theme = 0
        var pitch: Double = 26
        var fps: Double = 30
        var floor: Double = 0.10  // empty-cell brightness on the theme ramp
        var bloom = true
    }

    private static let moduleName = "com.williansaez.ultracode-atom"

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

    private var trailColors: [NSColor] = []
    private var floorColor: NSColor = .black
    private var electronColor: NSColor = .white
    private let trailLevels = 64

    /// Pre-rendered empty lattice (bg gradient + every cell at the floor
    /// brightness), blitted as the first drawing step each frame instead of
    /// filling thousands of floor cells individually.
    private var floorImage: CGImage?
    private var floorImageSize = NSSize.zero

    // MARK: - Atom simulation (Rutherford rosette, lattice-aligned)

    // Modeled on the classic Rutherford atom illustration: a NUCLEUS CLUSTER
    // of many packed cells (protons in the contrast accent + neutrons in the
    // bright theme color) that jiggles alive, surrounded by a ROSETTE of
    // ellipses at evenly distributed tilts whose full paths stay visible as
    // faint rings, with accent-colored electrons traveling along them.
    // Everything is rendered snapped to the cell lattice. It starts as
    // hydrogen (1 electron, its ring); after 5 s a second electron flies in
    // from off-screen, is captured and its ring fades in. Arrivals continue
    // every 6-12 s up to 10; at the cap the outermost electron is ejected
    // and its ring fades out — the atom breathes forever.

    private struct Electron {
        var a: Float            // semi-major axis (cells)
        var b: Float            // semi-minor axis
        var w: Float            // angular speed (rad/frame)
        var phase: Float
        var tilt: Float         // rosette orientation
        var ringAlpha: Float    // 0..1, fades in on capture / out on eject
        var inFrames: Int       // >0: incoming capture flight
        var inTotal: Int
        var sx: Float, sy: Float
        var cxp: Float, cyp: Float
        var outFrames: Int      // >0: escaping
        var ox: Float, oy: Float
        var lastX: Float, lastY: Float
    }

    private var electrons: [Electron] = []
    private var trail: [Float] = []          // comet trails behind the heads
    private let trailDecay: Float = 0.90
    private var rosettePrec: Float = 0       // slow global rosette rotation

    /// Proton slots in packing order (closest to center first). The first
    /// `protonCount` are drawn — 1 proton per electron, always.
    private var protonOrder: [(Int, Int)] = []
    private var protonCount = 1
    private var nucX = 0
    private var nucY = 0
    private var orbitA: Float = 14
    private var orbitB: Float = 6

    private var framesToNextArrival = 0
    private var frameCount = 0

    private var rngState: UInt64 = 0x9E3779B97F4A7C15
    private func nextRand() -> UInt64 {
        rngState ^= rngState << 13
        rngState ^= rngState >> 7
        rngState ^= rngState << 17
        return rngState
    }
    private func randF() -> Float { Float(nextRand() >> 40) / Float(1 << 24) }

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
        let seed = UInt64(Date().timeIntervalSince1970 * 1000)
        if seed != 0 { rngState = seed }
        loadConfig()
        NotificationCenter.default.addObserver(
            self, selector: #selector(configChanged),
            name: .atomConfigChanged, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func configChanged() {
        loadConfig()
        rebuildGrid()
        needsDisplay = true
    }

    // MARK: - Layout

    private func rebuildGrid() {
        pitch = isPreview ? 9 : CGFloat(config.pitch)
        cellSide = pitch * 0.70
        cols = max(8, Int(bounds.width / pitch) + 2)
        rows = max(8, Int(bounds.height / pitch) + 2)
        originX = (bounds.width - CGFloat(cols - 1) * pitch) / 2
        originY = (bounds.height - CGFloat(rows - 1) * pitch) / 2

        let stops = Self.themes[config.theme].stops.map(RGB.init)
        // Configurable empty-cell floor; trails span floor -> 0.90 so the
        // lit end of the ramp is unchanged regardless of the floor setting.
        let f = CGFloat(config.floor)
        let bgMid = RGB.lerp(bgTop, bgBottom, 0.5)
        // The theme ramp bottoms out at its coldest stop, which is brighter
        // than the background; below that band fade toward the background so
        // floor 0 makes empty cells invisible. At the default floor 0.10 the
        // fade branch never runs.
        func floorRamp(_ b: CGFloat) -> RGB {
            if b < 0.10 {
                return RGB.lerp(bgMid, ramp(0.10, stops: stops), b / 0.10)
            }
            return ramp(b, stops: stops)
        }
        floorColor = floorRamp(f).color
        trailColors = (0..<trailLevels).map { k in
            let t = CGFloat(k) / CGFloat(trailLevels - 1)
            return floorRamp(f + (0.90 - f) * t).color
        }
        electronColor = ramp(1.0, stops: stops).color

        nucX = cols / 2
        nucY = rows / 2
        let short = Float(min(cols, rows))
        // One big rosette like the reference: all ellipses similar size,
        // tilts spread evenly.
        orbitA = short * 0.42
        orbitB = short * 0.17

        protonRadius = 3
        buildProtonOrder()
        protonCount = 1                          // hydrogen: 1 p+ for 1 e-

        trail = .init(repeating: 0, count: cols * rows)
        electrons.removeAll(keepingCapacity: true)
        var first = makeOrbitElements(slot: 0)
        first.ringAlpha = 1
        electrons.append(first)                 // hydrogen: 1 e- in orbit
        frameCount = 0
        rosettePrec = 0
        framesToNextArrival = Int(config.fps * 5.0)   // 2nd e- after 5 s

        rebuildFloorImage()
    }

    /// Renders the whole empty lattice once (Retina scale) so draw() can
    /// blit it instead of filling ~cols*rows floor cells per frame. Rebuilt
    /// by rebuildGrid() on resize/config change, so the floor slider works.
    private func rebuildFloorImage() {
        floorImage = nil
        floorImageSize = bounds.size
        let scale = window?.backingScaleFactor ?? 2
        let pw = max(1, Int(bounds.width * scale))
        let ph = max(1, Int(bounds.height * scale))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pw, height: ph,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        ctx.scaleBy(x: scale, y: scale)

        // Same gradient as drawBackground().
        let colors = [bgTop.color.cgColor, bgBottom.color.cgColor] as CFArray
        if let grad = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(grad,
                                   start: CGPoint(x: 0, y: bounds.height),
                                   end: CGPoint(x: 0, y: 0),
                                   options: [])
        } else {
            ctx.setFillColor(bgTop.color.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height))
        }

        // Every cell at the floor brightness, in one batched fill.
        let radius = cellSide * 0.28
        let path = CGMutablePath()
        for j in 0..<rows {
            let cy = originY + CGFloat(j) * pitch
            for i in 0..<cols {
                let cx = originX + CGFloat(i) * pitch
                let rect = CGRect(x: cx - cellSide / 2, y: cy - cellSide / 2,
                                  width: cellSide, height: cellSide)
                path.addPath(CGPath(roundedRect: rect, cornerWidth: radius,
                                    cornerHeight: radius, transform: nil))
            }
        }
        ctx.setFillColor(floorColor.cgColor)
        ctx.addPath(path)
        ctx.fillPath()

        floorImage = ctx.makeImage()
    }

    /// Proton packing order: lattice offsets sorted center-out, so the
    /// cluster grows compactly as electrons (and their protons) arrive.
    /// Rebuilt with a larger radius whenever the cluster outgrows it —
    /// there is no ceiling.
    private var protonRadius = 3

    private func buildProtonOrder() {
        var offs: [(Int, Int)] = []
        let ri = protonRadius
        for dy in -ri...ri {
            for dx in -ri...ri {
                offs.append((dx, dy))
            }
        }
        offs.sort {
            let d0 = $0.0 * $0.0 + $0.1 * $0.1
            let d1 = $1.0 * $1.0 + $1.1 * $1.1
            if d0 != d1 { return d0 < d1 }
            // Stable angular tiebreak inside each shell.
            return atan2(Float($0.1), Float($0.0)) < atan2(Float($1.1), Float($1.0))
        }
        protonOrder = offs
    }

    private func ensureProtonCapacity(_ n: Int) {
        while protonOrder.count < n {
            protonRadius += 2
            buildProtonOrder()
        }
    }

    private func makeOrbitElements(slot: Int) -> Electron {
        // Rosette tilt: golden-angle spacing stays evenly spread no matter
        // how many electrons accumulate (there is no cap).
        let tilt = Float(slot) * 2.39996323
        let a = orbitA * (0.96 + randF() * 0.08)
        let b = orbitB * (0.92 + randF() * 0.16)
        let speed: Float = 0.044 * (0.9 + randF() * 0.2)
        return Electron(
            a: a, b: b, w: speed,
            phase: randF() * 2 * .pi,
            tilt: tilt,
            ringAlpha: 0,
            inFrames: 0, inTotal: 0,
            sx: 0, sy: 0, cxp: 0, cyp: 0,
            outFrames: 0, ox: 0, oy: 0,
            lastX: 0, lastY: 0)
    }

    private func orbitPos(_ e: Electron) -> (Float, Float) {
        let px = e.a * cos(e.phase)
        let py = e.b * sin(e.phase)
        let t = e.tilt + rosettePrec
        let ct = cos(t), st = sin(t)
        return (px * ct - py * st, px * st + py * ct)
    }

    private func spawnIncoming() {
        var e = makeOrbitElements(slot: electrons.count)
        let fc = Float(cols), fr = Float(rows)
        let edge = Int(nextRand() % 4)
        let m: Float = 6
        switch edge {
        case 0:  e.sx = -fc / 2 - m;            e.sy = (randF() - 0.5) * fr
        case 1:  e.sx = fc / 2 + m;             e.sy = (randF() - 0.5) * fr
        case 2:  e.sx = (randF() - 0.5) * fc;   e.sy = -fr / 2 - m
        default: e.sx = (randF() - 0.5) * fc;   e.sy = fr / 2 + m
        }
        e.inTotal = Int(config.fps * 1.6)
        e.inFrames = e.inTotal
        e.cxp = e.sx * 0.18
        e.cyp = e.sy * 0.18
        electrons.append(e)
    }

    // MARK: - Exclusion force (nucleus must never reach the orbit zone)

    /// Cluster radius for a given proton count (outermost packed slot).
    private func nucleusRadius(_ count: Int) -> Float {
        guard count > 0 else { return 0 }
        ensureProtonCapacity(count)
        let (dx, dy) = protonOrder[count - 1]
        return sqrt(Float(dx * dx + dy * dy)) + 0.5
    }

    /// Closest approach of the tightest possible orbit (b varies 0.92-1.08).
    private var minOrbitClearance: Float { orbitB * 0.85 }
    private let nucleusGap: Float = 1.5    // cells of forced clearance

    /// The exclusion force fired: the innermost settled electron is repelled
    /// radially out of the atom and takes its proton with it (1:1), shrinking
    /// the nucleus back below the orbit zone — the equilibrium point.
    private func repelInnermost() {
        guard protonCount > 1,
              let idx = electrons.indices
                .filter({ electrons[$0].inFrames == 0 && electrons[$0].outFrames == 0 })
                .min(by: { electrons[$0].b < electrons[$1].b }) else { return }
        var e = electrons[idx]
        let x = e.lastX, y = e.lastY
        let len = max(1e-3, sqrt(x * x + y * y))
        e.outFrames = 1
        e.ox = x / len * 0.45              // shove straight away from the nucleus
        e.oy = y / len * 0.45
        electrons[idx] = e
        protonCount = max(1, protonCount - 1)
    }

    // MARK: - Frame

    public override func animateOneFrame() {
        if trail.isEmpty { rebuildGrid() }
        frameCount += 1
        rosettePrec += 0.0009          // the whole rosette turns, slowly

        framesToNextArrival -= 1
        if framesToNextArrival <= 0 {
            spawnIncoming()
            framesToNextArrival = Int(config.fps * (6.0 + 6.0 * Double(randF())))
        }

        // Exclusion check: if the proton cluster has grown to within the
        // forced gap of the innermost orbit (easy on small views), repel one
        // electron per frame until nucleus and orbits no longer collide.
        if nucleusRadius(protonCount) + nucleusGap >= minOrbitClearance {
            repelInnermost()
        }

        for i in 0..<trail.count { trail[i] *= trailDecay }

        var keep: [Electron] = []
        keep.reserveCapacity(electrons.count)
        for var e in electrons {
            var x: Float, y: Float
            if e.outFrames > 0 {
                e.outFrames += 1
                e.ox *= 1.06; e.oy *= 1.06
                x = e.lastX + e.ox
                y = e.lastY + e.oy
                e.lastX = x; e.lastY = y
                e.ringAlpha = max(0, e.ringAlpha - 0.04)   // ring fades out
                if abs(x) > Float(cols) || abs(y) > Float(rows) { continue }
            } else if e.inFrames > 0 {
                e.inFrames -= 1
                e.phase += e.w
                let (tx, ty) = orbitPos(e)
                let t = 1 - Float(e.inFrames) / Float(max(1, e.inTotal))
                let u = t * t * (3 - 2 * t)
                let omu = 1 - u
                x = omu * omu * e.sx + 2 * omu * u * e.cxp + u * u * tx
                y = omu * omu * e.sy + 2 * omu * u * e.cyp + u * u * ty
                e.ringAlpha = min(1, u + 0.1)              // ring fades in
                if e.inFrames == 0 {
                    // Captured: the nucleus gains its matching proton (1:1).
                    protonCount += 1
                    ensureProtonCapacity(protonCount)
                }
            } else {
                e.phase += e.w
                (x, y) = orbitPos(e)
                e.ringAlpha = min(1, e.ringAlpha + 0.02)
            }

            let gx = nucX + Int(x.rounded())
            let gy = nucY + Int(y.rounded())
            if gx >= 0 && gx < cols && gy >= 0 && gy < rows {
                trail[gy * cols + gx] = 1.0
            }
            e.lastX = x; e.lastY = y
            keep.append(e)
        }
        electrons = keep

        if tilePop > 0.01 { tilePop *= 0.86 } else { tilePop = 0 }

        needsDisplay = true
    }

    /// Harness hooks.
    @objc public var debugElectronCount: Int { electrons.count }
    @objc public func debugForceArrival() { framesToNextArrival = 1 }

    // MARK: - Periodic table + info tile

    private struct Element {
        let sym: String, name: String, mass: String
        init(_ sym: String, _ name: String, _ mass: String) {
            self.sym = sym; self.name = name; self.mass = mass
        }
    }

    /// Z = 1..118 (índice = Z-1). Nomes em português, massa atómica padrão
    /// (sintéticos = isótopo mais estável, entre parênteses retos).
    private static let elements: [Element] = [
        Element("H", "Hidrogênio", "1,008"), Element("He", "Hélio", "4,003"),
        Element("Li", "Lítio", "6,94"), Element("Be", "Berílio", "9,012"),
        Element("B", "Boro", "10,81"), Element("C", "Carbono", "12,011"),
        Element("N", "Nitrogênio", "14,007"), Element("O", "Oxigênio", "15,999"),
        Element("F", "Flúor", "18,998"), Element("Ne", "Neônio", "20,180"),
        Element("Na", "Sódio", "22,990"), Element("Mg", "Magnésio", "24,305"),
        Element("Al", "Alumínio", "26,982"), Element("Si", "Silício", "28,085"),
        Element("P", "Fósforo", "30,974"), Element("S", "Enxofre", "32,06"),
        Element("Cl", "Cloro", "35,45"), Element("Ar", "Argônio", "39,95"),
        Element("K", "Potássio", "39,098"), Element("Ca", "Cálcio", "40,078"),
        Element("Sc", "Escândio", "44,956"), Element("Ti", "Titânio", "47,867"),
        Element("V", "Vanádio", "50,942"), Element("Cr", "Cromo", "51,996"),
        Element("Mn", "Manganês", "54,938"), Element("Fe", "Ferro", "55,845"),
        Element("Co", "Cobalto", "58,933"), Element("Ni", "Níquel", "58,693"),
        Element("Cu", "Cobre", "63,546"), Element("Zn", "Zinco", "65,38"),
        Element("Ga", "Gálio", "69,723"), Element("Ge", "Germânio", "72,630"),
        Element("As", "Arsênio", "74,922"), Element("Se", "Selênio", "78,971"),
        Element("Br", "Bromo", "79,904"), Element("Kr", "Criptônio", "83,798"),
        Element("Rb", "Rubídio", "85,468"), Element("Sr", "Estrôncio", "87,62"),
        Element("Y", "Ítrio", "88,906"), Element("Zr", "Zircônio", "91,224"),
        Element("Nb", "Nióbio", "92,906"), Element("Mo", "Molibdênio", "95,95"),
        Element("Tc", "Tecnécio", "[98]"), Element("Ru", "Rutênio", "101,07"),
        Element("Rh", "Ródio", "102,91"), Element("Pd", "Paládio", "106,42"),
        Element("Ag", "Prata", "107,87"), Element("Cd", "Cádmio", "112,41"),
        Element("In", "Índio", "114,82"), Element("Sn", "Estanho", "118,71"),
        Element("Sb", "Antimônio", "121,76"), Element("Te", "Telúrio", "127,60"),
        Element("I", "Iodo", "126,90"), Element("Xe", "Xenônio", "131,29"),
        Element("Cs", "Césio", "132,91"), Element("Ba", "Bário", "137,33"),
        Element("La", "Lantânio", "138,91"), Element("Ce", "Cério", "140,12"),
        Element("Pr", "Praseodímio", "140,91"), Element("Nd", "Neodímio", "144,24"),
        Element("Pm", "Promécio", "[145]"), Element("Sm", "Samário", "150,36"),
        Element("Eu", "Európio", "151,96"), Element("Gd", "Gadolínio", "157,25"),
        Element("Tb", "Térbio", "158,93"), Element("Dy", "Disprósio", "162,50"),
        Element("Ho", "Hólmio", "164,93"), Element("Er", "Érbio", "167,26"),
        Element("Tm", "Túlio", "168,93"), Element("Yb", "Itérbio", "173,05"),
        Element("Lu", "Lutécio", "174,97"), Element("Hf", "Háfnio", "178,49"),
        Element("Ta", "Tântalo", "180,95"), Element("W", "Tungstênio", "183,84"),
        Element("Re", "Rênio", "186,21"), Element("Os", "Ósmio", "190,23"),
        Element("Ir", "Irídio", "192,22"), Element("Pt", "Platina", "195,08"),
        Element("Au", "Ouro", "196,97"), Element("Hg", "Mercúrio", "200,59"),
        Element("Tl", "Tálio", "204,38"), Element("Pb", "Chumbo", "207,2"),
        Element("Bi", "Bismuto", "208,98"), Element("Po", "Polônio", "[209]"),
        Element("At", "Astato", "[210]"), Element("Rn", "Radônio", "[222]"),
        Element("Fr", "Frâncio", "[223]"), Element("Ra", "Rádio", "[226]"),
        Element("Ac", "Actínio", "[227]"), Element("Th", "Tório", "232,04"),
        Element("Pa", "Protactínio", "231,04"), Element("U", "Urânio", "238,03"),
        Element("Np", "Netúnio", "[237]"), Element("Pu", "Plutônio", "[244]"),
        Element("Am", "Amerício", "[243]"), Element("Cm", "Cúrio", "[247]"),
        Element("Bk", "Berquélio", "[247]"), Element("Cf", "Califórnio", "[251]"),
        Element("Es", "Einstênio", "[252]"), Element("Fm", "Férmio", "[257]"),
        Element("Md", "Mendelévio", "[258]"), Element("No", "Nobélio", "[259]"),
        Element("Lr", "Laurêncio", "[266]"), Element("Rf", "Rutherfórdio", "[267]"),
        Element("Db", "Dúbnio", "[268]"), Element("Sg", "Seabórgio", "[269]"),
        Element("Bh", "Bóhrio", "[270]"), Element("Hs", "Hássio", "[269]"),
        Element("Mt", "Meitnério", "[278]"), Element("Ds", "Darmstácio", "[281]"),
        Element("Rg", "Roentgênio", "[282]"), Element("Cn", "Copernício", "[285]"),
        Element("Nh", "Nihônio", "[286]"), Element("Fl", "Fleróvio", "[289]"),
        Element("Mc", "Moscóvio", "[290]"), Element("Lv", "Livermório", "[293]"),
        Element("Ts", "Tenesso", "[294]"), Element("Og", "Oganessônio", "[294]"),
    ]

    private var tileImage: CGImage?
    private var tileZ = 0
    private var tileThemeKey = -1
    private var tileSize = NSSize.zero
    private var tileScaleKey: CGFloat = 0
    private var tilePop: CGFloat = 0     // brief scale bump when the element changes

    private func currentZ() -> Int { min(Self.elements.count, max(1, protonCount)) }

    /// Top-left tile rect (view coords, y-up), scaled to the view.
    private func elementTileRect() -> CGRect {
        let s = min(bounds.width, bounds.height)
        let w = min(212, max(132, s * 0.17))
        let h = w * 1.16
        let m = max(16, w * 0.18)
        return CGRect(x: m, y: bounds.height - h - m, width: w, height: h)
    }

    private func attrSize(_ s: String, _ f: NSFont) -> NSSize {
        (s as NSString).size(withAttributes: [.font: f])
    }
    private func drawText(_ s: String, _ f: NSFont, _ c: NSColor, at p: CGPoint) {
        (s as NSString).draw(at: p, withAttributes: [.font: f, .foregroundColor: c])
    }

    /// Renders the element info tile with an Apple "liquid glass" look:
    /// frosted translucent panel, top specular streak, bright top border,
    /// accent under-glow, drop shadow. Cached per (Z, theme, size, scale).
    private func makeElementTile(z: Int, size: NSSize, scale: CGFloat) -> CGImage? {
        let W = size.width, H = size.height
        let pxW = max(1, Int((W * scale).rounded(.up)))
        let pxH = max(1, Int((H * scale).rounded(.up)))
        guard z >= 1, z <= Self.elements.count,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pxW, height: pxH,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns

        let inset: CGFloat = 9
        let body = CGRect(x: inset, y: inset, width: W - 2 * inset, height: H - 2 * inset)
        let r = body.width * 0.24
        let path = NSBezierPath(roundedRect: body, xRadius: r, yRadius: r)
        let acc = contrastAccent(forTheme: config.theme)

        // Drop shadow.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 18,
                      color: NSColor(white: 0, alpha: 0.5).cgColor)
        NSColor(white: 1, alpha: 0.06).setFill()
        path.fill()
        ctx.restoreGState()

        // Frosted body + accent under-glow + top specular streak (clipped).
        ctx.saveGState()
        path.addClip()
        if let g = CGGradient(colorsSpace: space, colors: [
            NSColor(white: 1, alpha: 0.20).cgColor,
            NSColor(white: 1, alpha: 0.06).cgColor,
            NSColor(white: 1, alpha: 0.02).cgColor] as CFArray, locations: [0, 0.5, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: body.midX, y: body.maxY),
                                   end: CGPoint(x: body.midX, y: body.minY), options: [])
        }
        if let ag = CGGradient(colorsSpace: space, colors: [
            NSColor(srgbRed: acc.r, green: acc.g, blue: acc.b, alpha: 0.16).cgColor,
            NSColor(srgbRed: acc.r, green: acc.g, blue: acc.b, alpha: 0).cgColor] as CFArray,
            locations: [0, 1]) {
            let c = CGPoint(x: body.midX, y: body.minY + body.height * 0.26)
            ctx.drawRadialGradient(ag, startCenter: c, startRadius: 0,
                                   endCenter: c, endRadius: body.width * 0.7, options: [])
        }
        let streak = NSBezierPath(roundedRect: CGRect(
            x: body.minX + body.width * 0.12, y: body.maxY - body.height * 0.11,
            width: body.width * 0.76, height: body.height * 0.05), xRadius: 6, yRadius: 6)
        NSColor(white: 1, alpha: 0.38).setFill()
        streak.fill()
        ctx.restoreGState()

        // Borders: subtle all around, brighter on the top half.
        path.lineWidth = 1.2
        NSColor(white: 1, alpha: 0.22).setStroke()
        path.stroke()
        ctx.saveGState()
        NSBezierPath(rect: CGRect(x: body.minX - 2, y: body.midY,
                                  width: body.width + 4, height: body.height / 2 + 4)).addClip()
        path.lineWidth = 1.4
        NSColor(white: 1, alpha: 0.5).setStroke()
        path.stroke()
        ctx.restoreGState()

        // Text.
        let el = Self.elements[z - 1]
        let white = NSColor(white: 1, alpha: 0.95)
        let dim = NSColor(white: 1, alpha: 0.62)
        let accColor = NSColor(srgbRed: min(1, acc.r * 1.15), green: min(1, acc.g * 1.15),
                               blue: min(1, acc.b * 1.15), alpha: 1)
        let pad = body.width * 0.12

        let numF = NSFont.systemFont(ofSize: body.width * 0.15, weight: .semibold)
        drawText("\(z)", numF, white,
                 at: CGPoint(x: body.minX + pad,
                             y: body.maxY - pad * 0.7 - attrSize("\(z)", numF).height))

        let massF = NSFont.systemFont(ofSize: body.width * 0.11, weight: .regular)
        let ms = attrSize(el.mass, massF)
        drawText(el.mass, massF, dim,
                 at: CGPoint(x: body.maxX - pad - ms.width,
                             y: body.maxY - pad * 0.7 - ms.height))

        let symF = NSFont.systemFont(ofSize: body.width * 0.42, weight: .bold)
        let ss = attrSize(el.sym, symF)
        drawText(el.sym, symF, accColor,
                 at: CGPoint(x: body.midX - ss.width / 2,
                             y: body.minY + body.height * 0.40 - ss.height / 2))

        var nameF = NSFont.systemFont(ofSize: body.width * 0.115, weight: .medium)
        var nm = attrSize(el.name, nameF)
        if nm.width > body.width - pad {     // shrink long names to fit
            nameF = NSFont.systemFont(ofSize: body.width * 0.115 * (body.width - pad) / nm.width,
                                      weight: .medium)
            nm = attrSize(el.name, nameF)
        }
        drawText(el.name, nameF, white,
                 at: CGPoint(x: body.midX - nm.width / 2, y: body.minY + pad * 0.7))

        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    private func drawElementTile(_ ctx: CGContext) {
        guard !isPreview, bounds.width >= 240 else { return }
        let z = currentZ()
        let rect = elementTileRect()
        let scale = window?.backingScaleFactor ?? 2
        if tileImage == nil || z != tileZ || config.theme != tileThemeKey
            || tileSize != rect.size || tileScaleKey != scale {
            if z != tileZ && tileZ != 0 { tilePop = 1 }   // element changed: pop
            tileImage = makeElementTile(z: z, size: rect.size, scale: scale)
            tileZ = z; tileThemeKey = config.theme
            tileSize = rect.size; tileScaleKey = scale
        }
        guard let img = tileImage else { return }
        let p = 1 + 0.06 * tilePop
        let drawRect = rect.insetBy(dx: -rect.width * (p - 1) / 2,
                                    dy: -rect.height * (p - 1) / 2)
        ctx.draw(img, in: drawRect)
    }

    // MARK: - Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if trail.isEmpty || floorImage == nil || floorImageSize != bounds.size {
            rebuildGrid()
        }

        // Floor blit: bg gradient + every cell at floor brightness, prebuilt.
        if let floorImage {
            ctx.draw(floorImage, in: bounds)
        } else {
            drawBackground(ctx)
        }

        // Comet trails above the floor blit, batched: ONE fill per quantized
        // level instead of one path per cell. Floor-level cells are skipped
        // (the blit already shows them).
        let radius = cellSide * 0.28
        var levelPaths = [CGMutablePath?](repeating: nil, count: trailLevels)
        for j in 0..<rows {
            let cy = originY + CGFloat(j) * pitch
            let rowBase = j * cols
            for i in 0..<cols {
                let v = trail[rowBase + i]
                let lvl = min(trailLevels - 1, max(0, Int(CGFloat(v) * CGFloat(trailLevels - 1))))
                if lvl <= 1 { continue }            // floor: already blitted
                let cx = originX + CGFloat(i) * pitch
                let rect = CGRect(x: cx - cellSide / 2, y: cy - cellSide / 2,
                                  width: cellSide, height: cellSide)
                let p = levelPaths[lvl] ?? CGMutablePath()
                p.addPath(CGPath(roundedRect: rect, cornerWidth: radius,
                                 cornerHeight: radius, transform: nil))
                levelPaths[lvl] = p
            }
        }
        for lvl in 2..<trailLevels {
            guard let p = levelPaths[lvl] else { continue }
            ctx.setFillColor(trailColors[lvl].cgColor)
            ctx.addPath(p)
            ctx.fillPath()
        }

        // Nucleus cluster: protons only, all in the contrast accent, with a
        // gentle per-cell shimmer so the packed blob feels alive — every
        // cell exactly on the lattice.
        let accentRGB = contrastAccent(forTheme: config.theme)
        for (dx, dy) in protonOrder.prefix(protonCount) {
            let gx = nucX + dx, gy = nucY + dy
            guard gx >= 0, gx < cols, gy >= 0, gy < rows else { continue }
            let f = 0.84 + 0.16 * CGFloat(sin(Float(frameCount) * 0.11 + Float(dx * 3 + dy * 7)))
            let c = NSColor(srgbRed: accentRGB.r * f, green: accentRGB.g * f,
                            blue: accentRGB.b * f, alpha: 1)
            drawCell(ctx,
                     x: originX + CGFloat(gx) * pitch,
                     y: originY + CGFloat(gy) * pitch,
                     color: c, bloom: false)
        }

        // Electron heads (accent, like the reference), lattice-snapped.
        for e in electrons {
            let gx = nucX + Int(e.lastX.rounded())
            let gy = nucY + Int(e.lastY.rounded())
            guard gx >= 0, gx < cols, gy >= 0, gy < rows else { continue }
            drawCell(ctx,
                     x: originX + CGFloat(gx) * pitch,
                     y: originY + CGFloat(gy) * pitch,
                     color: electronColor, bloom: config.bloom)
        }

        // Element info tile (liquid glass) on top of everything.
        drawElementTile(ctx)
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

    /// Pitches in [8, 80] where the grid shows NO partially cut cells on the
    /// main screen. Grid math is untouched (cols = Int(w/p)+2, centered, cell
    /// side 0.7p): the overflow edge cells are FULLY offscreen whenever the
    /// fractional parts of w/p and h/p are <= 0.3.
    private static func pitchDetents() -> [Double] {
        let size = NSScreen.main?.frame.size ?? NSSize(width: 1512, height: 982)
        let w = Double(size.width), h = Double(size.height)
        var runs: [[Double]] = []
        var cur: [Double] = []
        var p = 8.0
        while p <= 80.0 {
            let fw = w / p - (w / p).rounded(.down)
            let fh = h / p - (h / p).rounded(.down)
            if fw <= 0.3 && fh <= 0.3 {
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
        panel.title = "Átomo"
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

        // Detented spacing slider: only positions with no cut cells.
        let detents = Self.pitchDetents()
        pitchDetentValues = detents
        let nearestIdx = detents.enumerated().min {
            abs($0.element - config.pitch) < abs($1.element - config.pitch)
        }!.offset
        _ = label("Espaçamento da grelha:", row: 164)
        let pSlider = slider(Double(nearestIdx), 0, Double(detents.count - 1), row: 164)
        pSlider.numberOfTickMarks = detents.count
        pSlider.allowsTickMarkValuesOnly = true

        _ = label("Velocidade (fps):", row: 126)
        let fSlider = slider(config.fps, 15, 60, row: 126)

        _ = label("Brilho do fundo:", row: 88)
        let flSlider = slider(config.floor, 0.0, 0.30, row: 88)

        let bloom = NSButton(checkboxWithTitle: "Brilho (bloom) nas partículas",
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
        NotificationCenter.default.post(name: .atomConfigChanged, object: nil)
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
