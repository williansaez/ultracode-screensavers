import ScreenSaver
import AppKit
import Metal
import QuartzCore
import simd

private extension Notification.Name {
    static let particleSphereConfigChanged =
        Notification.Name("UltracodeParticleSphereConfigChanged")
}

// MARK: - Ported constants (originkit.dev "particlesphere", preset `base`)
//
// Preset props (merged over component defaults):
//   particlesCount = 10000, particleScale = 8, speed = 20, smoothing = 7,
//   scale = 10, rotationDirection = "clockwise", sphereColor = #FFFFFF
//
// Derived exactly like the reference maps them:
//   speedN  = 20/10 = 2.0  -> rotationSpeed = mapLinear(2.0, 0.1..1.0 -> 0.01..0.05)
//                            = 0.094444...  (the reference does NOT clamp)
//   scaleN  = 10/10 = 1.0  -> scaleMultiplier = mapLinear(1.0, 0..1 -> 0.25..1.25) = 1.25
//   sizeN   = 8/10  = 0.8  -> particleSize = mapLinear(0.8, 0.1..1.0 -> 0.01..0.1) = 0.08
//   smoothingN = 7/10 = 0.7 -> lerpFactor = mapLinear(0.7, 0..1 -> 0.4..0.03) = 0.141
//
// Geometry / camera:
//   Fibonacci (golden-angle) distribution on a sphere of radius 1.0 * 1.25.
//   Each particle is a tiny sphere mesh of radius particleSize * 0.15 = 0.012
//   world units, flat white, additive blending (MeshBasicMaterial).
//   Camera: perspective, base FOV 50 deg vertical, positioned at z = 3.0
//   (max(3.0, sphereRadius + 1.0)). The reference's 2.5x canvas overflow and
//   FOV widening cancel out for the visible crop, leaving an effective 50 deg
//   FOV over the container - which here is the full screen.
//
// Animation (auto-rotation only; drag/cursor replaced per screensaver rules):
//   targetRotation.x += rotationSpeed * 0.1 * deltaFactor  (deltaFactor = dt/16.67ms)
//   rotation.x += (target - rotation) * (1 - pow(1 - 0.141, deltaFactor))
//   group.rotation.y = rotation.x   (three.js Y-axis rotation, clockwise preset)
//
// User configuration (ScreenSaverDefaults, module
// "com.williansaez.ultracode-particlesphere"):
//   theme        popup  - "Base" keeps the flat white particles; the themed
//                         options color each particle by its ROTATED depth
//                         (back of sphere = cold ramp stop, front = hot stop),
//                         giving the sphere painted volumetry. With additive
//                         blending overlapping particles saturate toward hot.
//   speed        slider - 0.25x..3x multiplier on rotationSpeed (default 1x)
//   particles    slider - 2000..20000 (default 10000); the Fibonacci
//                         distribution is regenerated on change
//   particleSize slider - 0.5x..2x multiplier on particle radius (default 1x)

private enum Ref {
    static let particlesCount = 10_000                      // default (user 2000..20000)
    static let rotationSpeed: Float = 0.0944444444          // speed=20 preset
    static let lerpFactor: Float = 0.141                    // smoothing=7
    static let sphereRadius: Float = 1.25                   // scale=10
    static let particleRadius: Float = 0.012                // particleScale=8 (0.08 * 0.15)
    static let cameraZ: Float = 3.0
    static let fovYDegrees: Float = 50.0
    static let targetDeltaMs: Double = 1000.0 / 60.0
}

// MARK: - Shaders

private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4x4 modelView;
    float4x4 projection;
    float    pointScale;   // drawableHeightPx / (2 * tan(fov/2))
    float    radius;       // particle world radius
    float    cameraZ;      // camera distance (recovers rotated model-space z)
    float    sphereRadius; // sphere radius, normalizes the depth ramp
    float    useRamp;      // 0 = flat white (Base), 1 = themed depth ramp
    float    pad0;
    float2   pad1;
    float4   stops[8];     // theme ramp, cold (back) -> hot (front)
};

struct VOut {
    float4 position  [[position]];
    float  pointSize [[point_size]];
    float3 color;
};

