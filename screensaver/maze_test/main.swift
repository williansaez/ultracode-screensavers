import AppKit
import ScreenSaver

// Offline harness: render the maze saver at meaningful stages of its loop.

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

guard let view = UltracodeMazeView(frame: NSRect(origin: .zero, size: size),
                                   isPreview: false) else {
    fatalError("failed to create view")
}

func pump(_ n: Int) {
    for _ in 0..<n { view.animateOneFrame() }
}

/// Pump until the saver reaches the named phase (or a frame budget runs out).
func pumpUntil(phase name: String, maxFrames: Int = 4000) {
    var i = 0
    while view.debugPhaseName != name && i < maxFrames {
        view.animateOneFrame()
        i += 1
    }
    print("reached \(view.debugPhaseName) after \(i) extra frames")
}

// 1) Mid-generation: partial maze with the bright carving head.
pump(70)
print("phase now: \(view.debugPhaseName)")
snapshot(view, to: "\(outDir)/maze_midgen.png")

// 2) A bit later in generation: must differ from snapshot 1 (motion check).
pump(40)
print("phase now: \(view.debugPhaseName)")
snapshot(view, to: "\(outDir)/maze_midgen2.png")

// 3) Solving: BFS frontier visible as faint highlight spreading.
pumpUntil(phase: "solving")
pump(20)
print("phase now: \(view.debugPhaseName)")
snapshot(view, to: "\(outDir)/maze_solving.png")

// 4) Mid-trace: solution path partially lit with bright tip.
pumpUntil(phase: "tracing")
pump(12)
print("phase now: \(view.debugPhaseName)")
snapshot(view, to: "\(outDir)/maze_tracing.png")

// 5) Holding: complete maze with the full solution path lit.
pumpUntil(phase: "holding")
pump(5)
print("phase now: \(view.debugPhaseName)")
snapshot(view, to: "\(outDir)/maze_path.png")

// 6) Dissolve then restart: loop must come back around to generating.
pumpUntil(phase: "dissolving")
pump(10)
snapshot(view, to: "\(outDir)/maze_dissolving.png")
pumpUntil(phase: "generating")
pump(70)
print("phase after restart: \(view.debugPhaseName)")
snapshot(view, to: "\(outDir)/maze_secondrun.png")
