// UltracodeChromaticWaves — réplica fiel do componente "chromatic-waves" (originkit.dev, preset `base`).
//
// A referência (React + ogl/WebGL2) faz dois passes:
//   1. Perlin pass: simplex noise 3D → hue → hsv2rgb (campo arco-íris) num render target.
//   2. Dot pass: por célula de `uCellSize` px, amostra o campo no CENTRO da célula,
//      converte para luminância, aplica gama + bias, e desenha um disco cujo raio
//      é proporcional a esse valor, colorido pela paleta, composto sobre bgColor.
//
// Como o dot pass só lê o campo Perlin no centro de cada célula, os dois passes
// fundem-se num único fragment shader Metal sem perda de fidelidade (avaliação
// analítica do noise no centro da célula ≡ amostra da textura full-res nesse ponto).
//
// Parâmetros do preset `base`, já mapeados UI→shader como no código de origem:
//   frequency  = 1   → uFrequency   = 0.3        (mapLinear 1..10 → 0.3..6)
//   speed      = 4   → uSpeed       = 0.2        (ui * 0.05)
//   cellSize   = 34  → uCellSize    = 24 px      (mapLinear 1..100 → 6..60)
//   gamma      = 6   → uGamma       = 2.4736842  (mapLinear 1..20 → 0.5..8)
//   paletteBias= -3  → uPaletteBias = -0.15      (ui * 0.05)
//   colors     = ["#FFFFFF"] (1 cor, alpha 1)  bgColor = #000000  uValue = 1
//   frame cap  = 30 fps (frameInterval = 1000/30 no original)
//
// configureSheet (frames fixos, sem Auto Layout): tema (Base/Ultracode/Doom/Matrix),
// velocidade (0.25x–3x sobre uSpeed), tamanho de célula (12–48 px) e frequência (0.1–1.0).
// Defaults em ScreenSaverDefaults "com.williansaez.ultracode-chromatic-waves".
// Sem dependências externas: ScreenSaver, AppKit, Metal, QuartzCore, simd.

import ScreenSaver
import AppKit
import Metal
import QuartzCore
import simd

private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float2 resolution;   // pixels do drawable
    float  time;         // segundos
    float  frequency;    // 0.3
    float  speed;        // 0.2
    float  cellSize;     // 24 (pixels de dispositivo, como no WebGL com dpr)
    float  gamma;        // 2.4736842
    float  paletteBias;  // -0.15
    int    themeMode;    // 0 = Base (branco), >0 = ramp de 8 stops
    float  pad0;
    float  pad1;
    float  pad2;
    float4 stops[8];     // ramp cold -> hot (rgb em .xyz)
};

struct VOut { float4 pos [[position]]; };

