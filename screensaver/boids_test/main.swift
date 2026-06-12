import AppKit
import ScreenSaver

// Offline harness: render the boids saver at several simulation stages.

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

guard let view = UltracodeBoidsView(frame: NSRect(origin: .zero, size: size),
                                    isPreview: false) else {
    fatalError("failed to create view")
}

// Perf harness (env-gated, BOIDS_PERF=1): pitch comes from the saver's
// prefs (write it via `defaults -currentHost write` before running).
// Pumps animateOneFrame + offscreen draw(bounds) 60x, prints avg ms/frame.
if ProcessInfo.processInfo.environment["BOIDS_PERF"] == "1" {
    let b = view.bounds
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(b.width), pixelsHigh: Int(b.height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let gctx = NSGraphicsContext(bitmapImageRep: rep) else {
        fatalError("failed to create perf bitmap context")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gctx
    for _ in 0..<10 {            // warm-up: grid + floor image build
        view.animateOneFrame()
        view.draw(b)
    }
    let t0 = CFAbsoluteTimeGetCurrent()
    let frames = 60
    for _ in 0..<frames {
        view.animateOneFrame()
        view.draw(b)
    }
    let elapsed = CFAbsoluteTimeGetCurrent() - t0
    NSGraphicsContext.restoreGraphicsState()
    print(String(format: "perf: %.2f ms/frame (sim+draw, %d frames)",
                 elapsed / Double(frames) * 1000, frames))
    exit(0)
}

// Early: flock leaving the seed clusters.
for _ in 0..<5 { view.animateOneFrame() }
snapshot(view, to: "\(outDir)/boids_t5.png")

// Settled flock with comet trails.
for _ in 0..<55 { view.animateOneFrame() }
snapshot(view, to: "\(outDir)/boids_t60.png")

// 60 frames later: MUST clearly differ from t60 (moving flock).
for _ in 0..<60 { view.animateOneFrame() }
snapshot(view, to: "\(outDir)/boids_t120.png")

// Predator scatter: trigger and watch the flock flee.
view.debugTriggerPredator()
for _ in 0..<25 { view.animateOneFrame() }
snapshot(view, to: "\(outDir)/boids_flee.png")

// Regrouped after the predator expires.
for _ in 0..<180 { view.animateOneFrame() }
snapshot(view, to: "\(outDir)/boids_regroup.png")
