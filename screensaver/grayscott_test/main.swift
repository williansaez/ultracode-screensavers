import AppKit
import ScreenSaver

// Offline harness: render the Gray-Scott reaction-diffusion saver at
// several growth stages and dump field statistics.

_ = NSApplication.shared

let size = NSSize(width: 1512, height: 982)
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func snapshot(_ view: NSView, to path: String) {
    let b = view.bounds
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(b.width), pixelsHigh: Int(b.height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let gctx = NSGraphicsContext(bitmapImageRep: rep) else {
        fatalError("failed to create bitmap context")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gctx
    view.draw(b)
    gctx.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("png encode failed")
    }
    try! png.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

// Perf mode (GS_PERF=1): time sim+draw per frame. Set the pitch pref first
// (defaults -currentHost write com.williansaez.ultracode-grayscott pitch ...).
if ProcessInfo.processInfo.environment["GS_PERF"] != nil {
    guard let pv = UltracodeGrayScottView(frame: NSRect(origin: .zero, size: size),
                                          isPreview: false) else {
        fatalError("failed to create view")
    }
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let gctx = NSGraphicsContext(bitmapImageRep: rep) else {
        fatalError("failed to create bitmap context")
    }
    // Warm-up: let the pattern grow so the draw load is representative.
    for _ in 0..<120 { pv.animateOneFrame() }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gctx
    pv.draw(pv.bounds)   // warm caches / floor image
    let frames = 60
    var simNs: UInt64 = 0
    var drawNs: UInt64 = 0
    let t0 = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<frames {
        let a = DispatchTime.now().uptimeNanoseconds
        pv.animateOneFrame()
        let b = DispatchTime.now().uptimeNanoseconds
        pv.draw(pv.bounds)
        let c = DispatchTime.now().uptimeNanoseconds
        simNs += b - a
        drawNs += c - b
    }
    let t1 = DispatchTime.now().uptimeNanoseconds
    NSGraphicsContext.restoreGraphicsState()
    let ms = Double(t1 - t0) / 1_000_000.0 / Double(frames)
    pv.debugDump()
    print(String(format: "perf: %d frames, avg sim+draw = %.2f ms/frame (sim %.2f, draw %.2f)",
                 frames, ms,
                 Double(simNs) / 1_000_000.0 / Double(frames),
                 Double(drawNs) / 1_000_000.0 / Double(frames)))
    exit(0)
}

guard let view = UltracodeGrayScottView(frame: NSRect(origin: .zero, size: size),
                                        isPreview: false) else {
    fatalError("failed to create view")
}

// Snapshot at meaningful growth stages: early spots, expansion, labyrinth,
// and past the first quiet-area reseed (~frame 600 at 30 fps).
let stages = [60, 200, 400, 650]
var frame = 0
for stage in stages {
    while frame < stage {
        view.animateOneFrame()
        frame += 1
    }
    view.debugDump()
    snapshot(view, to: "\(outDir)/gs_f\(stage).png")
}
