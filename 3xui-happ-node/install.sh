#!/usr/bin/env bash
set -Eeuo pipefail

TASK='3X-UI HAPP NODE INSTALL'
echo "#################### НАЧАЛО ВЫВОДА: ${TASK} ####################"

trap 'rc=$?; echo "[ОШИБКА] Установка прервана, код: $rc"; echo "#################### КОНЕЦ ВЫВОДА: ${TASK} ####################"; exit $rc' ERR

if [ "${EUID}" -ne 0 ]; then
  echo '[ОШИБКА] Запустите скрипт от root.'
  exit 1
fi

DOMAIN="${DOMAIN:-}"
EMAIL="${EMAIL:-}"
PANEL_PORT="${PANEL_PORT:-8000}"
XHTTP_PORT="${XHTTP_PORT:-18443}"
SUB_PORT="${SUB_PORT:-2096}"
CLIENT_NAME="${CLIENT_NAME:-main}"
INSTALL_RADIO_STUB="${INSTALL_RADIO_STUB:-no}"
XUI_VERSION=3.7.0
XUI_TAG="v${XUI_VERSION}"
XUI_COMMIT=f727d04f6522bb94a8fb52e8352fdcafb51c11e1
XUI_INSTALL_BLOB_SHA=4ff60a069362e618d5149abc4cbc5246629c93ea
RADIO_COMMIT=276908d5fed3faaadfb3a331ab7acad18824a9b9
RADIO_INDEX_BLOB_SHA=794845d7ac21dc76a96250fe0da9b5f71037507f
WEBROOT="${WEBROOT:-/var/www/mstream}"
CREDENTIALS_FILE="${CREDENTIALS_FILE:-/root/3xui-happ-node.credentials}"

rand_alnum() { tr -dc 'a-z0-9' </dev/urandom | head -c "${1:-16}"; }
rand_pass() { tr -dc 'A-Za-z0-9_!@#%+=' </dev/urandom | head -c "${1:-24}"; }

git_blob_sha() {
  local file="$1" size
  size="$(wc -c <"$file" | tr -d '[:space:]')"
  { printf 'blob %s\000' "$size"; cat "$file"; } | sha1sum | awk '{print $1}'
}
download_git_blob_checked() {
  local url="$1" expected="$2" dst="$3" actual
  rm -f "$dst"
  curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 60 --retry 2 "$url" -o "$dst"
  actual="$(git_blob_sha "$dst")"
  [ "$actual" = "$expected" ] || { echo "[ОШИБКА] git blob SHA не совпал: $actual != $expected ($url)" >&2; rm -f "$dst"; return 1; }
}
xui_release_sha256() {
  case "$(uname -m)" in
    x86_64|x64|amd64) printf '%s' '0f8dd7baef3458f6591574e24814f322cf7f5e1e27f0a594683745e50be84ec5' ;;
    i386|i486|i586|i686|x86) printf '%s' 'fe5db2bf3acbf97654dce9ef8f9d36d1ad97e3ec0c137b441208a4d39a5bad0f' ;;
    aarch64|arm64|armv8*) printf '%s' '3caf1db1e8b10bb1fa1324c945522690bcf01c533ee75b377268f1c01a3ce896' ;;
    armv7*|armv7) printf '%s' 'fc5cffd218cdb6da0c22c1ce9981ee91f269f657ea71463a1a1b5a9d930d7983' ;;
    armv6*|armv6) printf '%s' 'db285ff17c2a889b2ca09c63bdac82f61f41a6b637e749a89dfff07388b8384e' ;;
    armv5*|armv5) printf '%s' 'd198e607e530560ac7904fb408fed61447caa52bbf893b9ab5d8df6137924c67' ;;
    s390x) printf '%s' 'ff72abf4987b1929d273f79c3b591d6dd7c84fd0a59ead058d488aa238ab1a07' ;;
    *) return 1 ;;
  esac
}
xui_release_arch() {
  case "$(uname -m)" in
    x86_64|x64|amd64) printf '%s' amd64 ;;
    i386|i486|i586|i686|x86) printf '%s' 386 ;;
    aarch64|arm64|armv8*) printf '%s' arm64 ;;
    armv7*|armv7) printf '%s' armv7 ;;
    armv6*|armv6) printf '%s' armv6 ;;
    armv5*|armv5) printf '%s' armv5 ;;
    s390x) printf '%s' s390x ;;
    *) return 1 ;;
  esac
}

