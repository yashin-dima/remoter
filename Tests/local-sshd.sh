#!/bin/zsh
# Поднимает локальный sshd на 127.0.0.1:2222 и тестовый git-репозиторий со всеми видами
# изменений, потом печатает переменные для `swift test`.
#
# sshd запускается от текущего пользователя на непривилегированном порту — sudo не нужен,
# в системные настройки (Remote Login) мы не лезем и ничего в ~/.ssh не правим.
#
#   ./Tests/local-sshd.sh          # поднять
#   ./Tests/local-sshd.sh stop     # остановить
set -e

# pwd -P: TMPDIR на маке лежит за симлинком, а git отдаёт разрешённые пути —
# без этого корень репозитория и пути в тестах оказались бы разными строками.
DIR="$(cd "${TMPDIR:-/tmp}" && pwd -P)/remoter-test"
SSHD="$DIR/sshd"
REPO="$DIR/repo"
# Короткий путь: у unix-сокета лимит 104 байта, а $TMPDIR на маке длинный.
SOCKETS="/tmp/remoter-test-sockets"
PORT=2222

if [[ "$1" == "stop" ]]; then
  [[ -f "$SSHD/sshd.pid" ]] && kill "$(cat "$SSHD/sshd.pid")" 2>/dev/null || true
  rm -rf "$DIR" "$SOCKETS"
  echo "Остановлено, $DIR удалён."
  exit 0
fi

mkdir -p "$SSHD"

# Всё своё: и ключ хоста, и ключ клиента, и known_hosts. Пользовательский ~/.ssh не трогаем —
# ни ключей, ни config, ни known_hosts. Тесты получат нужные пути через REMOTER_TEST_SSH_OPTS.
[[ -f "$SSHD/hostkey" ]] || ssh-keygen -q -t ed25519 -f "$SSHD/hostkey" -N ''
[[ -f "$SSHD/id" ]] || ssh-keygen -q -t ed25519 -f "$SSHD/id" -N ''
cp "$SSHD/id.pub" "$SSHD/authorized_keys"
chmod 600 "$SSHD/hostkey" "$SSHD/id" "$SSHD/authorized_keys"

cat > "$SSHD/sshd_config" <<EOF
Port $PORT
ListenAddress 127.0.0.1
HostKey $SSHD/hostkey
PidFile $SSHD/sshd.pid
AuthorizedKeysFile $SSHD/authorized_keys
StrictModes no
UsePAM no
PasswordAuthentication no
PubkeyAuthentication yes
EOF

if ! nc -z 127.0.0.1 $PORT 2>/dev/null; then
  /usr/sbin/sshd -f "$SSHD/sshd_config" -E "$SSHD/sshd.log"
  sleep 1
fi

# Тестовый репозиторий: по одному файлу на каждый вид изменения, плюс пути с юникодом,
# пробелами и бинарник — ровно то, на чём ломается наивный разбор вывода git.
rm -rf "$REPO"
mkdir -p "$REPO/src/utils" "$REPO/docs"
cd "$REPO"
git init -q -b main
git config user.email test@remoter && git config user.name Test

printf 'def hello():\n    print("hi")\n    return 1\n' > src/main.py
printf 'export const a = 1;\nexport const b = 2;\n' > src/utils/helper.ts
printf 'old file\n' > src/old_name.py
printf 'to be deleted\n' > docs/gone.md
printf '# Docs\n' > docs/readme.md
printf 'имя с пробелом\n' > "docs/файл с пробелом.md"
# Заголовок PNG: содержит нулевые байты, значит определится как бинарник детерминированно.
# Со случайными байтами тест плавал: в 300 байтах /dev/urandom нулевой байт есть не всегда,
# а именно по нему (как и git) мы отличаем бинарник от текста.
printf '\211PNG\r\n\032\n\0\0\0\rIHDR\0\0\0\1\0\0\0\1' > docs/blob.bin
git add -A && git commit -qm init

printf 'def hello():\n    print("HELLO WORLD")\n    print("new line")\n    return 42\n' > src/main.py
printf 'export const a = 1;\nexport const b = 99;\nexport const c = 3;\n' > src/utils/helper.ts
git add src/utils/helper.ts
printf 'brand new\nsecond line\n' > src/brand_new.py
rm docs/gone.md
git mv src/old_name.py src/new_name.py
printf 'old file\nplus a change\n' > src/new_name.py

ssh-keyscan -p $PORT 127.0.0.1 > "$SSHD/known_hosts" 2>/dev/null

OPTS="-o UserKnownHostsFile=$SSHD/known_hosts -o IdentityFile=$SSHD/id -o IdentitiesOnly=yes"

mkdir -p "$DIR/home" "$DIR/claude/projects" "$SOCKETS"

cat <<EOF

Готово. sshd на 127.0.0.1:$PORT, репозиторий $REPO

Запуск тестов:
  REMOTER_TEST_REPO="$REPO" \\
  REMOTER_TEST_PORT=$PORT \\
  REMOTER_TEST_SSH_OPTS="$OPTS" \\
  REMOTER_WEB_ROOT="\$PWD/Web" \\
  REMOTER_HOME="$DIR/home" \\
  REMOTER_STORE="$DIR/home/workspaces.json" \\
  REMOTER_SOCKETS="$SOCKETS" \\
  CLAUDE_CONFIG_DIR="$DIR/claude" \\
  swift test

  REMOTER_HOME, REMOTER_STORE, REMOTER_SOCKETS и CLAUDE_CONFIG_DIR обязательны: без них тесты работали бы
  с настоящим ~/Remoter и настоящим списком проектов — а уборка после тестов их бы стирала. Ровно так
  однажды и пропали все проекты. (Забыть их теперь не смертельно: под тестами приложение само уводит
  эти пути в песочницу — но лучше задавать явно.)

  REMOTER_SOCKETS живёт в /tmp, а не рядом с репозиторием: у unix-сокета путь ограничен 104 байтами,
  а \$TMPDIR на маке — это /var/folders/… Сокет мультиплексора там не создаётся вовсе.

Убрать за собой:
  ./Tests/local-sshd.sh stop
EOF
