#!/bin/bash
# Galeria da suite: janela única a navegar pelos .saver compilados.
# Uso: ./gallery.sh            # ← → mudam de saver, Esc sai
#      ./gallery.sh --auto 5   # avança sozinho a cada 5 s (e ← → continuam a funcionar)
set -euo pipefail
cd "$(dirname "$0")"

AUTO=0
if [[ "${1:-}" == "--auto" ]]; then AUTO=${2:-5}; fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/main.swift" <<EOF
import AppKit
import ScreenSaver

typealias InitFn = @convention(c) (AnyObject, Selector, NSRect, ObjCBool) -> AnyObject?

func makeSaverView(_ cls: ScreenSaverView.Type, frame: NSRect) -> ScreenSaverView? {
    let sel = Selector(("initWithFrame:isPreview:"))
    guard let method = class_getInstanceMethod(cls, sel),
          let allocated = (cls as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue()
    else { return nil }
    let fn = unsafeBitCast(method_getImplementation(method), to: InitFn.self)
    return fn(allocated, sel, frame, false) as? ScreenSaverView
}

final class GalleryDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var win: NSWindow!
    var frameTimer: Timer?
    var autoTimer: Timer?
    var current: ScreenSaverView?
    var savers: [(name: String, path: String)] = []
    var idx = 0
    let auto: Double = ${AUTO}

    func applicationDidFinishLaunching(_ n: Notification) {
        let fm = FileManager.default
        let cwd = fm.currentDirectoryPath
        savers = ((try? fm.contentsOfDirectory(atPath: cwd)) ?? [])
            .filter { \$0.hasSuffix(".saver") }
            .sorted()
            .map { (String(\$0.dropLast(6)), cwd + "/" + \$0) }
        guard !savers.isEmpty else { print("nenhum .saver aqui"); NSApp.terminate(nil); return }

        let rect = NSRect(x: 0, y: 0, width: 1280, height: 800)
        win = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .resizable],
                       backing: .buffered, defer: false)
        win.delegate = self
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            switch e.keyCode {
            case 53:  NSApp.terminate(nil)      // Esc
            case 123: self.show(self.idx - 1)   // ←
            case 124: self.show(self.idx + 1)   // →
            default:  return e
            }
            return nil
        }

        show(0)
        if auto > 0 {
            autoTimer = Timer.scheduledTimer(withTimeInterval: auto, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.show(self.idx + 1)
            }
        }
    }

    func show(_ i: Int) {
        let n = savers.count
        idx = ((i % n) + n) % n
        frameTimer?.invalidate()
        if let c = current, c.isAnimating { c.stopAnimation() }
        let (name, path) = savers[idx]

        guard let bundle = Bundle(path: path), bundle.load(),
              let cls = bundle.principalClass as? ScreenSaverView.Type,
              let view = makeSaverView(cls, frame: win.contentView?.bounds ?? .zero)
        else {
            win.title = "\(idx+1)/\(n)  \(name) — FALHOU A CARREGAR (←→ continua)"
            win.contentView = NSView()
            current = nil
            return
        }

        view.autoresizingMask = [.width, .height]
        win.contentView = view
        current = view
        win.title = "\(idx+1)/\(n)  \(name)   ←→ muda · Esc sai"
        view.startAnimation()
        frameTimer = Timer.scheduledTimer(withTimeInterval: view.animationTimeInterval, repeats: true) { _ in
            view.animateOneFrame()
            view.needsDisplay = true
        }
    }

    func windowWillClose(_ n: Notification) { NSApp.terminate(nil) }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = GalleryDelegate()
app.delegate = delegate
app.run()
EOF

swiftc -O "$TMP/main.swift" -framework ScreenSaver -framework AppKit -o "$TMP/gallery"
"$TMP/gallery"
