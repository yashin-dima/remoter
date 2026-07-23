#!/bin/sh
# Хелпер для ssh: спрашивает пароль/парольную фразу нативным диалогом macOS.
#
# Зачем: мастер-соединение Remoter живёт фоновым процессом без терминала, спросить в консоли
# ему негде. OpenSSH в такой ситуации зовёт SSH_ASKPASS — то есть этот скрипт. Текст запроса
# приходит первым аргументом.
#
# Аргумент передаём в osascript через argv, а не подставляем в текст скрипта: иначе кавычки
# в тексте запроса ломали бы AppleScript (а то и выполняли бы что-нибудь лишнее).

prompt="$1"
[ -n "$prompt" ] || prompt="Введите пароль"

case "$prompt" in
  # Первое подключение к серверу: ssh хочет подтверждения отпечатка ключа.
  # Это не пароль — тут нужны кнопки «да/нет», а не поле ввода.
  *"(yes/no"*|*"yes/no/[fingerprint]"*|*"Are you sure"*)
    osascript - "$prompt" <<'APPLESCRIPT'
      on run argv
        set msg to item 1 of argv
        try
          display dialog msg buttons {"Отмена", "Подключиться"} default button 2 ¬
            with title "Remoter" with icon caution
          if button returned of result is "Подключиться" then
            return "yes"
          else
            error number -128
          end if
        on error number -128
          return "no"
        end try
      end run
APPLESCRIPT
    ;;

  *)
    # Сохранённый пароль (из Keychain; в окружение его кладёт SSHConnection) — но ТОЛЬКО на запрос
    # пароля. Парольная фраза ключа («Enter passphrase for key …») — другой секрет: подсунув ей
    # пароль сервера, мы сожгли бы попытку входа и получили отказ на ровном месте. Поэтому смотрим,
    # о чём именно спрашивают, а не отвечаем на всё подряд.
    #
    # Пароль приходит окружением, а не аргументом: argv виден в `ps` любому процессу в системе.
    #
    # Отдаём его ОДИН раз за подключение — про это отметка REMOTER_PASSWORD_USED. Пароль на сервере
    # могли сменить, а ssh спрашивает до трёх раз: без отметки мы трижды скормили бы ему один и тот
    # же устаревший пароль, человек увидел бы «отказано» и не понял, почему приложение не пускает.
    # А так первая попытка идёт сохранённым, а дальше ssh спросит — и новый пароль введут руками.
    case "$prompt" in
      *[Pp]assword*|*[Пп]ароль*)
        if [ -n "$REMOTER_PASSWORD" ] && [ -n "$REMOTER_PASSWORD_USED" ] &&
           [ ! -e "$REMOTER_PASSWORD_USED" ]; then
          : > "$REMOTER_PASSWORD_USED"
          printf '%s\n' "$REMOTER_PASSWORD"
          exit 0
        fi
        ;;
    esac

    osascript - "$prompt" <<'APPLESCRIPT'
      on run argv
        set msg to item 1 of argv
        display dialog msg default answer "" with hidden answer ¬
          buttons {"Отмена", "OK"} default button 2 ¬
          with title "Remoter" with icon note
        return text returned of result
      end run
APPLESCRIPT
    ;;
esac

# Отмена в диалоге → osascript вернёт ненулевой код → ssh корректно прервёт подключение.
exit $?
