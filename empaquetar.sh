#!/bin/bash
# Arma dist/Estudio-<versión>.zip para repartir (por ejemplo, en los releases de GitHub).
# Firma genérica (ad hoc): no usa el certificado personal de firma/. Quien la descargue la abre la primera vez con
# clic derecho → Abrir, porque no está notarizada por Apple.
set -e
cd "$(dirname "$0")"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
APP=dist/Estudio.app
rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/herramientas"
swiftc -O -parse-as-library -swift-version 5 -enable-bare-slash-regex -target arm64-apple-macosx26.0 \
  Sources/*.swift -o "$APP/Contents/MacOS/Estudio"
cp Info.plist "$APP/Contents/"
cp -R Resources/* "$APP/Contents/Resources/"
cp herramientas/* "$APP/Contents/Resources/herramientas/"
codesign --force --deep --sign - "$APP"
ditto -c -k --keepParent "$APP" "dist/Estudio-$VERSION.zip"
echo "Listo: $(pwd)/dist/Estudio-$VERSION.zip ($(du -h "dist/Estudio-$VERSION.zip" | cut -f1))"
