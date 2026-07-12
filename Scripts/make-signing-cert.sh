#!/bin/zsh
# Создаёт самоподписанный сертификат "Remoter" в связке ключей login. Запусти ОДИН раз.
#
# Зачем: при adhoc-подписи хеш кода меняется на каждой сборке, macOS видит «другое приложение»
# и сбрасывает всё, что было выдано прошлому — доступ к связке ключей, разрешения, исключения.
# Сертификат держит подпись стабильной, и после пересборки ничего заново выдавать не нужно.
set -e

NAME="Remoter"

# -v: без него в списке есть и просроченные/отозванные сертификаты — «уже есть» было бы враньём.
if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
  echo "Сертификат \"$NAME\" уже есть. Ничего делать не нужно."
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.conf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions    = ext
prompt             = no
[ dn ]
CN = $NAME
[ ext ]
keyUsage         = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.conf"

# Пароль на .p12 обязателен и должен быть непустым, иначе `security import` ругается
# «MAC verification failed». Он временный — нужен только чтобы перенести ключ в связку.
P12PASS="remoter"
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/cert.p12" -passout "pass:$P12PASS" 2>/dev/null \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
       -out "$TMP/cert.p12" -passout "pass:$P12PASS"

# Только -T /usr/bin/codesign, без -A: с -A приватный ключ подписи был бы доступен
# ЛЮБОМУ приложению без запроса — доверяем ровно тому, кому ключ нужен.
security import "$TMP/cert.p12" -k ~/Library/Keychains/login.keychain-db \
  -P "$P12PASS" -T /usr/bin/codesign

# Доверие не обязательно — codesign подписывает и недоверенным сертификатом, а для
# стабильности важна сама привязка к нему. Поэтому не падаем, если шаг не прошёл.
security add-trusted-cert -r trustAsRoot \
  -p codeSign -k ~/Library/Keychains/login.keychain-db "$TMP/cert.pem" 2>/dev/null || true

echo
echo "Готово. Теперь ./build.sh будет подписывать сертификатом \"$NAME\"."
