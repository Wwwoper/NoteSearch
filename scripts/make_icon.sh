#!/bin/bash
# Генерирует набор иконок AppIcon.appiconset из одного PNG 1024x1024 (только macOS, использует sips).
#
#   bash scripts/make_icon.sh [исходный.png] [папка-appiconset]
#
# По умолчанию: assets/icon-1024.png -> NoteSearch/Assets.xcassets/AppIcon.appiconset
set -euo pipefail

SRC="${1:-assets/icon-1024.png}"
DEST="${2:-NoteSearch/Assets.xcassets/AppIcon.appiconset}"

if [ ! -f "$SRC" ]; then
  echo "Не найден исходный файл: $SRC" >&2
  exit 1
fi

mkdir -p "$DEST"

make() {
  sips -z "$1" "$1" "$SRC" --out "$DEST/$2" >/dev/null
}

make 16   icon_16x16.png
make 32   icon_16x16@2x.png
make 32   icon_32x32.png
make 64   icon_32x32@2x.png
make 128  icon_128x128.png
make 256  icon_128x128@2x.png
make 256  icon_256x256.png
make 512  icon_256x256@2x.png
make 512  icon_512x512.png
make 1024 icon_512x512@2x.png

cat > "$DEST/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "icon_16x16.png",      "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png",   "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png",      "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png",   "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png",    "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png",    "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png",    "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

echo "Готово: $DEST"
