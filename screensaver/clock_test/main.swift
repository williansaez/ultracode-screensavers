import AppKit
import ScreenSaver

// Offline harness: render the clock saver at fixed times, including a
// mid-transition frame after a minute change.

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

// Perf mode (CLOCK_PERF=1): pump sim + offscreen draw 60 times and print the
// average ms/frame. Pitch comes from prefs — set it to 8 first, e.g.:
//   defaults -currentHost write com.williansaez.ultracode-clock pitch -float 8
if ProcessInfo.processInfo.environment["CLOCK_PERF"] != nil {
    guard let pv = UltracodeClockView(frame: NSRect(origin: .zero, size: size),
                                      isPreview: false) else {
        fatalError("failed to create view")
    }
    pv.debugSetTime(10, 58, colonOn: true)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let gctx = NSGraphicsContext(bitmapImageRep: rep) else {
        fatalError("failed to create bitmap context")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gctx
    for _ in 0..<5 {                       // warm-up (includes grid build)
        pv.animateOneFrame()
        pv.draw(pv.bounds)
    }
    let t0 = CFAbsoluteTimeGetCurrent()
    for frame in 0..<60 {
        if frame == 20 {                   // mid-run minute change: worst case
            pv.debugSetTime(10, 59, colonOn: true)
        }
        pv.animateOneFrame()
        pv.draw(pv.bounds)
    }
    let elapsed = CFAbsoluteTimeGetCurrent() - t0
    NSGraphicsContext.restoreGraphicsState()
    print(String(format: "perf: %.2f ms/frame avg (60 frames, sim+draw)",
                 elapsed / 60 * 1000))
    exit(0)
}

guard let view = UltracodeClockView(frame: NSRect(origin: .zero, size: size),
                                    isPreview: false) else {
    fatalError("failed to create view")
}

// Settled time, colon on.
view.debugSetTime(10, 58, colonOn: true)
for _ in 0..<60 { view.animateOneFrame() }
snapshot(view, to: "\(outDir)/clock_1058_on.png")

// Same time, colon off (blink check).
view.debugSetTime(10, 58, colonOn: false)
for _ in 0..<20 { view.animateOneFrame() }
snapshot(view, to: "\(outDir)/clock_1058_off.png")

// Minute change -> capture mid-transition (~0.33 s into a ~1 s dissolve).
view.debugSetTime(10, 59, colonOn: true)
for _ in 0..<10 { view.animateOneFrame() }
snapshot(view, to: "\(outDir)/clock_1059_mid.png")

// Fully settled new minute.
for _ in 0..<80 { view.animateOneFrame() }
snapshot(view, to: "\(outDir)/clock_1059_settled.png")