vertex VOut cw_vertex(uint vid [[vertex_id]]) {
    // triângulo fullscreen
    float2 p[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    VOut o;
    o.pos = float4(p[vid], 0.0, 1.0);
    return o;
}

// --- simplex noise 3D (Ashima / webgl-noise), porte 1:1 do GLSL da referência ---
static float3 mod289(float3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
static float4 mod289(float4 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
static float4 permute(float4 x) { return mod289(((x * 34.0) + 1.0) * x); }
static float4 taylorInvSqrt(float4 r) { return 1.79284291400159 - 0.85373472095314 * r; }

static float snoise(float3 v) {
    const float2 C = float2(1.0/6.0, 1.0/3.0);
    const float4 D = float4(0.0, 0.5, 1.0, 2.0);
    float3 i  = floor(v + dot(v, C.yyy));
    float3 x0 = v - i + dot(i, C.xxx);
    float3 g = step(x0.yzx, x0.xyz);
    float3 l = 1.0 - g;
    float3 i1 = min(g.xyz, l.zxy);
    float3 i2 = max(g.xyz, l.zxy);
    float3 x1 = x0 - i1 + C.xxx;
    float3 x2 = x0 - i2 + C.yyy;
    float3 x3 = x0 - D.yyy;
    i = mod289(i);
    float4 p = permute(permute(permute(
               i.z + float4(0.0, i1.z, i2.z, 1.0))
             + i.y + float4(0.0, i1.y, i2.y, 1.0))
             + i.x + float4(0.0, i1.x, i2.x, 1.0));
    float n_ = 0.142857142857;
    float3 ns = n_ * D.wyz - D.xzx;
    float4 j = p - 49.0 * floor(p * ns.z * ns.z);
    float4 x_ = floor(j * ns.z);
    float4 y_ = floor(j - 7.0 * x_);
    float4 x = x_ * ns.x + ns.yyyy;
    float4 y = y_ * ns.x + ns.yyyy;
    float4 h = 1.0 - abs(x) - abs(y);
    float4 b0 = float4(x.xy, y.xy);
    float4 b1 = float4(x.zw, y.zw);
    float4 s0 = floor(b0) * 2.0 + 1.0;
    float4 s1 = floor(b1) * 2.0 + 1.0;
    float4 sh = -step(h, float4(0.0));
    float4 a0 = b0.xzyw + s0.xzyw * sh.xxyy;
    float4 a1 = b1.xzyw + s1.xzyw * sh.zzww;
    float3 p0 = float3(a0.xy, h.x);
    float3 p1 = float3(a0.zw, h.y);
    float3 p2 = float3(a1.xy, h.z);
    float3 p3 = float3(a1.zw, h.w);
    float4 norm = taylorInvSqrt(float4(dot(p0,p0), dot(p1,p1), dot(p2,p2), dot(p3,p3)));
    p0 *= norm.x;
    p1 *= norm.y;
    p2 *= norm.z;
    p3 *= norm.w;
    float4 m = max(0.6 - float4(dot(x0,x0), dot(x1,x1), dot(x2,x2), dot(x3,x3)), 0.0);
    m = m * m;
    return 42.0 * dot(m * m, float4(dot(p0,x0), dot(p1,x1), dot(p2,x2), dot(p3,x3)));
}

static float3 hsv2rgb(float3 c) {
    float4 K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
    float3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

fragment float4 cw_fragment(VOut in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
    // gl_FragCoord tem origem em baixo-esquerda no GL; Metal em cima-esquerda.
    float2 pix = float2(in.pos.x, u.resolution.y - in.pos.y);
    float cell = max(u.cellSize, 1.0);

    // dot pass: amostra do campo no centro da célula
    float2 cellIdx = floor(pix / cell);
    float2 cellCenter = (cellIdx + 0.5) * cell;

    // perlin pass avaliado nesse ponto (uv em [0,1], correção de aspecto como na referência)
    float2 uv = cellCenter / u.resolution;
    float aspect = u.resolution.x / max(u.resolution.y, 1.0);
    uv = (uv - 0.5) * float2(aspect, 1.0) + 0.5;
    float hue = abs(snoise(float3(uv * u.frequency, u.time * u.speed)));
    float3 rainbow = hsv2rgb(float3(hue, 1.0, 1.0));   // uValue = 1

    float gray = 0.3 * rainbow.r + 0.59 * rainbow.g + 0.11 * rainbow.b;
    gray = pow(clamp(gray, 0.0001, 1.0), u.gamma);

    float2 cellUV = fract(pix / cell) - 0.5;
    float dist = length(cellUV);
    float radius = clamp(gray + u.paletteBias, 0.0, 1.0) * 0.5;
    float aa = fwidth(dist) + 1e-4;
    float mark = 1.0 - smoothstep(radius - aa, radius + aa, dist);

    // Paleta: tema 0 (Base) = branco fixo, como o preset original.
    // Temas >0: a luminância pós-gama (com bias) indexa a ramp de 8 stops cold->hot.
    float a = mark;                    // mark * dotOpacity
    float3 dotCol;
    if (u.themeMode == 0) {
        dotCol = float3(1.0);
    } else {
        float t = clamp(gray + u.paletteBias, 0.0, 1.0);
        float x = t * 7.0;
        int i = clamp(int(x), 0, 6);
        dotCol = mix(u.stops[i].rgb, u.stops[i + 1].rgb, x - float(i));
    }
    float3 bg = float3(0.0);
    float3 outColor = dotCol * a + bg * (1.0 - a);
    return float4(outColor, 1.0);
}
"""

private struct Uniforms {
    var resolution: SIMD2<Float>
    var time: Float
    var frequency: Float
    var speed: Float
    var cellSize: Float
    var gamma: Float
    var paletteBias: Float
    var themeMode: Int32
    var pad0: Float = 0
    var pad1: Float = 0
    var pad2: Float = 0
    var stops: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
}

@objc(UltracodeChromaticWavesView)
public final class UltracodeChromaticWavesView: ScreenSaverView {

    // Parâmetros portados do preset `base` (já mapeados UI → shader)
    private let uSpeed: Float = 0.2
    private let uGamma: Float = 0.5 + ((6.0 - 1.0) / (20.0 - 1.0)) * (8.0 - 0.5)  // 2.4736842
    private let uPaletteBias: Float = -0.15

    // MARK: - Temas

    private struct Theme {
        let name: String
        let stops: [UInt32]   // cold -> hot (8 stops); vazio = branco fixo (Base)
    }

    private static let themes: [Theme] = [
        Theme(name: "Base", stops: []),
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

    private static func stopVec(_ hex: UInt32) -> SIMD4<Float> {
        SIMD4<Float>(Float((hex >> 16) & 0xFF) / 255,
                     Float((hex >> 8) & 0xFF) / 255,
                     Float(hex & 0xFF) / 255, 1)
    }

    // MARK: - Configuração do utilizador

    private struct Config {
        var theme = 0
        var speedMult: Double = 1.0     // 0.25x .. 3x
        var cellSize: Double = 24.0     // 12 .. 48 px
        var frequency: Double = 0.3     // 0.1 .. 1.0
    }

    private static let moduleName = "com.williansaez.ultracode-chromatic-waves"

    private static func makeDefaults() -> ScreenSaverDefaults? {
        let d = ScreenSaverDefaults(forModuleWithName: moduleName)
        d?.register(defaults: [
            "theme": 0,
            "speedMult": 1.0,
            "cellSize": 24.0,
            "frequency": 0.3,
        ])
        return d
    }

    private var config = Config()

    private func loadConfig() {
        guard let d = Self.makeDefaults() else { return }
        config.theme = min(max(d.integer(forKey: "theme"), 0), Self.themes.count - 1)
        config.speedMult = min(max(d.double(forKey: "speedMult"), 0.25), 3.0)
        config.cellSize = min(max(d.double(forKey: "cellSize"), 12.0), 48.0)
        config.frequency = min(max(d.double(forKey: "frequency"), 0.1), 1.0)
    }

    // Sheet de configuração
    private var sheet: NSPanel?
    private var themePopup: NSPopUpButton?
    private var speedSlider: NSSlider?
    private var cellSlider: NSSlider?
    private var freqSlider: NSSlider?

    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var metalLayer: CAMetalLayer?

    /// Tempo de simulação em segundos. Avança em passos fixos de 1/30 s por frame,
    /// espelhando o cap de 30 fps do original (frameInterval = 1000/30).
    private var simTime: Float = 0

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
        animationTimeInterval = 1.0 / 30.0
        wantsLayer = true
        loadConfig()
        setupMetal()
    }

    // MARK: - Metal setup

    private func setupMetal() {
        guard let dev = MTLCreateSystemDefaultDevice() else { return }
        device = dev
        commandQueue = dev.makeCommandQueue()
        do {
            let library = try dev.makeLibrary(source: shaderSource, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "cw_vertex")
            desc.fragmentFunction = library.makeFunction(name: "cw_fragment")
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try dev.makeRenderPipelineState(descriptor: desc)
        } catch {
            NSLog("UltracodeChromaticWaves: falha ao compilar shaders Metal: \\(error)")
        }

        let layer = CAMetalLayer()
        layer.device = dev
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.backgroundColor = NSColor.black.cgColor
        metalLayer = layer
    }

    private func attachLayerIfNeeded() {
        guard let metalLayer = metalLayer, let hostLayer = self.layer else { return }
        if metalLayer.superlayer !== hostLayer {
            hostLayer.backgroundColor = NSColor.black.cgColor
            hostLayer.addSublayer(metalLayer)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = bounds
        let scale = window?.backingScaleFactor ?? 1.0
        metalLayer.contentsScale = scale
        let w = max(1.0, bounds.width * scale)
        let h = max(1.0, bounds.height * scale)
        let newSize = CGSize(width: w, height: h)
        if metalLayer.drawableSize != newSize {
            metalLayer.drawableSize = newSize
        }
        CATransaction.commit()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        attachLayerIfNeeded()
    }

    public override func layout() {
        super.layout()
        attachLayerIfNeeded()
    }

    // MARK: - Animação

    public override func startAnimation() {
        super.startAnimation()
        loadConfig()
        attachLayerIfNeeded()
    }

    public override func animateOneFrame() {
        simTime += Float(1.0 / 30.0)
        renderOnscreen()
    }

    public override func draw(_ rect: NSRect) {
        // fallback: fundo preto (bgColor do preset) enquanto a camada Metal não cobre
        NSColor.black.setFill()
        rect.fill()
    }

    private func renderOnscreen() {
        guard window != nil,
              let metalLayer = metalLayer,
              pipeline != nil,
              let queue = commandQueue else { return }
        attachLayerIfNeeded()
        guard let drawable = metalLayer.nextDrawable() else { return }
        guard let cmd = queue.makeCommandBuffer() else { return }
        encode(to: drawable.texture, commandBuffer: cmd)
        cmd.present(drawable)
        cmd.commit()
    }

    private func encode(to texture: MTLTexture, commandBuffer: MTLCommandBuffer) {
        guard let pipeline = pipeline else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        let theme = Self.themes[min(max(config.theme, 0), Self.themes.count - 1)]
        let s: [SIMD4<Float>] = theme.stops.isEmpty
            ? Array(repeating: SIMD4<Float>(1, 1, 1, 1), count: 8)
            : theme.stops.map(Self.stopVec)
        var uniforms = Uniforms(
            resolution: SIMD2<Float>(Float(texture.width), Float(texture.height)),
            time: simTime,
            frequency: Float(config.frequency),
            speed: uSpeed * Float(config.speedMult),
            cellSize: Float(config.cellSize),
            gamma: uGamma,
            paletteBias: uPaletteBias,
            themeMode: theme.stops.isEmpty ? 0 : 1,
            stops: (s[0], s[1], s[2], s[3], s[4], s[5], s[6], s[7])
        )
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    // MARK: - Configure sheet
    //
    // REGRA do projeto: frames fixos, zero Auto Layout — o sheet é medido e
    // apresentado remotamente (legacyScreenSaver -> Definições de Sistema)
    // antes de qualquer passe de layout; painéis com autolayout colapsam lá.

    public override var hasConfigureSheet: Bool { true }

    public override var configureSheet: NSWindow? {
        if let sheet { return sheet }
        loadConfig()

        let W: CGFloat = 440, H: CGFloat = 212
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                            styleMask: [.titled],
                            backing: .buffered, defer: false)
        panel.title = "Ondas Cromáticas"
        panel.isReleasedWhenClosed = false

        let content = panel.contentView!

        func label(_ text: String, row y: CGFloat) {
            let l = NSTextField(labelWithString: text)
            l.alignment = .right
            l.frame = NSRect(x: 20, y: y, width: 150, height: 20)
            content.addSubview(l)
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

        label("Tema:", row: 164)
        let popup = NSPopUpButton(frame: NSRect(x: 178, y: 158, width: 244, height: 26),
                                  pullsDown: false)
        popup.addItems(withTitles: Self.themes.map(\.name))
        popup.selectItem(at: config.theme)
        content.addSubview(popup)

        label("Velocidade:", row: 126)
        let sSlider = slider(config.speedMult, 0.25, 3.0, row: 126)

        label("Tamanho da célula (px):", row: 88)
        let cSlider = slider(config.cellSize, 12.0, 48.0, row: 88)

        label("Frequência:", row: 50)
        let fSlider = slider(config.frequency, 0.1, 1.0, row: 50)

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
        freqSlider = fSlider
        return panel
    }

    @objc private func sheetOK(_ sender: Any?) {
        if let d = Self.makeDefaults() {
            d.set(themePopup?.indexOfSelectedItem ?? 0, forKey: "theme")
            d.set(speedSlider?.doubleValue ?? 1.0, forKey: "speedMult")
            d.set(cellSlider?.doubleValue ?? 24.0, forKey: "cellSize")
            d.set(freqSlider?.doubleValue ?? 0.3, forKey: "frequency")
            d.synchronize()
        }
        loadConfig()
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

    // MARK: - Captura offscreen (verificação / harness)

    /// Renderiza o estado atual para uma textura offscreen e grava PNG. Devolve true em sucesso.
    @discardableResult
    public func debugWritePNG(to path: String, width: Int? = nil, height: Int? = nil) -> Bool {
        guard let dev = device, let queue = commandQueue, pipeline != nil else { return false }
        let w = width ?? max(1, Int(bounds.width))
        let h = height ?? max(1, Int(bounds.height))
        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        texDesc.usage = [.renderTarget]
        texDesc.storageMode = .shared
        guard let texture = dev.makeTexture(descriptor: texDesc),
              let cmd = queue.makeCommandBuffer() else { return false }
        encode(to: texture, commandBuffer: cmd)
        cmd.commit()
        cmd.waitUntilCompleted()

        let bytesPerRow = w * 4
        var data = [UInt8](repeating: 0, count: bytesPerRow * h)
        texture.getBytes(&data, bytesPerRow: bytesPerRow,
                         from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)

        guard let provider = CGDataProvider(data: Data(data) as CFData),
              let cgImage = CGImage(
                width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                                         | CGImageAlphaInfo.noneSkipFirst.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent) else { return false }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            return true
        } catch {
            return false
        }
    }
}
