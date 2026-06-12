import AppKit
import ScreenSaver

// Offline harness: render the Gray-Scott reaction-diffusion saver at
// several growth stages and dump field statistics.

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

guard let view = UltracodeGrayScottView(frame: NSRect(origin: .zero, size: size),
                                        isPreview: false) else {
    fatalError("failed to create view")
}

// Snapshot at meaningful growth stages: early spots, expansion, labyrinth,
// and past the first quiet-area reseed (~frame 600 at 30 fps).
let stages = [60, 200, 400, 650]
var frame = 0
for stage in stages {
    while frame < stage {
        view.animateOneFrame()
        frame += 1
    }
    view.debugDump()
    snapshot(view, to: "\(outDir)/gs_f\(stage).png")
}
