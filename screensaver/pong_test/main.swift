import AppKit
import ScreenSaver

// Offline harness: render the Pong saver at several rally stages.

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

guard let view = UltracodePongView(frame: NSRect(origin: .zero, size: size),
                                   isPreview: false) else {
    fatalError("failed to create view")
}

// Stage 1: a few frames in — ball near center with a fresh tail.
for _ in 0..<10 { view.animateOneFrame() }
snapshot(view, to: "\(outDir)/pong_t10.png")

// Stage 2: 50 frames later — ball must have moved, paddles tracked.
for _ in 0..<50 { view.animateOneFrame() }
snapshot(view, to: "\(outDir)/pong_t60.png")

// Stage 3: mid-rally after several paddle exchanges.
for _ in 0..<240 { view.animateOneFrame() }
snapshot(view, to: "\(outDir)/pong_t300.png")

// Stage 4: rig a guaranteed miss, run until the score flash is live.
view.debugSetAimError(5.0)
var flashShot = false
for i in 0..<1200 {
    view.animateOneFrame()
    if view.debugIsFlashing {
        // A couple more frames so the flash is clearly mid-display.
        view.animateOneFrame()
        snapshot(view, to: "\(outDir)/pong_flash.png")
        print("flash captured at frame \(i)")
        flashShot = true
        break
    }
}
if !flashShot { print("WARNING: no flash captured in 1200 frames") }
view.debugClearAimError()

// Stage 5: after the pause, ball is back in play.
for _ in 0..<90 { view.animateOneFrame() }
snapshot(view, to: "\(outDir)/pong_resume.png")
