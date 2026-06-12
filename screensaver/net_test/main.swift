import AppKit
import ScreenSaver

_ = NSApplication.shared
let size = NSSize(width: 1512, height: 982)
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func snapshot(_ view: NSView, to path: String) {
    let b = view.bounds
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(b.width), pixelsHigh: Int(b.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let gctx = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("ctx") }
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = gctx
    view.draw(b); gctx.flushGraphics(); NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path)); print("wrote \(path)")
}

// Perf mode (ULTRA_PERF=1): time sim+draw, no snapshots. Set the pitch pref
// first (e.g. `defaults -currentHost write com.williansaez.ultracode-network
// pitch -float 8`) and reset it afterwards.
if ProcessInfo.processInfo.environment["ULTRA_PERF"] != nil {
    guard let pv = UltracodeNetworkView(frame: NSRect(origin: .zero, size: size), isPreview: false) else { fatalError("view") }
    let b = pv.bounds
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(b.width), pixelsHigh: Int(b.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let gctx = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("ctx") }
    for (name, down, up) in [("stream 8MB/s", Float(8_000_000), Float(200_000)),
                             ("heavy 30MB/s", Float(30_000_000), Float(30_000_000))] {
        pv.debugSetRates(down: down, up: up)
        for _ in 0..<90 { pv.animateOneFrame() }   // reach steady state
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = gctx
        let t0 = CFAbsoluteTimeGetCurrent()
        for _ in 0..<60 { pv.animateOneFrame(); pv.draw(b) }
        let dt = CFAbsoluteTimeGetCurrent() - t0
        NSGraphicsContext.restoreGraphicsState()
        print(String(format: "perf %@: %.2f ms/frame (sim+draw avg of 60)", name, dt / 60 * 1000))
    }
    exit(0)
}

guard let view = UltracodeNetworkView(frame: NSRect(origin: .zero, size: size), isPreview: false) else { fatalError("view") }

// Idle: ~5 KB/s down, 1 KB/s up
view.debugSetRates(down: 5_000, up: 1_000)
for _ in 0..<90 { view.animateOneFrame() }
snapshot(view, to: "\(outDir)/net_idle.png")

// Streaming: ~8 MB/s down, 200 KB/s up
view.debugSetRates(down: 8_000_000, up: 200_000)
for _ in 0..<90 { view.animateOneFrame() }
snapshot(view, to: "\(outDir)/net_stream.png")

// Heavy upload: 30 MB/s both ways
view.debugSetRates(down: 30_000_000, up: 30_000_000)
for _ in 0..<90 { view.animateOneFrame() }
snapshot(view, to: "\(outDir)/net_heavy.png")
