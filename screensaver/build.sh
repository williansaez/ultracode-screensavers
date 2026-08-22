#!/bin/bash
# Compila, assina (ad-hoc) e instala todos os screensavers da suite Ultracode.
# Uso: ./build.sh [--install]
set -euo pipefail
cd "$(dirname "$0")"

INSTALL=${1:-}

SAVERS=(
  "Ultracode"
  "UltracodeLife"
  "UltracodePhysarum"
  "UltracodeCPU"
  "UltracodeNetwork"
  "UltracodeBattery:IOKit"
  "UltracodeClock"
  "UltracodeGrayScott"
  "UltracodeBoids"
  "UltracodeMaze"
  "UltracodeLightning"
  "UltracodeSand"
  "UltracodeSnake"
  "UltracodePong"
  "UltracodeAtom"
  "UltracodeChromaticWaves:Metal"
  "UltracodeTextWave"
  "UltracodeParticleSphere:Metal"
  "UltracodeGlobe"
  "UltracodePixelCard"
  "UltracodeDotMatrix"
  "UltracodeLineRipple"
)

for spec in "${SAVERS[@]}"; do
  name="${spec%%:*}"
  extra=""
  [[ "$spec" == *:IOKit ]] && extra="-framework IOKit"
  [[ "$spec" == *:Metal ]] && extra="-framework Metal -framework QuartzCore"
  echo "→ $name"
  mkdir -p "$name.saver/Contents/MacOS"
  # shellcheck disable=SC2086
  swiftc -O -emit-library "${name}View.swift" \
    -framework ScreenSaver -framework AppKit $extra \
    -module-name "$name" -o "$name.saver/Contents/MacOS/$name"
  codesign --force --deep --sign - "$name.saver"
  if [[ "$INSTALL" == "--install" ]]; then
    rm -rf "$HOME/Library/Screen Savers/$name.saver"
    cp -R "$name.saver" "$HOME/Library/Screen Savers/"
  fi
done

if [[ "$INSTALL" == "--install" ]]; then
  killall legacyScreenSaver 2>/dev/null || true
  echo "Instalados em ~/Library/Screen Savers (agente de screensavers reiniciado)."
else
  echo "Bundles compilados. Para instalar: ./build.sh --install"
fi
