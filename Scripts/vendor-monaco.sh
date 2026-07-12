#!/bin/zsh
# Кладёт Monaco (движок редактора VS Code) в Web/vs — рядом с editor.html.
# Запускается один раз; результат лежит в проекте и в интернете больше не нуждается.
set -eu
cd "$(dirname "$0")/.."

VERSION="${1:-0.52.2}"
DEST="Web/vs"

# Ожидаемый SHA-256 тарбола для версии по умолчанию. Этот код грузится прямо в WebView, поэтому
# доверять одному лишь реестру npm мало: сверяем скачанное с закреплённым здесь хэшем, и любая
# подмена (компрометация пакета, прокси, зеркала) обрывает установку, а не уезжает в редактор.
# Для другой версии хэша у нас нет — тогда пропускаем сверку и честно об этом говорим
# (обновляя версию, впишите сюда её `shasum -a 256 monaco-editor-<версия>.tgz`).
DEFAULT_VERSION="0.52.2"
EXPECTED_SHA256="c280cdcf0b0c13d1a2bf01af958d4387ed06d7f6c918401d00c4adcae1bc72b6"

if [[ -f "$DEST/loader.js" ]]; then
  echo "Monaco уже на месте ($DEST). Для обновления: rm -rf $DEST && $0 <версия>"
  exit 0
fi

echo "Качаю monaco-editor@$VERSION…"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cd "$TMP"
npm pack "monaco-editor@$VERSION" >/dev/null

TARBALL="monaco-editor-$VERSION.tgz"
if [[ "$VERSION" == "$DEFAULT_VERSION" ]]; then
  GOT=$(shasum -a 256 "$TARBALL" | cut -d' ' -f1)
  if [[ "$GOT" != "$EXPECTED_SHA256" ]]; then
    echo "✗ SHA-256 не совпал для $TARBALL:" >&2
    echo "  ждали:  $EXPECTED_SHA256" >&2
    echo "  видим:  $GOT" >&2
    echo "  Установка прервана — этот код грузится в редактор, доверять непроверенному нельзя." >&2
    exit 1
  fi
  echo "SHA-256 совпал."
else
  echo "⚠️  Версия $VERSION не $DEFAULT_VERSION — сверять хэш не с чем, доверяем integrity npm."
fi

tar xzf "$TARBALL"
cd - >/dev/null

# Копируем всегда в чистый каталог: неполный Web/vs от прерванной прошлой загрузки
# (есть каталог, нет loader.js) при `cp -R` дал бы вложенный Web/vs/vs.
rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"
# min/vs — это собранная, минифицированная сборка: ровно то, что нужно грузить в WebView.
#
# Копируем ЦЕЛИКОМ, включая nls.messages.*.js. Выкидывать локализации нельзя, хотя соблазн есть:
# на русской системе Monaco грузит nls.messages.ru.js и внутри воркера, который считает diff.
# Файла нет → воркер падает → diff молча не появляется, а редактор при этом выглядит рабочим.
cp -R "$TMP/package/min/vs" "$DEST"

echo "Готово: $DEST ($(du -sh "$DEST" | cut -f1))"
