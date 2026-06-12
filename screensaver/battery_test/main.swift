import AppKit
import ScreenSaver

// Offline harness: render the battery saver at several charge levels.

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

guard let view = UltracodeBatteryView(frame: NSRect(origin: .zero, size: size),
                                      isPreview: false) else {
    fatalError("failed to create view")
}

// (pct, charging, lowPowerMode, name)
let cases: [(Float, Bool, Bool, String)] = [
    (0.85, false, false, "green85"),
    (0.62, false, true,  "lpm62"),
    (0.12, false, false, "red12"),
    (0.40, true,  false, "charging40"),
]
for (pct, chg, lpm, name) in cases {
    view.debugSetBattery(pct, charging: chg)
    view.debugSetLowPower(lpm)
    for _ in 0..<30 { view.animateOneFrame() }
    snapshot(view, to: "\(outDir)/batt_\(name).png")
}
