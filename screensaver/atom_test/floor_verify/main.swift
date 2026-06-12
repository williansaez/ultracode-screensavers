import AppKit
import ScreenSaver

// Floor verification: set "floorLevel" BEFORE creating the view, run the
// sim, snapshot. Usage: verify_floor <floorValue> <out.png>
_ = NSApplication.shared
let floorVal = Double(CommandLine.arguments[1])!
let outPath = CommandLine.arguments[2]

let d = ScreenSaverDefaults(forModuleWithName: "com.williansaez.ultracode-atom")!
d.set(floorVal, forKey: "floorLevel")
d.synchronize()

let size = NSSize(width: 1512, height: 982)
guard let view = UltracodeAtomView(frame: NSRect(origin: .zero, size: size),
                                   isPreview: false) else { fatalError() }
for _ in 1...600 { view.animateOneFrame() }

let b = view.bounds
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                 pixelsWide: Int(b.width), pixelsHigh: Int(b.height),
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0),
      let g = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("ctx") }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = g
view.draw(b)
g.flushGraphics()
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath) (floorLevel \(floorVal))")