if [ -z "$DOMAIN" ]; then
  read -r -p 'DNS имя ноды (например stream.example.com): ' DOMAIN
fi
if [ -z "$EMAIL" ]; then
  read -r -p 'Email для Let\x27s Encrypt: ' EMAIL
fi

if [ -z "$DOMAIN" ] || [ -z "$EMAIL" ]; then
  echo '[ОШИБКА] DOMAIN и EMAIL обязательны.'
  exit 1
fi

PANEL_USER="${PANEL_USER:-admin_$(rand_alnum 8)}"
PANEL_PASS="${PANEL_PASS:-$(rand_pass 24)}"
PANEL_PATH="${PANEL_PATH:-/$(rand_alnum 24)/}"
SUB_PATH="${SUB_PATH:-/$(rand_alnum 16)/}"
XHTTP_PATH="${XHTTP_PATH:-/api/v1/$(rand_alnum 8)/events/}"
SUB_ID="${SUB_ID:-$(rand_alnum 24)}"

normalize_path() {
  local p="$1"
  [[ "$p" == /* ]] || p="/$p"
  [[ "$p" == */ ]] || p="$p/"
  printf '%s' "$p"
}
PANEL_PATH="$(normalize_path "$PANEL_PATH")"
SUB_PATH="$(normalize_path "$SUB_PATH")"
XHTTP_PATH="$(normalize_path "$XHTTP_PATH")"

install_packages() {
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y curl jq openssl ca-certificates certbot git caddy
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y epel-release || true
    dnf install -y curl jq openssl ca-certificates certbot git caddy
  elif command -v yum >/dev/null 2>&1; then
    yum install -y epel-release || true
    yum install -y curl jq openssl ca-certificates certbot git caddy
  else
    echo '[ОШИБКА] Не найден apt/dnf/yum.'
    exit 1
  fi
}

