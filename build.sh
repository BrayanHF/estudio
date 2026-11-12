#!/bin/bash
# Compila Estudio.app (no necesita Xcode, solo las Command Line Tools)
set -e
cd "$(dirname "$0")"
APP=Estudio.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -parse-as-library -swift-version 5 -enable-bare-slash-regex -target arm64-apple-macosx26.0 \
  Sources/*.swift -o "$APP/Contents/MacOS/Estudio"
cp Info.plist "$APP/Contents/"
cp -R Resources/* "$APP/Contents/Resources/"
# las herramientas de voz (scripts e instalador) viajan dentro de la app
mkdir -p "$APP/Contents/Resources/herramientas"
for f in herramientas/*; do [ -f "$f" ] && cp "$f" "$APP/Contents/Resources/herramientas/"; done
# Firma con un certificado propio y fijo (firma/): así macOS recuerda los permisos
# de micrófono y grabación de pantalla entre versiones. Si no existe, firma provisional.
KC=~/Library/Keychains/afinador.keychain-db
if [ -f "$KC" ]; then
  security unlock-keychain -p afinador "$KC"
  codesign --force --keychain "$KC" --sign 103B453B7AF789544E07E8F03893E17C85828298 --identifier com.brayan.afinador "$APP"
else
  codesign --force --sign - "$APP"
fi
# Se instala en ~/Applications: Spotlight (⌘ + espacio) no muestra apps que están dentro de ~/Code
mkdir -p ~/Applications
rm -rf ~/Applications/"$APP"
ditto "$APP" ~/Applications/"$APP"
mdimport ~/Applications/"$APP" 2>/dev/null || true
echo "Listo: $(pwd)/$APP (instalada en ~/Applications/$APP)"
