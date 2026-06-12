import AppKit
import ScreenSaver

// Offline harness: pump the screensaver's animation clock and snapshot
// frames to PNG so the look can be checked without installing it.
// Also smoke-tests the configure sheet and renders each color theme.

_ = NSApplication.shared   // NSPanel creation needs an app instance

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

let defaults = ScreenSaverDefaults(forModuleWithName: "com.williansaez.ultracode-screensaver")!

for theme in 0..<3 {
    defaults.set(theme, forKey: "theme")
    defaults.synchronize()
    guard let view = UltracodeView(frame: NSRect(origin: .zero, size: size),
                                   isPreview: false) else {
        fatalError("failed to create view")
    }
    for _ in 0..<300 { view.animateOneFrame() }
    snapshot(view, to: "\(outDir)/theme_\(theme).png")
}

// Leave prefs on the default theme.
defaults.set(0, forKey: "theme")
defaults.synchronize()

// Low-intensity render: same shape, dimmer peak colors.
defaults.set(0.45, forKey: "intensity")
defaults.synchronize()
if let view = UltracodeView(frame: NSRect(origin: .zero, size: size), isPreview: false) {
    for _ in 0..<300 { view.animateOneFrame() }
    snapshot(view, to: "\(outDir)/intensity_low.png")
}
defaults.set(1.0, forKey: "intensity")
defaults.synchronize()

// Configure sheet smoke test: must build without crashing.
if let view = UltracodeView(frame: NSRect(origin: .zero, size: size), isPreview: false) {
    print("hasConfigureSheet:", view.hasConfigureSheet)
    print("configureSheet:", view.configureSheet != nil ? "built OK" : "FAILED")
}

// Freeze-frame pipeline test: stopAnimation must persist lastframe.png.
if let view = UltracodeView(frame: NSRect(origin: .zero, size: size), isPreview: false) {
    view.startAnimation()
    for _ in 0..<200 { view.animateOneFrame() }
    view.stopAnimation()
    let p = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Ultracode/lastframe.png").path
    print("freeze file:", FileManager.default.fileExists(atPath: p) ? "OK \(p)" : "MISSING \(p)")
}