wait_http() {
  local url="$1"
  for _ in $(seq 1 30); do
    curl -fsS "$url" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

echo '[1/13] Предварительные проверки'
command -v getent >/dev/null 2>&1 || true
RESOLVED_IP="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1{print $1}')"
echo "Domain:   $DOMAIN"
echo "DNS IPv4: ${RESOLVED_IP:-не найден}"
[ -n "$RESOLVED_IP" ] || echo '[INFO] IPv4 DNS не найден локальным resolver; окончательную проверку сделает ACME challenge.'

if ss -ltn '( sport = :80 )' 2>/dev/null | grep -q LISTEN; then
  echo '[INFO] TCP/80 занят. Если это Caddy, временно остановлю его для Certbot.'
fi

install_packages

echo '[2/13] Получаю сертификат Let\x27s Encrypt'
if systemctl is-active --quiet caddy 2>/dev/null; then
  systemctl stop caddy
fi
certbot certonly --standalone --non-interactive --agree-tos --email "$EMAIL" -d "$DOMAIN"

LE_DIR="/etc/letsencrypt/live/${DOMAIN}"
[ -s "$LE_DIR/fullchain.pem" ] && [ -s "$LE_DIR/privkey.pem" ] || { echo '[ОШИБКА] Сертификат не получен.'; exit 1; }

mkdir -p "/etc/caddy/certs/${DOMAIN}"
install -o root -g caddy -m 0640 "$LE_DIR/fullchain.pem" "/etc/caddy/certs/${DOMAIN}/fullchain.pem"
install -o root -g caddy -m 0640 "$LE_DIR/privkey.pem" "/etc/caddy/certs/${DOMAIN}/privkey.pem"
chmod 0750 "/etc/caddy/certs/${DOMAIN}"

echo '[3/13] Устанавливаю 3x-ui из закреплённого commit/release'
export XUI_USERNAME="$PANEL_USER"
export XUI_PASSWORD="$PANEL_PASS"
export XUI_PANEL_PORT="$PANEL_PORT"
export XUI_WEB_BASE_PATH="$PANEL_PATH"
export XUI_SSL_MODE='none'
export XUI_NONINTERACTIVE=1

XUI_INSTALL=/tmp/3x-ui-install.sh
XUI_ARCH="$(xui_release_arch)" || { echo '[ОШИБКА] Неподдерживаемая архитектура.'; exit 1; }
XUI_RELEASE_SHA256="$(xui_release_sha256)" || { echo '[ОШИБКА] Нет закреплённого SHA-256 для этой архитектуры.'; exit 1; }
XUI_RELEASE="/usr/local/x-ui-linux-${XUI_ARCH}.tar.gz"
download_git_blob_checked "https://raw.githubusercontent.com/MHSanaei/3x-ui/${XUI_COMMIT}/install.sh" "$XUI_INSTALL_BLOB_SHA" "$XUI_INSTALL"
bash -n "$XUI_INSTALL"
sed -i "s#raw.githubusercontent.com/MHSanaei/3x-ui/main/#raw.githubusercontent.com/MHSanaei/3x-ui/${XUI_COMMIT}/#g" "$XUI_INSTALL"
sed -i 's#^[[:space:]]*curl -fLR --retry 5 --retry-delay 3 --connect-timeout 15 --speed-limit 1 --speed-time 300 -o ${xui_folder}-linux-$(arch).tar.gz .*#        test -s ${xui_folder}-linux-$(arch).tar.gz#' "$XUI_INSTALL"

curl -fL --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 300 \
  "https://github.com/MHSanaei/3x-ui/releases/download/${XUI_TAG}/x-ui-linux-${XUI_ARCH}.tar.gz" -o "$XUI_RELEASE"
printf '%s  %s\n' "$XUI_RELEASE_SHA256" "$XUI_RELEASE" | sha256sum -c -
bash "$XUI_INSTALL" "$XUI_TAG"
rm -f "$XUI_INSTALL" "$XUI_RELEASE"

[ -s /etc/x-ui/install-result.env ] || { echo '[ОШИБКА] 3x-ui не создал install-result.env.'; exit 1; }
. /etc/x-ui/install-result.env

PANEL_PORT="${XUI_PANEL_PORT:-$PANEL_PORT}"
PANEL_PATH="${XUI_WEB_BASE_PATH:-$PANEL_PATH}"
PANEL_PATH="$(normalize_path "$PANEL_PATH")"
API_TOKEN="${XUI_API_TOKEN:-}"
if [ -z "$API_TOKEN" ]; then
  API_TOKEN="$(/usr/local/x-ui/x-ui setting -getApiToken 2>/dev/null | tail -n1 | xargs)"
fi
[ -n "$API_TOKEN" ] || { echo '[ОШИБКА] Не удалось получить API token 3x-ui.'; exit 1; }

API="http://127.0.0.1:${PANEL_PORT}${PANEL_PATH%/}"
api_get() { curl -fsS -H "Authorization: Bearer ${API_TOKEN}" "${API}/${1#/}"; }
api_post() { curl -fsS -H "Authorization: Bearer ${API_TOKEN}" -H 'Content-Type: application/json' -X POST "${API}/${1#/}" -d "${2:-{}}"; }

/usr/local/x-ui/x-ui setting -listenIP "127.0.0.1" >/dev/null
systemctl restart x-ui
sleep 2
wait_http "http://127.0.0.1:${PANEL_PORT}${PANEL_PATH}" || { echo '[ОШИБКА] Панель не отвечает на loopback.'; exit 1; }

echo '[4/13] Настраиваю Happ subscription'
ROUTING_JSON="$(jq -cn '{Name:"RU DIRECT",GlobalProxy:"true",DirectSites:["geosite:category-ru"],DirectIp:["geoip:ru","geoip:private","10.0.0.0/8","100.64.0.0/10","127.0.0.0/8","169.254.0.0/16","172.16.0.0/12","192.168.0.0/16"],ProxySites:[],ProxyIp:[],BlockSites:[],BlockIp:[],DomainStrategy:"IPIfNonMatch",FakeDNS:"false"}')"
ROUTING_B64="$(printf '%s' "$ROUTING_JSON" | base64 -w0)"
HAPP_ROUTING="happ://routing/onadd/${ROUTING_B64}"

SETTINGS="$(api_post 'panel/api/setting/all' '{}')"
printf '%s' "$SETTINGS" | jq -e '.success == true' >/dev/null
OBJ="$(printf '%s' "$SETTINGS" | jq '.obj')"
OBJ="$(printf '%s' "$OBJ" | jq --arg domain "$DOMAIN" --arg listen '127.0.0.1' --arg path "$SUB_PATH" --arg routing "$HAPP_ROUTING" --argjson port "$SUB_PORT" '.subListen=$listen | .subPort=$port | .subPath=$path | .subDomain=$domain | .subEnable=true | .subEncrypt=true | .subEnableRouting=true | .subRoutingRules=$routing')"
RESP="$(api_post 'panel/api/setting/update' "$OBJ")"
printf '%s' "$RESP" | jq -e '.success == true' >/dev/null
systemctl restart x-ui
sleep 3

API="http://127.0.0.1:${PANEL_PORT}${PANEL_PATH%/}"

echo '[5/13] Создаю VLESS/XHTTP inbound'
XHTTP_BODY="$(jq -cn --arg path "$XHTTP_PATH" --arg domain "$DOMAIN" --argjson port "$XHTTP_PORT" '{up:0,down:0,total:0,remark:"VLESS XHTTP",enable:true,expiryTime:0,listen:"127.0.0.1",port:$port,protocol:"vless",settings:{clients:[],decryption:"none",fallbacks:[]},streamSettings:{network:"xhttp",security:"none",externalProxy:[{forceTls:"tls",dest:$domain,port:443,remark:"public",show:true}],xhttpSettings:{path:$path,host:$domain,mode:"packet-up",xPaddingBytes:"100-1000",xPaddingObfsMode:true,xPaddingKey:"_dc",xPaddingHeader:"X-Cache",xPaddingPlacement:"queryInHeader",xPaddingMethod:"tokenish",sessionIDPlacement:"cookie",sessionIDKey:"sid",sessionIDTable:"Base62",sessionIDLength:"16-32",seqPlacement:"cookie",seqKey:"seq",scMaxBufferedPosts:30,scStreamUpServerSecs:"20-80",noSSEHeader:false,serverMaxHeaderBytes:0,headers:{},enableXmux:false}},sniffing:{enabled:true,destOverride:["http","tls","quic","fakedns"],metadataOnly:false,routeOnly:true}}')"
RESP="$(api_post 'panel/api/inbounds/add' "$XHTTP_BODY")"
printf '%s' "$RESP" | jq -e '.success == true' >/dev/null

echo '[6/13] Создаю Hysteria2 inbound UDP/443'
HY2_BODY="$(jq -cn --arg cert "$LE_DIR/fullchain.pem" --arg key "$LE_DIR/privkey.pem" '{up:0,down:0,total:0,remark:"Hysteria2",enable:true,expiryTime:0,listen:"",port:443,protocol:"hysteria",settings:{version:2,clients:[]},streamSettings:{network:"hysteria",security:"tls",hysteriaSettings:{version:2,auth:"",udpIdleTimeout:60},tlsSettings:{serverName:"",minVersion:"1.2",maxVersion:"1.3",cipherSuites:"",rejectUnknownSni:false,disableSystemRoot:false,enableSessionResumption:false,certificates:[{certificateFile:$cert,keyFile:$key,ocspStapling:3600,oneTimeLoading:false,usage:"encipherment"}],alpn:["h3"]}},sniffing:{enabled:true,destOverride:["http","tls","quic","fakedns"],metadataOnly:false,routeOnly:true}}')"
RESP="$(api_post 'panel/api/inbounds/add' "$HY2_BODY")"
printf '%s' "$RESP" | jq -e '.success == true' >/dev/null

INBOUNDS="$(api_get 'panel/api/inbounds/list')"
XHTTP_ID="$(printf '%s' "$INBOUNDS" | jq -r '.obj[] | select(.remark=="VLESS XHTTP") | .id' | head -n1)"
HY2_ID="$(printf '%s' "$INBOUNDS" | jq -r '.obj[] | select(.remark=="Hysteria2") | .id' | head -n1)"
[ -n "$XHTTP_ID" ] && [ -n "$HY2_ID" ] || { echo '[ОШИБКА] Не найдены ID inbound-ов.'; exit 1; }

echo '[7/13] Создаю одного клиента на оба inbound-а'
CLIENT_BODY="$(jq -cn --arg email "$CLIENT_NAME" --arg subId "$SUB_ID" --argjson xhttp "$XHTTP_ID" --argjson hy2 "$HY2_ID" '{email:$email,enable:true,expiryTime:0,totalGB:0,limitIp:0,subId:$subId,inboundIds:[$xhttp,$hy2]}')"
RESP="$(api_post 'panel/api/clients/add' "$CLIENT_BODY")"
printf '%s' "$RESP" | jq -e '.success == true' >/dev/null
systemctl restart x-ui
sleep 3

echo '[8/13] Устанавливаю маскировочный сайт'
mkdir -p "$WEBROOT"
rm -f "$WEBROOT/admin.html"
if [ "$INSTALL_RADIO_STUB" = 'yes' ]; then
  TMP_SITE="$(mktemp)"
  download_git_blob_checked "https://raw.githubusercontent.com/Balbuto/radio-stub-site/${RADIO_COMMIT}/index.html" "$RADIO_INDEX_BLOB_SHA" "$TMP_SITE"
  install -o root -g root -m 0644 "$TMP_SITE" "$WEBROOT/index.html"
  rm -f "$TMP_SITE"
else
  cat >"$WEBROOT/index.html" <<'HTML'
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex,nofollow"><title>Media</title></head>
<body><main><h1>Media service</h1><p>Streaming endpoint is online.</p></main></body></html>
HTML
  chmod 0644 "$WEBROOT/index.html"
fi

echo '[9/13] Настраиваю Caddy'
[ -f /etc/caddy/Caddyfile ] && cp -a /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.bak.$(date +%Y%m%d-%H%M%S)" || true
cat >/etc/caddy/Caddyfile <<CADDY
{
    servers {
        protocols h1 h2
    }
    auto_https off
}

https://${DOMAIN}:443 {
    tls /etc/caddy/certs/${DOMAIN}/fullchain.pem /etc/caddy/certs/${DOMAIN}/privkey.pem {
        protocols tls1.2 tls1.3
    }

    @panel path ${PANEL_PATH}*
    reverse_proxy @panel https://127.0.0.1:${PANEL_PORT} {
        header_up Host ${DOMAIN}
        transport http {
            tls_server_name ${DOMAIN}
        }
    }

    @subscription path ${SUB_PATH}*
    reverse_proxy @subscription https://127.0.0.1:${SUB_PORT} {
        header_up Host ${DOMAIN}
        transport http {
            tls_server_name ${DOMAIN}
        }
    }

    @xhttp path ${XHTTP_PATH}*
    reverse_proxy @xhttp 127.0.0.1:${XHTTP_PORT} {
        flush_interval -1
    }

    root * ${WEBROOT}
    file_server
}

