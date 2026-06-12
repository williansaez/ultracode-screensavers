import AppKit
import ScreenSaver

// Offline harness: hydrogen start, 2nd electron arrival at 5s, multi-shell.
_ = NSApplication.shared
let size = NSSize(width: 1512, height: 982)
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func snapshot(_ view: NSView, to path: String) {
    let b = view.bounds
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(b.width), pixelsHigh: Int(b.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let g = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("ctx") }
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = g
    view.draw(b); g.flushGraphics(); NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path)); print("wrote \(path)")
}

// Timing mode (ATOM_TIMING=1): pump sim + offscreen draw 60x, print avg
// ms/frame. Set the pitch pref beforehand (e.g. 8) via `defaults`.
if ProcessInfo.processInfo.environment["ATOM_TIMING"] != nil {
    guard let v = UltracodeAtomView(frame: NSRect(origin: .zero, size: size), isPreview: false) else { fatalError() }
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let g = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("ctx") }
    // Warm-up: grid + floor image build, plus a few sim frames for trails.
    for _ in 0..<120 { v.animateOneFrame() }
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = g
    v.draw(v.bounds)
    NSGraphicsContext.restoreGraphicsState()
    var total = 0.0
    for _ in 0..<60 {
        let t0 = CFAbsoluteTimeGetCurrent()
        v.animateOneFrame()
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = g
        v.draw(v.bounds)
        NSGraphicsContext.restoreGraphicsState()
        total += CFAbsoluteTimeGetCurrent() - t0
    }
    print(String(format: "avg sim+draw: %.3f ms/frame", total / 60 * 1000))
    exit(0)
}

guard let view = UltracodeAtomView(frame: NSRect(origin: .zero, size: size), isPreview: false) else { fatalError() }

// 30 fps: 5 s = 150 frames.
for f in 1...1500 {
    view.animateOneFrame()
    if f == 120 { snapshot(view, to: "\(outDir)/atom_hydrogen.png"); print("e- count:", view.debugElectronCount) }
    if f == 170 { snapshot(view, to: "\(outDir)/atom_arrival.png"); print("e- count:", view.debugElectronCount) }
    if f == 600 { snapshot(view, to: "\(outDir)/atom_2s.png"); print("e- count:", view.debugElectronCount) }
    if f == 1500 { snapshot(view, to: "\(outDir)/atom_shells.png"); print("e- count:", view.debugElectronCount) }
}
