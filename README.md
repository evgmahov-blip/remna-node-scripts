# Remna Node Scripts

Главный installer этого репозитория — **REMNANODE NEXT**.

NEXT восстановлен из source snapshot реально работающей ноды и снова является основной цепочкой установки. Старый Caddy-based manager оставлен только для обслуживания legacy-нод и **не вызывается** из `install.sh`, `clean-install.sh` или `full-clean-reinstall.sh`.

## Что умеет NEXT

- Remnawave Node + `remnawave-nginx`;
- SelfSteal через общий `/dev/shm/nginx.sock`;
- VLESS + REALITY + XHTTP на TCP/443;
- VLESS + REALITY + RAW на TCP/443;
- Hysteria2 + TLS на UDP/443;
- комбинированный профиль **XHTTP + Hysteria2**: TCP/443 + UDP/443;
- генерация Config Profile и Host для Remnawave;
- стабильная per-node XHTTP signature;
- RKN SAFE scanner guard с rollback и self-heal;
- runtime repair для Hysteria cert mount / RKN;
- маскировочный SelfSteal-сайт;
- безопасный backup / clean / reinstall без глобального `ufw reset`.

## Быстрая установка

Новая нода:

```bash
curl -fsSL --proto '=https' --tlsv1.2 \
  https://raw.githubusercontent.com/evgmahov-blip/remna-node-scripts/4cc22efdafeee9dc37d5adf6df38a4fc63f64fd9/install.sh \
  -o /tmp/remna-install.sh

sudo bash /tmp/remna-install.sh
```

Safe reinstall:

```bash
curl -fsSL --proto '=https' --tlsv1.2 \
  https://raw.githubusercontent.com/evgmahov-blip/remna-node-scripts/30cfc346a3e158eeeb45ad208fd2b56e85d2e3a1/clean-install.sh \
  -o /tmp/remna-clean-install.sh

sudo bash /tmp/remna-clean-install.sh
```

Обе команды используют immutable commit SHA. Следующий launcher проверяется по Git blob SHA; recovered NEXT source bundle — по immutable commit + Git blob SHA, а каждый входящий в него скрипт дополнительно проверяется по SHA256.

## Главное меню

После первой синхронизации:

```bash
sudo remnanode-next
```

Меню:

```text
REMNANODE NEXT — main

 [1]  Установка / продолжить настройку NEXT
 [2]  Транспорт / профили (XHTTP / RAW / Hysteria2 / combined)
 [3]  Профили для копипасты в Remnawave
 [4]  SelfSteal / маскировочный сайт
 [5]  XHTTP signature
 [6]  РКН защита — SAFE scanner guard
 [7]  Runtime repair / guards
 [8]  Базовое управление Remnanode
 [9]  Статус
 [10] Safe clean текущей ноды
 [11] Safe reinstall
 [0]  Выход
```

RKN снова находится непосредственно в основном меню NEXT.

## Транспортные профили

Пункт 2 использует восстановленный `remnawave-transport-manager.sh`:

```text
1) VLESS + REALITY + XHTTP (основной)
2) VLESS + REALITY + RAW (fallback)
3) Hysteria2 + TLS (UDP)
4) XHTTP + Hysteria2 одновременно (TCP/443 + UDP/443)
```

Профили сохраняются в:

```text
/opt/remnanode/remnawave-profiles/xhttp-reality.json
/opt/remnanode/remnawave-profiles/raw-reality.json
/opt/remnanode/remnawave-profiles/hysteria2-tls.json
/opt/remnanode/remnawave-profiles/xhttp-hysteria2.json
```

Пункт 3 основного меню печатает выбранный **полный JSON прямо в терминал для копипасты в Remnawave**.

JSON XHTTP/REALITY содержит private key — не публикуйте его.

### Hysteria2: совместимость с рабочим Xray/Remnawave профилем

Эталонный recovered bundle оставлен **байт-в-байт неизменным**. Исправленный transport-manager хранится отдельно в репозитории как immutable overlay:

```text
next-installer/remnawave-transport-manager.sh
```

NEXT launcher проверяет overlay по commit SHA + Git blob SHA и только после этого ставит его поверх recovered transport-manager.

Исправленный Hysteria2 server profile:

- `protocol: hysteria`;
- `settings.version: 2`;
- `settings.clients: []` — Remnawave сам добавляет каждому пользователю `auth = UUID`;
- `network: hysteria`;
- `security: tls`;
- ALPN `h3`;
- `finalmask.quicParams.congestion: brutal`;
- `hysteriaSettings.version: 2`;
- `hysteriaSettings.auth` на сервере **не хардкодится**;
- перед сохранением профиль проходит отдельный shape-check и затем штатный `rw-core/Xray run -test`.