http://${DOMAIN}:80 {
    redir https://${DOMAIN}{uri} permanent
}
CADDY
caddy fmt --overwrite /etc/caddy/Caddyfile >/dev/null 2>&1 || true
caddy validate --config /etc/caddy/Caddyfile
systemctl enable --now caddy
systemctl reload caddy

echo '[10/13] Включаю TLS только на loopback-панели и проверяю приватность'
/usr/local/x-ui/x-ui setting -listenIP "127.0.0.1" >/dev/null
/usr/local/x-ui/x-ui setting -webCert "/etc/caddy/certs/${DOMAIN}/fullchain.pem" -webCertKey "/etc/caddy/certs/${DOMAIN}/privkey.pem"
systemctl restart x-ui
sleep 3
ss -ltn | awk -v p=":${PANEL_PORT}" '$4 ~ p {print $4}' | grep -Eq '^(127\.0\.0\.1|\[::1\]):' || {
  echo '[ОШИБКА] Панель 3x-ui слушает не только loopback.' >&2
  exit 1
}
curl -fsS --resolve "${DOMAIN}:${PANEL_PORT}:127.0.0.1" "https://${DOMAIN}:${PANEL_PORT}${PANEL_PATH}" >/dev/null || {
  echo '[ОШИБКА] TLS loopback-панели не отвечает с ожидаемым SNI.' >&2
  exit 1
}

