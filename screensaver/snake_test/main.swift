import AppKit
import ScreenSaver

// Offline harness: render the self-playing Snake saver at several stages.

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

// Perf mode (SNAKE_PERF=1): set the pitch pref to 8 beforehand
// (defaults -currentHost write com.williansaez.ultracode-snake pitch -float 8),
// then time 60 frames of sim + offscreen draw and print the average.
if ProcessInfo.processInfo.environment["SNAKE_PERF"] != nil {
    guard let v = UltracodeSnakeView(frame: NSRect(origin: .zero, size: size),
                                     isPreview: false) else {
        fatalError("failed to create view")
    }
    for _ in 0..<10 { v.animateOneFrame() }   // warm-up: grid + floor image
    let b = v.bounds
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(b.width), pixelsHigh: Int(b.height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let gctx = NSGraphicsContext(bitmapImageRep: rep) else {
        fatalError("failed to create bitmap context")
    }
    let frames = 60
    let t0 = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<frames {
        v.animateOneFrame()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gctx
        v.draw(b)
        gctx.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
    }
    let t1 = DispatchTime.now().uptimeNanoseconds
    let ms = Double(t1 - t0) / 1_000_000.0 / Double(frames)
    print(String(format: "perf: %.2f ms/frame (sim+draw, %d frames, %dx%d)",
                 ms, frames, Int(b.width), Int(b.height)))
    exit(0)
}

guard let view = UltracodeSnakeView(frame: NSRect(origin: .zero, size: size),
                                    isPreview: false) else {
    fatalError("failed to create view")
}

// Stage 1: fresh board, snake length 6 plus food.
for _ in 0..<10 { view.animateOneFrame() }
snapshot(view, to: "\(outDir)/snake_start.png")

// Stage 2: after ~150 frames (~75 moves) the snake has moved and likely
// eaten at least once -> position AND length must differ from stage 1.
for _ in 0..<150 { view.animateOneFrame() }
snapshot(view, to: "\(outDir)/snake_mid.png")

// Stage 3: long run -> visibly longer body with a clear gradient.
for _ in 0..<2000 { view.animateOneFrame() }
snapshot(view, to: "\(outDir)/snake_late.png")

// Stage 4: a couple frames later, to verify frame-to-frame motion.
for _ in 0..<30 { view.animateOneFrame() }
snapshot(view, to: "\(outDir)/snake_late2.png")