vertex VOut psphere_vertex(uint vid [[vertex_id]],
                           const device packed_float3 *positions [[buffer(0)]],
                           constant Uniforms &u [[buffer(1)]]) {
    float3 p = positions[vid];
    float4 viewPos = u.modelView * float4(p, 1.0);
    VOut o;
    o.position = u.projection * viewPos;
    float dist = max(0.0001, -viewPos.z);
    // Projected diameter in pixels of a sphere of radius u.radius at this depth.
    o.pointSize = clamp(2.0 * u.radius * u.pointScale / dist, 0.75, 500.0);
    if (u.useRamp > 0.5) {
        // Rotated depth: viewPos.z + cameraZ is the particle's z after the
        // model rotation, in [-sphereRadius, +sphereRadius]. Back of the
        // sphere maps to the cold end of the ramp, front (facing the camera)
        // to the hot end - painted volumetry. Additive blending then
        // saturates overlaps toward the hot stop.
        float modelZ = viewPos.z + u.cameraZ;
        float t = clamp(modelZ / u.sphereRadius * 0.5 + 0.5, 0.0, 1.0);
        float x = t * 7.0;
        int i = min(int(x), 6);
        o.color = mix(u.stops[i].rgb, u.stops[i + 1].rgb, x - float(i));
    } else {
        o.color = float3(1.0);   // Base: sphereColor #FFFFFF, as shipped
    }
    return o;
}

