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