echo '[11/13] Устанавливаю hook продления сертификата'
install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
cat >/etc/letsencrypt/renewal-hooks/deploy/3xui-happ-node.sh <<HOOK
#!/bin/sh
set -eu
DOMAIN='${DOMAIN}'
SRC="/etc/letsencrypt/live/\${DOMAIN}"
DST="/etc/caddy/certs/\${DOMAIN}"
install -d -o root -g caddy -m 0750 "\$DST"
install -o root -g caddy -m 0640 "\$SRC/fullchain.pem" "\$DST/fullchain.pem"
install -o root -g caddy -m 0640 "\$SRC/privkey.pem" "\$DST/privkey.pem"
caddy validate --config /etc/caddy/Caddyfile
systemctl reload caddy
systemctl restart x-ui
HOOK
chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/3xui-happ-node.sh

echo '[12/13] Проверяю сервисы и подписку'
systemctl is-active --quiet caddy
systemctl is-active --quiet x-ui
ss -lntup | grep -E ":(80|443|${PANEL_PORT}|${XHTTP_PORT}|${SUB_PORT})[[:space:]]" || true

SUB_URL="https://${DOMAIN}${SUB_PATH}${SUB_ID}"
curl -fsS -A 'Happ/1.0' --max-time 10 "$SUB_URL" -o /tmp/happ-sub.body
LINK_COUNT="$(python3 - <<'PY'
import base64
from pathlib import Path
raw=Path('/tmp/happ-sub.body').read_bytes().strip()
try: txt=base64.b64decode(raw).decode('utf-8','replace')
except Exception: txt=raw.decode('utf-8','replace')
print(sum(1 for x in txt.splitlines() if x.strip().startswith(('vless://','hysteria2://','hysteria://'))))
PY
)"
if [ "$LINK_COUNT" -lt 2 ]; then
  echo "[ОШИБКА] В подписке найдено подключений: $LINK_COUNT"
  exit 1
