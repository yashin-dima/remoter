#!/bin/zsh
# Сборка Remoter.app.
#
# Swift-код собирает SPM (нужна зависимость SwiftTerm), а бандл приложения мы собираем руками:
# кладём бинарь, Info.plist, Monaco и askpass-хелпер, потом подписываем.
set -e
set -o pipefail
cd "$(dirname "$0")"

APP="Remoter.app"
CONTENTS="$APP/Contents"
CONFIG="${1:-release}"

# Monaco нужен в бандле — без него редактор не откроется.
if [[ ! -f "Web/vs/loader.js" ]]; then
  echo "Monaco не найден, ставлю…"
  ./Scripts/vendor-monaco.sh
fi

echo "Собираю ($CONFIG)…"
# Без пайпа: упавшая компиляция обязана валить скрипт. Раньше стояло `... | grep ... || true`,
# и при ошибке компиляции в бандл молча уезжал СТАРЫЙ бинарь от прошлой удачной сборки.
if ! BUILD_OUT=$(swift build -c "$CONFIG" 2>&1); then
  printf '%s\n' "$BUILD_OUT"
  echo "Сборка не прошла" >&2
  exit 1
fi
# На успехе показываем вывод без строк прогресса вида "[123/456] Compiling…".
printf '%s\n' "$BUILD_OUT" | grep -v "^\[" || true

BIN=$(swift build -c "$CONFIG" --show-bin-path)/Remoter
[[ -f "$BIN" ]] || { echo "Сборка не дала бинарь"; exit 1; }

mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN" "$CONTENTS/MacOS/Remoter"

# Info.plist и иконка — исходники, а не результат сборки: раньше они жили только внутри бандла,
# и «rm -rf Remoter.app» унёс бы их с собой.
cp Resources/Info.plist "$CONTENTS/Info.plist"
# CFBundleVersion — из времени сборки: Launch Services видит «новую версию» и сам перечитывает
# иконку и plist. Раньше для этого перезапускался Dock у пользователя на каждую сборку.
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d.%H%M%S)" "$CONTENTS/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$CONTENTS/Resources/AppIcon.icns"

# Ресурсы кладём заново: иначе удалённые файлы остались бы в бандле от прошлой сборки.
rm -rf "$CONTENTS/Resources/web"
mkdir -p "$CONTENTS/Resources/web"
cp -R Web/. "$CONTENTS/Resources/web/"
cp Scripts/askpass.sh "$CONTENTS/Resources/askpass.sh"
chmod +x "$CONTENTS/Resources/askpass.sh"

# Стабильная подпись: adhoc меняет хеш при каждой сборке, и macOS каждый раз считает
# приложение новым — слетают разрешения и заново спрашивается доступ к связке ключей.
# Самоподписанный сертификат держит подпись неизменной.
#
# Сертификат «SSHDiff» — из времён, когда так звалось приложение. Он ничем не хуже, и пока он
# есть, подпись остаётся стабильной: перевыпускать его только ради имени незачем.
#
# `-v` обязателен: без него find-identity перечисляет и просроченные/отозванные сертификаты,
# и codesign падал бы, выбрав мёртвый. CERT инициализируем явно, чтобы не подобрать
# одноимённую переменную из окружения.
CERT=""
IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null || true)
if grep -q '"Remoter"' <<< "$IDENTITIES"; then
  CERT="Remoter"
elif grep -q '"SSHDiff"' <<< "$IDENTITIES"; then
  CERT="SSHDiff"
fi

if [[ -n "$CERT" ]]; then
  codesign --force --deep --sign "$CERT" "$APP"
  echo "Собрано и подписано сертификатом $CERT → $APP"
else
  # Ошибки codesign не глушим: молча неподписанный бандл хуже, чем видимая ошибка.
  codesign --force --deep --sign - "$APP"
  echo "Собрано (adhoc) → $APP"
  echo "  ⚠️  Запусти ./Scripts/make-signing-cert.sh один раз — подпись станет стабильной."
fi

# Перерегистрируем бандл в Launch Services: вместе со свежим CFBundleVersion этого достаточно,
# чтобы иконка и plist обновились без перезапуска Dock.
touch "$APP"
LSREG=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
if [[ -x "$LSREG" ]]; then
  "$LSREG" -f "$APP"
fi
