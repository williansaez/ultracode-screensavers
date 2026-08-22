import ScreenSaver
import AppKit
import Metal
import QuartzCore
import simd

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

private enum Ref {
    static let particlesCount = 10_000
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
    float2   pad;
};

struct VOut {
    float4 position  [[position]];
    float  pointSize [[point_size]];
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
    return o;
}

fragment float4 psphere_fragment(VOut in [[stage_in]],
                                 float2 pc [[point_coord]]) {
    float r = length(pc - float2(0.5)) * 2.0;
    // Round particle with a thin antialiased rim (stands in for the
    // reference's MSAA'd low-poly sphere geometry).
    float alpha = 1.0 - smoothstep(0.8, 1.0, r);
    if (alpha <= 0.0) discard_fragment();
    // sphereColor #FFFFFF, opacity 1, additive blending (premultiplied).
    return float4(alpha, alpha, alpha, alpha);
}
"""

// MARK: - Renderer

final class ParticleSphereRenderer {
    struct Uniforms {
        var modelView: simd_float4x4
        var projection: simd_float4x4
        var pointScale: Float
        var radius: Float
        var pad: SIMD2<Float> = .zero
    }

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let positionBuffer: MTLBuffer

    // Rotation state, mirroring the reference exactly.
    private var rotationX: Float = 0        // lerped angle actually applied
    private var targetRotationX: Float = 0  // advanced by the auto-rotation

    init?(device: MTLDevice) {
        self.device = device
        guard let queue = device.makeCommandQueue() else { return nil }
        self.queue = queue

        // Fibonacci sphere distribution - identical math to the reference.
        let n = Ref.particlesCount
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
        guard let buf = device.makeBuffer(bytes: verts,
                                          length: verts.count * MemoryLayout<Float>.size,
                                          options: .storageModeShared) else { return nil }
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

    /// Advance the simulation by `dt` seconds (reference's delta-time model).
    func advance(deltaSeconds dt: Double) {
        let deltaFactor = Float((dt * 1000.0) / Ref.targetDeltaMs)
        // Auto-rotation: targetRotation.x += rotationSpeed * 0.1 * deltaFactor
        targetRotationX += Ref.rotationSpeed * 0.1 * deltaFactor
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
        enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: Ref.particlesCount)
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
        return Uniforms(modelView: modelView,
                        projection: projection,
                        pointScale: pointScale,
                        radius: Ref.particleRadius)
    }
}

// MARK: - Screen saver view

@objc(UltracodeParticleSphereView)
public final class UltracodeParticleSphereView: ScreenSaverView {
    private var renderer: ParticleSphereRenderer?
    private var metalLayer: CAMetalLayer?
    private var lastFrameTime: CFTimeInterval = 0

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
    }

    public override var hasConfigureSheet: Bool { false }

    public override func startAnimation() {
        super.startAnimation()
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
}
