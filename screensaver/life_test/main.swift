import AppKit
import ScreenSaver

// Offline harness for the Game of Life saver: pump generations and
// snapshot frames; smoke-test the configure sheet.

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

guard let view = UltracodeLifeView(frame: NSRect(origin: .zero, size: size),
                                   isPreview: false) else {
    fatalError("failed to create view")
}
for gen in 1...120 {
    view.animateOneFrame()
    if gen == 2 { snapshot(view, to: "\(outDir)/life_g2.png") }
    if gen == 40 { snapshot(view, to: "\(outDir)/life_g40.png") }
    if gen == 120 { snapshot(view, to: "\(outDir)/life_g120.png") }
}

print("hasConfigureSheet:", view.hasConfigureSheet)
print("configureSheet:", view.configureSheet != nil ? "built OK" : "FAILED")
