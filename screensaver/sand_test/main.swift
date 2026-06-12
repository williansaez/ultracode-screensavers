import AppKit
import ScreenSaver

// Offline harness: render the sand saver at several simulation stages.

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

guard let view = UltracodeSandView(frame: NSRect(origin: .zero, size: size),
                                   isPreview: false) else {
    fatalError("failed to create view")
}

// Stage 1: early — small piles forming under the emitters.
for _ in 0..<300 { view.animateOneFrame() }
print("early: grains=\(view.debugGrainCount) draining=\(view.debugIsDraining)")
snapshot(view, to: "\(outDir)/sand_early.png")

// Stage 1b: a few frames later, to verify motion between frames.
for _ in 0..<12 { view.animateOneFrame() }
snapshot(view, to: "\(outDir)/sand_early_b.png")

// Stage 2: layered dunes — pump until the pile is substantial.
var fillPumped = 0
while view.debugGrainCount < 950 && !view.debugIsDraining && fillPumped < 30000 {
    view.animateOneFrame()
    fillPumped += 1
}
print("dunes after +\(fillPumped): grains=\(view.debugGrainCount) draining=\(view.debugIsDraining)")
snapshot(view, to: "\(outDir)/sand_dunes.png")

// Stage 3: drain phase — the pile must keep filling past 75% of the screen
// (old trigger) and the drain only opens when a settled grain reaches one of
// the top 2 rows or the grid is ~90% full. Pump until trigger, then catch it
// mid-flow.
var pumped = 0
var sawPast75 = false
while !view.debugIsDraining && pumped < 60000 {
    view.animateOneFrame()
    pumped += 1
    if !sawPast75 && view.debugMaxSettledHeight >= Int(Double(view.debugRows) * 0.80) {
        sawPast75 = true
        print("fill passed 75%: height=\(view.debugMaxSettledHeight)/\(view.debugRows) draining=\(view.debugIsDraining)")
        if view.debugIsDraining { print("ERROR: drain opened at/below 80% height") }
        snapshot(view, to: "\(outDir)/sand_fill_past75.png")
    }
}
print("drain opened after +\(pumped) frames, grains=\(view.debugGrainCount) " +
      "height=\(view.debugMaxSettledHeight)/\(view.debugRows)")
if !sawPast75 { print("ERROR: drain opened before the pile passed 75% height") }
snapshot(view, to: "\(outDir)/sand_full_trigger.png")
if view.debugIsDraining {
    for _ in 0..<60 { view.animateOneFrame() }
    print("mid-drain: grains=\(view.debugGrainCount) draining=\(view.debugIsDraining)")
    snapshot(view, to: "\(outDir)/sand_drain.png")
    // Run until the drain closes, then confirm refilling resumes.
    var closing = 0
    while view.debugIsDraining && closing < 20000 {
        view.animateOneFrame()
        closing += 1
    }
    print("drain closed after +\(closing) frames, grains=\(view.debugGrainCount)")
    for _ in 0..<300 { view.animateOneFrame() }
    print("refill: grains=\(view.debugGrainCount) draining=\(view.debugIsDraining)")
    snapshot(view, to: "\(outDir)/sand_refill.png")
} else {
    print("ERROR: drain never opened")
}
