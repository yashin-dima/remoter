#!/bin/zsh
# Собирает Resources/AppIcon.icns из картинки.
#
#   ./Scripts/make-icon.sh ~/Desktop/image.png
#
# Запускается один раз: результат (AppIcon.icns) лежит в репозитории, сборка его просто копирует.
set -e
cd "$(dirname "$0")/.."

SRC="${1:-Resources/AppIcon-source.png}"
[[ -f "$SRC" ]] || { echo "Нет картинки: $SRC"; exit 1; }

mkdir -p Resources
# Оригинал храним рядом: если понадобится пересобрать иконку, не придётся искать его по дискам.
[[ "$(cd "$(dirname "$SRC")" && pwd)/$(basename "$SRC")" == "$PWD/Resources/AppIcon-source.png" ]] \
  || cp "$SRC" Resources/AppIcon-source.png

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

swift Scripts/icon-tool.swift Resources/AppIcon-source.png "$WORK/icon.png"

SET="$WORK/AppIcon.iconset"
mkdir -p "$SET"
for size in 16 32 128 256 512; do
  sips -z $size $size "$WORK/icon.png" --out "$SET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$WORK/icon.png" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$SET" -o Resources/AppIcon.icns
echo "Готово → Resources/AppIcon.icns"
