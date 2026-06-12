import AppKit
import ScreenSaver

_ = NSApplication.shared
let size = NSSize(width: 1512, height: 982)
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func snapshot(_ view: NSView, to path: String) {
    let b = view.bounds
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(b.width), pixelsHigh: Int(b.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let gctx = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("ctx") }
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = gctx
    view.draw(b); gctx.flushGraphics(); NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path)); print("wrote \(path)")
}

// Timing mode (CPU_TIMING=1): pump animateOneFrame + an offscreen draw into a
// bitmap context 60 times and print the average ms/frame. Pitch comes from
// the saved prefs — write `pitch` via `defaults -currentHost` before running.
if ProcessInfo.processInfo.environment["CPU_TIMING"] != nil {
    guard let view = UltracodeCPUView(frame: NSRect(origin: .zero, size: size), isPreview: false) else { fatalError("view") }
    view.debugSetLoads([0.9, 0.2, 0.65, 0.1, 0.45, 0.85, 0.3, 0.55, 0.15, 0.7])
    let b = view.bounds
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(b.width), pixelsHigh: Int(b.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let gctx = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("ctx") }
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = gctx
    view.animateOneFrame(); view.draw(b) // warm-up: builds grid + floor image
    let t0 = CFAbsoluteTimeGetCurrent()
    for _ in 0..<60 {
        view.animateOneFrame()
        view.draw(b)
    }
    let dt = CFAbsoluteTimeGetCurrent() - t0
    NSGraphicsContext.restoreGraphicsState()
    print(String(format: "avg sim+draw: %.2f ms/frame (60 frames)", dt / 60 * 1000))
    exit(0)
}

guard let view = UltracodeCPUView(frame: NSRect(origin: .zero, size: size), isPreview: false) else { fatalError("view") }
// 10 cores, mixed loads
view.debugSetLoads([0.9, 0.2, 0.65, 0.1, 0.45, 0.85, 0.3, 0.55, 0.15, 0.7])
for _ in 0..<20 { view.animateOneFrame() }
snapshot(view, to: "\(outDir)/cpu_mixed.png")
view.debugSetLoads([0.05,0.08,0.04,0.1,0.06,0.07,0.05,0.09])
for _ in 0..<20 { view.animateOneFrame() }
snapshot(view, to: "\(outDir)/cpu_idle.png")