fi

echo '[13/13] ГОТОВО'
echo
printf 'Сайт:              https://%s/\n' "$DOMAIN"
printf '3x-ui панель:       https://%s%s\n' "$DOMAIN" "$PANEL_PATH"
printf 'Happ subscription:  %s\n' "$SUB_URL"
printf 'XHTTP:              %s:443 TCP, path %s\n' "$DOMAIN" "$XHTTP_PATH"
printf 'Hysteria2:          %s:443 UDP\n' "$DOMAIN"
install -d -o root -g root -m 0700 "$(dirname "$CREDENTIALS_FILE")"
umask 077
{
  printf 'PANEL_URL=%q\n' "https://${DOMAIN}${PANEL_PATH}"
  printf 'PANEL_USERNAME=%q\n' "$PANEL_USER"
  printf 'PANEL_PASSWORD=%q\n' "$PANEL_PASS"
  printf 'SUBSCRIPTION_URL=%q\n' "$SUB_URL"
} >"$CREDENTIALS_FILE"
chmod 0600 "$CREDENTIALS_FILE"
echo
printf 'Панельные реквизиты сохранены в root-only файл: %s (0600)\n' "$CREDENTIALS_FILE"
echo '[ВАЖНО] TCP/443: Caddy TLS 1.2/1.3; Hysteria2 использует QUIC/TLS 1.3.'
echo '[ВАЖНО] 3x-ui слушает только 127.0.0.1 и доступен снаружи через Caddy по скрытому PANEL_PATH.'

echo "#################### КОНЕЦ ВЫВОДА: ${TASK} ####################"
