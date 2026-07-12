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
