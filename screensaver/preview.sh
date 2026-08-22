#!/bin/bash
# Pré-visualiza um saver da suite numa janela, sem passar pelas Definições de Sistema.
# Uso: ./preview.sh <NomeDoSaver> [segundos]
#   ex.: ./preview.sh UltracodeGlobe        # janela 1280x800, Esc ou fechar para sair
#   ex.: ./preview.sh UltracodeAtom 10      # fecha sozinho após 10 s
set -euo pipefail
cd "$(dirname "$0")"

NAME=${1:?uso: ./preview.sh <NomeDoSaver> [segundos] — ex.: ./preview.sh UltracodeGlobe}
SECS=${2:-0}
SRC="${NAME}View.swift"
[[ -f "$SRC" ]] || { echo "não existe $SRC"; ls Ultracode*View.swift | sed 's/View\.swift//'; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/main.swift" <<EOF
import AppKit
import ScreenSaver

final class PreviewDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var timer: Timer?
    func applicationDidFinishLaunching(_ n: Notification) {
        let rect = NSRect(x: 0, y: 0, width: 1280, height: 800)
        let win = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "${NAME} — preview (Esc fecha)"
        win.delegate = self
        let view = ${NAME}View(frame: rect, isPreview: false)!
        view.autoresizingMask = [.width, .height]
        win.contentView = view
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        view.startAnimation()
        timer = Timer.scheduledTimer(withTimeInterval: view.animationTimeInterval, repeats: true) { _ in
            view.animateOneFrame()
            view.needsDisplay = true
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { NSApp.terminate(nil) }
            return e
        }
        if ${SECS} > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(${SECS})) { NSApp.terminate(nil) }
        }
    }
    func windowWillClose(_ n: Notification) { NSApp.terminate(nil) }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = PreviewDelegate()
app.delegate = delegate
app.run()
EOF

swiftc -O "$SRC" "$TMP/main.swift" \
  -framework ScreenSaver -framework AppKit -framework IOKit \
  -framework Metal -framework QuartzCore \
  -o "$TMP/preview"

# Recursos do bundle (ex.: land.bin do Globo) ao lado do binário para Bundle.main os encontrar
if [[ -d "$NAME.saver/Contents/Resources" ]]; then
  cp -R "$NAME.saver/Contents/Resources/." "$TMP/"
fi

"$TMP/preview"
