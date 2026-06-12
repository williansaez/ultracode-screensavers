import AppKit
import ScreenSaver

// Offline harness for the Physarum saver: pump the growth and snapshot
// the dendritic network at several stages; smoke-test the configure sheet.

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

// Performance mode (PHYS_PERF=1): time sim+draw at the CURRENT prefs.
// Set the pitch first, e.g.:
//   defaults -currentHost write com.williansaez.ultracode-physarum pitch -float 8
if ProcessInfo.processInfo.environment["PHYS_PERF"] != nil {
    guard let v = UltracodePhysarumView(frame: NSRect(origin: .zero, size: size),
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
    for _ in 0..<120 { v.animateOneFrame() }   // warm up
    // Time consecutive 60-frame windows across a whole grow/hold/dissolve
    // lifecycle; the worst window covers the densest (hold) phase.
    var worst = 0.0
    for w in 0..<40 {
        let t0 = Date()
        for _ in 0..<60 {
            v.animateOneFrame()
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = gctx
            v.draw(v.bounds)
            NSGraphicsContext.restoreGraphicsState()
        }
        let ms = Date().timeIntervalSince(t0) / 60 * 1000
        if ms > worst { worst = ms }
        print(String(format: "window %2d: %.2f ms/frame", w, ms))
        v.debugDump()
    }
    print(String(format: "perf: %.2f ms/frame avg in WORST 60-frame window (sim+draw)",
                 worst))
    exit(0)
}

guard let view = UltracodePhysarumView(frame: NSRect(origin: .zero, size: size),
                                       isPreview: false) else {
    fatalError("failed to create view")
}

let t0 = Date()
let captures: [Int: String] = [
    20: "\(outDir)/phys_t20.png",
    60: "\(outDir)/phys_t60.png",
    120: "\(outDir)/phys_t120.png",
    220: "\(outDir)/phys_t220.png",
    400: "\(outDir)/phys_t400.png",
]
for frame in 1...700 {
    view.animateOneFrame()
    if let path = captures[frame] { snapshot(view, to: path); view.debugDump() }
}
let dt = Date().timeIntervalSince(t0)
print(String(format: "360 frames in %.2fs => %.1f fps (incl 4 snapshots)", dt, 360.0 / dt))

print("hasConfigureSheet:", view.hasConfigureSheet)
print("configureSheet:", view.configureSheet != nil ? "built OK" : "FAILED")
