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

// Perf mode (LIFE_PERF=1): pump sim + offscreen draw 60x, print avg ms/frame.
// Set the pitch pref BEFORE launching (defaults -currentHost write ...).
// The offscreen target mimics the deployed window backing store: Retina
// scale, BGRA little-endian, sRGB.
if ProcessInfo.processInfo.environment["LIFE_PERF"] == "1" {
    let scale = 2
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let cg = CGContext(
              data: nil,
              width: Int(size.width) * scale, height: Int(size.height) * scale,
              bitsPerComponent: 8, bytesPerRow: 0, space: space,
              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                  | CGBitmapInfo.byteOrder32Little.rawValue)
    else {
        fatalError("failed to create perf bitmap context")
    }
    cg.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    let gctx = NSGraphicsContext(cgContext: cg, flipped: false)
    view.animateOneFrame()   // warm up: build grid + floor image
    let frames = 60
    let t0 = CFAbsoluteTimeGetCurrent()
    for _ in 0..<frames {
        view.animateOneFrame()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gctx
        view.draw(view.bounds)
        gctx.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
    }
    let dt = CFAbsoluteTimeGetCurrent() - t0
    print(String(format: "perf: %.2f ms/frame avg over %d frames",
                 dt * 1000 / Double(frames), frames))
    exit(0)
}
for gen in 1...120 {
    view.animateOneFrame()
    if gen == 2 { snapshot(view, to: "\(outDir)/life_g2.png") }
    if gen == 40 { snapshot(view, to: "\(outDir)/life_g40.png") }
    if gen == 120 { snapshot(view, to: "\(outDir)/life_g120.png") }
}

print("hasConfigureSheet:", view.hasConfigureSheet)
print("configureSheet:", view.configureSheet != nil ? "built OK" : "FAILED")