Ключевая часть рабочего клиентского outbound, который должен получить пользователь из Remnawave:

```json
{
  "protocol": "hysteria",
  "settings": {
    "address": "<node-domain>",
    "port": 443,
    "version": 2
  },
  "streamSettings": {
    "finalmask": {
      "quicParams": {
        "congestion": "brutal"
      }
    },
    "hysteriaSettings": {
      "auth": "<UUID-пользователя>",
      "version": 2
    },
    "network": "hysteria",
    "security": "tls",
    "tlsSettings": {
      "alpn": ["h3"],
      "serverName": "<node-domain>"
    }
  }
}
```

Поля DNS, SOCKS/HTTP local inbounds, metrics, routing и mux в полном клиентском JSON относятся к шаблону клиента и **не являются частью server Config Profile**.

`masquerade` остаётся серверной настройкой и не обязан присутствовать в клиентском JSON.

## Рабочая архитектура

```text
                       rw-core

TCP/443  ───────► XHTTP + REALITY
                       │
                       │ target=/dev/shm/nginx.sock
                       ▼
                 remnawave-nginx
                 SelfSteal / mask

UDP/443  ───────► Hysteria2 + TLS/QUIC
```

Remnanode и Nginx используют общий `/dev/shm`. Это та схема, которая была снята с рабочей NEXT-ноды.

**Отдельный Caddy → 127.0.0.1:7443 pipeline не является основной NEXT-архитектурой.**

## RKN SAFE

Пункт 6:

```text
RKN WATCHER — SAFE SCANNER MODE

1) Установить / обновить SAFE scanner protection
2) Активировать / пере-применить guard с rollback 120 сек
3) Обновить scanner lists сейчас
4) Статус
5) ADVANCED upstream menu
6) Полностью удалить RKN Watcher
0) Назад
```

SAFE guard защищает TCP/80, TCP/443 и UDP/443 от известных scanner IP. При активации используется rollback и last-good проверка, чтобы не заменить рабочий набор повреждённым.

## Safe clean / reinstall

Top-level NEXT manager **не вызывает legacy uninstall**, потому что старый uninstall умеет делать глобальный `ufw reset`.

Перед clean/reinstall сохраняются важные настройки, профили, сертификаты и секреты в root-only backup:

```text
/root/remnanode-next-backup-YYYYMMDD-HHMMSS.tar.gz
```

Удаляются только известные компоненты текущей Remnanode/NEXT установки. Docker как пакет, SSH, DNS, default route и чужие контейнеры не удаляются.

## Восстановленный source snapshot

Source NEXT хранится внутри этого репозитория:

```text
vendor/remna-next-source.tar.gz
```

Манифест и контрольные суммы:

```text
NEXT_SOURCE_MANIFEST.md
```

В bundle входят:

```text
next-installer/setup_node-legacy.sh
next-installer/remnawave-transport-manager.sh
next-installer/selfsteal-site-manager.sh
next-installer/rkn-watcher-manager.sh
next-installer/next-runtime-guards.sh
next-installer/xhttp-signature-manager.sh
```

В recovered bundle байт-в-байт сохранены также `docker-compose.yml` и `nginx.conf` с рабочей ноды как эталон архитектуры. Installer их из bundle **не устанавливает**: для runtime используются штатные NEXT-функции. `.env`, сертификаты и приватные ключи в bundle отсутствуют.

### Известный хвост recovered snapshot

В восстановленном SelfSteal manager режим STREAM всё ещё содержит pinned URL старого `setup-remna-node`, который сейчас недоступен через GitHub. Свежая установка по умолчанию использует RANDOM/template SelfSteal и от этого URL не зависит. STREAM нужно отдельно перевендорить из рабочей копии сайта; это не причина возвращать legacy Caddy-manager в основную цепочку.

## Legacy Caddy manager

Эти файлы сохранены только для старых нод:

```text
install-caddy-node-reality-stream.sh
install-caddy-node-reality-stream-core.sh
caddy-resilient-start.sh
protection-manager.sh
```

Они **не являются main installer**.

## История восстановления

Последний корректный main до архитектурной ошибки: `cf8c8f5910b1bbd56364b99a457f2b999c743119`.

В `42d7d662c1f11b4705c8bfba3c74839ce98d669a` launcher был ошибочно переключён с NEXT на legacy Caddy-manager. Текущая ветка восстанавливает исходную роль NEXT, но хранит recovered source внутри этого репозитория, чтобы больше не зависеть от исчезнувшего внешнего `setup-remna-node`.