fragment float4 psphere_fragment(VOut in [[stage_in]],
                                 float2 pc [[point_coord]]) {
    float r = length(pc - float2(0.5)) * 2.0;
    // Round particle with a thin antialiased rim (stands in for the
    // reference's MSAA'd low-poly sphere geometry).
    float alpha = 1.0 - smoothstep(0.8, 1.0, r);
    if (alpha <= 0.0) discard_fragment();
    // Opacity 1, additive blending (premultiplied).
    return float4(in.color * alpha, alpha);
}
"""

// MARK: - Renderer

final class ParticleSphereRenderer {
    struct Uniforms {
        var modelView: simd_float4x4
        var projection: simd_float4x4
        var pointScale: Float
        var radius: Float
        var cameraZ: Float
        var sphereRadius: Float
        var useRamp: Float
        var pad0: Float = 0
        var pad1: SIMD2<Float> = .zero
        var stops: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                    SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
    }

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var positionBuffer: MTLBuffer
    private(set) var particleCount: Int

    // User configuration (pushed by the view from ScreenSaverDefaults).
    var speedMultiplier: Float = 1.0     // 0.25x..3x on rotation speed
    var sizeMultiplier: Float = 1.0      // 0.5x..2x on particle radius
    var rampStops: [SIMD4<Float>]?       // 8 stops cold->hot; nil = Base (white)

    // Rotation state, mirroring the reference exactly.
    private var rotationX: Float = 0        // lerped angle actually applied
    private var targetRotationX: Float = 0  // advanced by the auto-rotation

    init?(device: MTLDevice, particleCount: Int = Ref.particlesCount) {
        self.device = device
        guard let queue = device.makeCommandQueue() else { return nil }
        self.queue = queue

        let n = max(2, particleCount)
        self.particleCount = n
        guard let buf = Self.makeFibonacciBuffer(device: device, count: n) else { return nil }
        self.positionBuffer = buf

        do {
            let lib = try device.makeLibrary(source: shaderSource, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = lib.makeFunction(name: "psphere_vertex")
            desc.fragmentFunction = lib.makeFunction(name: "psphere_fragment")
            let ca = desc.colorAttachments[0]!
            ca.pixelFormat = .bgra8Unorm
            // AdditiveBlending, premultiplied: out = src + dst
            ca.isBlendingEnabled = true
            ca.rgbBlendOperation = .add
            ca.alphaBlendOperation = .add
            ca.sourceRGBBlendFactor = .one
            ca.sourceAlphaBlendFactor = .one
            ca.destinationRGBBlendFactor = .one
            ca.destinationAlphaBlendFactor = .one
            self.pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            NSLog("ParticleSphere: pipeline build failed: \(error)")
            return nil
        }
    }

    /// Fibonacci sphere distribution - identical math to the reference.
    private static func makeFibonacciBuffer(device: MTLDevice, count n: Int) -> MTLBuffer? {
        let goldenAngle = Float.pi * (3.0 - sqrtf(5.0))
        var verts = [Float](repeating: 0, count: n * 3)
        for i in 0..<n {
            let y = 1.0 - (Float(i) / Float(n - 1)) * 2.0   // 1 -> -1
            let ringRadius = sqrtf(max(0, 1.0 - y * y))
            let theta = goldenAngle * Float(i)
            verts[i * 3 + 0] = cosf(theta) * ringRadius * Ref.sphereRadius
            verts[i * 3 + 1] = y * Ref.sphereRadius
            verts[i * 3 + 2] = sinf(theta) * ringRadius * Ref.sphereRadius
        }
        return device.makeBuffer(bytes: verts,
                                 length: verts.count * MemoryLayout<Float>.size,
                                 options: .storageModeShared)
    }

    /// Regenerate the Fibonacci distribution when the particle count changes.
    func setParticleCount(_ n: Int) {
        let clamped = max(2, n)
        guard clamped != particleCount,
              let buf = Self.makeFibonacciBuffer(device: device, count: clamped) else { return }
        positionBuffer = buf
        particleCount = clamped
    }

    /// Advance the simulation by `dt` seconds (reference's delta-time model).
    func advance(deltaSeconds dt: Double) {
        let deltaFactor = Float((dt * 1000.0) / Ref.targetDeltaMs)
        // Auto-rotation: targetRotation.x += rotationSpeed * 0.1 * deltaFactor
        targetRotationX += Ref.rotationSpeed * speedMultiplier * 0.1 * deltaFactor
        // Lerp toward target: 1 - pow(1 - lerpFactor, deltaFactor)
        let t = 1.0 - powf(1.0 - Ref.lerpFactor, deltaFactor)
        rotationX += (targetRotationX - rotationX) * t
    }

    /// Encode a full frame into `texture` (clears to black first).
    func render(to texture: MTLTexture, commandBuffer: MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(positionBuffer, offset: 0, index: 0)

        var u = makeUniforms(widthPx: Float(texture.width), heightPx: Float(texture.height))
        enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: particleCount)
        enc.endEncoding()
    }

    func renderFrame(to texture: MTLTexture) {
        guard let cb = queue.makeCommandBuffer() else { return }
        render(to: texture, commandBuffer: cb)
        cb.commit()
        cb.waitUntilCompleted()
    }

    func renderAndPresent(drawable: CAMetalDrawable) {
        guard let cb = queue.makeCommandBuffer() else { return }
        render(to: drawable.texture, commandBuffer: cb)
        cb.present(drawable)
        cb.commit()
    }

    private func makeUniforms(widthPx: Float, heightPx: Float) -> Uniforms {
        // Model: three.js group.rotation.y = rotation.x
        // RotY(a): x' = cos*x + sin*z ; z' = -sin*x + cos*z
        let a = rotationX
        let c = cosf(a), s = sinf(a)
        let model = simd_float4x4(columns: (
            SIMD4<Float>( c, 0, -s, 0),
            SIMD4<Float>( 0, 1,  0, 0),
            SIMD4<Float>( s, 0,  c, 0),
            SIMD4<Float>( 0, 0,  0, 1)
        ))
        // View: camera at (0, 0, cameraZ) looking down -Z.
        var view = matrix_identity_float4x4
        view.columns.3 = SIMD4<Float>(0, 0, -Ref.cameraZ, 1)
        let modelView = view * model

        // Perspective projection, vertical FOV 50 deg, near 0.1, far 1000.
        let fov = Ref.fovYDegrees * .pi / 180
        let aspect = widthPx / heightPx
        let yScale = 1.0 / tanf(fov / 2)
        let xScale = yScale / aspect
        let zn: Float = 0.1, zf: Float = 1000
        let zRange = zf / (zn - zf)
        let projection = simd_float4x4(columns: (
            SIMD4<Float>(xScale, 0, 0, 0),
            SIMD4<Float>(0, yScale, 0, 0),
            SIMD4<Float>(0, 0, zRange, -1),
            SIMD4<Float>(0, 0, zn * zRange, 0)
        ))

        let pointScale = heightPx / (2.0 * tanf(fov / 2))

        let white = SIMD4<Float>(repeating: 1)
        var st = [SIMD4<Float>](repeating: white, count: 8)
        if let ramp = rampStops, ramp.count == 8 { st = ramp }

        return Uniforms(modelView: modelView,
                        projection: projection,
                        pointScale: pointScale,
                        radius: Ref.particleRadius * sizeMultiplier,
                        cameraZ: Ref.cameraZ,
                        sphereRadius: Ref.sphereRadius,
                        useRamp: rampStops == nil ? 0 : 1,
                        stops: (st[0], st[1], st[2], st[3],
                                st[4], st[5], st[6], st[7]))
    }
}

// MARK: - Screen saver view

@objc(UltracodeParticleSphereView)
public final class UltracodeParticleSphereView: ScreenSaverView {
    // Internal (not private) so the offscreen test harness, compiled into the
    // same module, can render frames without a window.
    var renderer: ParticleSphereRenderer?
    private var metalLayer: CAMetalLayer?
    private var lastFrameTime: CFTimeInterval = 0

    // MARK: - Themes

    private struct Theme {
        let name: String
        let stops: [UInt32]?   // 8 stops cold -> hot; nil = flat white (Base)
    }

    /// "Base" keeps today's flat white particles. The themed ramps share
    /// their stops with the other Ultracode savers (UltracodeLifeView).
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

    private static func rampVectors(_ stops: [UInt32]) -> [SIMD4<Float>] {
        stops.map { hex in
            SIMD4<Float>(Float((hex >> 16) & 0xFF) / 255,
                         Float((hex >> 8) & 0xFF) / 255,
                         Float(hex & 0xFF) / 255,
                         1)
        }
    }

    // MARK: - User configuration

    private struct Config {
        var theme = 0
        var speed: Double = 1.0              // 0.25x .. 3x rotation speed
        var particles = Ref.particlesCount   // 2000 .. 20000
        var size: Double = 1.0               // 0.5x .. 2x particle size
    }

    private static let moduleName = "com.williansaez.ultracode-particlesphere"

    private static func makeDefaults() -> ScreenSaverDefaults? {
        let d = ScreenSaverDefaults(forModuleWithName: moduleName)
        d?.register(defaults: [
            "theme": 0,
            "speed": 1.0,
            "particles": Ref.particlesCount,
            "particleSize": 1.0,
        ])
        return d
    }

    private var config = Config()

    private func loadConfig() {
        guard let d = Self.makeDefaults() else { return }
        config.theme = min(max(d.integer(forKey: "theme"), 0), Self.themes.count - 1)
        config.speed = min(max(d.double(forKey: "speed"), 0.25), 3.0)
        config.particles = min(max(d.integer(forKey: "particles"), 2000), 20_000)
        config.size = min(max(d.double(forKey: "particleSize"), 0.5), 2.0)
        applyConfig()
    }

    private func applyConfig() {
        guard let renderer else { return }
        renderer.speedMultiplier = Float(config.speed)
        renderer.sizeMultiplier = Float(config.size)
        renderer.rampStops = Self.themes[config.theme].stops.map(Self.rampVectors)
        renderer.setParticleCount(config.particles)   // regenerates Fibonacci
    }

    // MARK: - Lifecycle

    public override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func commonInit() {
        animationTimeInterval = 1.0 / 60.0
        wantsLayer = true
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = ParticleSphereRenderer(device: device) else {
            NSLog("ParticleSphere: Metal unavailable")
            return
        }
        self.renderer = renderer

        let ml = CAMetalLayer()
        ml.device = device
        ml.pixelFormat = .bgra8Unorm
        ml.framebufferOnly = true
        ml.isOpaque = true
        ml.backgroundColor = NSColor.black.cgColor
        self.metalLayer = ml

        NotificationCenter.default.addObserver(
            self, selector: #selector(configChanged(_:)),
            name: .particleSphereConfigChanged, object: nil)
    }

    @objc private func configChanged(_ note: Notification) {
        loadConfig()
    }

    public override func startAnimation() {
        super.startAnimation()
        loadConfig()
        lastFrameTime = 0
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachLayerIfNeeded()
    }

    public override func layout() {
        super.layout()
        updateLayerGeometry()
    }

    private func attachLayerIfNeeded() {
        guard let ml = metalLayer, ml.superlayer == nil, let host = layer else { return }
        host.backgroundColor = NSColor.black.cgColor
        host.addSublayer(ml)
        updateLayerGeometry()
    }

    private func updateLayerGeometry() {
        guard let ml = metalLayer else { return }
        let scale = window?.backingScaleFactor ?? 2.0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ml.frame = bounds
        ml.contentsScale = scale
        let w = max(1, bounds.width * scale)
        let h = max(1, bounds.height * scale)
        ml.drawableSize = CGSize(width: w, height: h)
        CATransaction.commit()
    }

    public override func animateOneFrame() {
        guard let renderer = renderer, let ml = metalLayer else { return }
        attachLayerIfNeeded()

        let now = CACurrentMediaTime()
        let dt: Double
        if lastFrameTime == 0 {
            dt = animationTimeInterval
        } else {
            dt = min(now - lastFrameTime, 0.1)   // clamp huge stalls
        }
        lastFrameTime = now

        renderer.advance(deltaSeconds: dt)
        guard let drawable = ml.nextDrawable() else { return }
        renderer.renderAndPresent(drawable: drawable)
    }

    public override func draw(_ rect: NSRect) {
        // Black fill behind the Metal layer (and fallback if Metal is absent).
        NSColor.black.setFill()
        rect.fill()
    }

    // MARK: - Configure sheet

    private var sheet: NSPanel?
    private var themePopup: NSPopUpButton?
    private var speedSlider: NSSlider?
    private var particlesSlider: NSSlider?
    private var sizeSlider: NSSlider?

    public override var hasConfigureSheet: Bool { true }

    public override var configureSheet: NSWindow? {
        if let sheet { return sheet }
        loadConfig()

        // Fixed frames, no autolayout: the sheet is measured and presented
        // remotely (legacyScreenSaver -> System Settings) before any layout
        // pass runs; autolayout-sized panels collapse there.
        let W: CGFloat = 440, H: CGFloat = 216
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                            styleMask: [.titled],
                            backing: .buffered, defer: false)
        panel.title = "Esfera de Partículas"
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

        _ = label("Tema:", row: 168)
        let popup = NSPopUpButton(frame: NSRect(x: 178, y: 162, width: 244, height: 26),
                                  pullsDown: false)
        popup.addItems(withTitles: Self.themes.map(\.name))
        popup.selectItem(at: config.theme)
        content.addSubview(popup)

        _ = label("Velocidade de rotação:", row: 130)
        let sSlider = slider(config.speed, 0.25, 3.0, row: 130)

        _ = label("Nº de partículas:", row: 96)
        let pSlider = slider(Double(config.particles), 2000, 20_000, row: 96)

        _ = label("Tamanho das partículas:", row: 62)
        let szSlider = slider(config.size, 0.5, 2.0, row: 62)

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
        particlesSlider = pSlider
        sizeSlider = szSlider
        return panel
    }

    @objc private func sheetOK(_ sender: Any?) {
        if let d = Self.makeDefaults() {
            d.set(themePopup?.indexOfSelectedItem ?? 0, forKey: "theme")
            d.set(speedSlider?.doubleValue ?? 1.0, forKey: "speed")
            let count = Int((particlesSlider?.doubleValue ?? Double(Ref.particlesCount)).rounded())
            d.set(count, forKey: "particles")
            d.set(sizeSlider?.doubleValue ?? 1.0, forKey: "particleSize")
            d.synchronize()
        }
        NotificationCenter.default.post(name: .particleSphereConfigChanged, object: nil)
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
