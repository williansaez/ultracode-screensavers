import AppKit
import ScreenSaver

// Offline harness: render the lightning saver at meaningful stages —
// mid-growth (dim jagged path), flash (bright branched bolt), fade, pause.

_ = NSApplication.shared

let size = NSSize(width: 1512, height: 982)
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

// Optional perf harness (LIGHTNING_TIMING=1): pump sim+draw into an offscreen
// bitmap 60 times and print the average ms/frame. Set the pitch beforehand:
//   defaults -currentHost write com.williansaez.ultracode-lightning pitch -float 8
if ProcessInfo.processInfo.environment["LIGHTNING_TIMING"] != nil {
    guard let v = UltracodeLightningView(frame: NSRect(origin: .zero, size: size),
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
    // Warm up so an active bolt (the heavy case) is in flight during timing.
    for _ in 0..<80 { v.animateOneFrame() }
    let t0 = Date()
    for _ in 0..<60 {
        v.animateOneFrame()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gctx
        v.draw(v.bounds)
        NSGraphicsContext.restoreGraphicsState()
    }
    let ms = -t0.timeIntervalSinceNow * 1000.0 / 60.0
    print(String(format: "TIMING avg %.3f ms/frame (sim+draw, 60 frames)", ms))
    exit(0)
}

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

guard let view = UltracodeLightningView(frame: NSRect(origin: .zero, size: size),
                                        isPreview: false) else {
    fatalError("failed to create view")
}

var gotGrowth = false
var gotFlash = false
var gotFade = false
var frame = 0

while frame < 3000 && !(gotGrowth && gotFlash && gotFade) {
    view.animateOneFrame()
    frame += 1

    if !gotGrowth, view.debugActiveBolts > 0, !view.debugIsFlashing,
       view.debugMainPathLen > 15 {
        snapshot(view, to: "\(outDir)/lightning_growth.png")
        print("growth at frame \(frame), mainPath=\(view.debugMainPathLen)")
        gotGrowth = true
    }
    if gotGrowth, !gotFlash, view.debugIsFlashing {
        // One more frame so the flash stamping lands in the trail grid.
        view.animateOneFrame()
        frame += 1
        snapshot(view, to: "\(outDir)/lightning_flash.png")
        print("flash at frame \(frame), maxTrail=\(view.debugMaxTrail)")
        gotFlash = true
        // Fade snapshot ~12 frames after the flash ends.
        for _ in 0..<16 { view.animateOneFrame(); frame += 1 }
        snapshot(view, to: "\(outDir)/lightning_fade.png")
        print("fade at frame \(frame), maxTrail=\(view.debugMaxTrail)")
        gotFade = true
    }
}

// Dark-pause frame: run until no bolts and trail fully gone.
var spins = 0
while (view.debugActiveBolts > 0 || view.debugMaxTrail > 0.03) && spins < 600 {
    view.animateOneFrame()
    spins += 1
}
snapshot(view, to: "\(outDir)/lightning_pause.png")
print("pause after \(spins) extra frames, maxTrail=\(view.debugMaxTrail)")

print(gotGrowth && gotFlash && gotFade ? "ALL STAGES CAPTURED" : "MISSING STAGES")
