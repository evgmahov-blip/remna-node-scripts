# Remna Node Scripts

Установка и обслуживание **Remnawave Node** с рабочей схемой:

```text
VLESS + XHTTP + REALITY
0.0.0.0:443
        |
      rw-core
        |
REALITY xver=1
target=/dev/shm/nginx.sock
        |
 remna-reality-fallback
     (HAProxy)
        |
127.0.0.1:8443
        |
      Caddy
        |
 маскировочный сайт
```

Главный принцип: **один XHTTP+REALITY inbound на TCP/443**.

Отдельного XHTTP inbound на внутреннем порту здесь нет.

---

## Что создаёт скрипт

После установки/подготовки профиля получается Config Profile Remnawave примерно такого вида:

```json
{
  "inbounds": [
    {
      "tag": "PL-node1-xHTTP",
      "port": 443,
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "xhttpSettings": {
          "mode": "auto",
          "path": "/api/example/example.ts",
          "extra": {
            "xmux": {
              "cMaxReuseTimes": 12,
              "maxConcurrency": 1
            },
            "seqKey": "visitor_id",
            "xPaddingKey": "_r",
            "seqPlacement": "cookie",
            "sessionIDKey": "auth_session",
            "xPaddingBytes": "270-1096",
            "sessionIDTable": "Base62",
            "xPaddingHeader": "X-Request-Token",
            "xPaddingMethod": "tokenish",
            "sessionIDLength": "16-32",
            "xPaddingObfsMode": true,
            "xPaddingPlacement": "queryInHeader",
            "sessionIDPlacement": "cookie"
          }
        },
        "realitySettings": {
          "show": false,
          "xver": 1,
          "target": "/dev/shm/nginx.sock",
          "shortIds": ["GENERATED"],
          "privateKey": "GENERATED",
          "serverNames": ["node.example.com"],
          "minClientVer": "1"
        }
      }
    }
  ]
}
```

Домен, XHTTP path, private key и short ID генерируются/подставляются автоматически.

---

## Требования

- Debian / Ubuntu;
- root или `sudo`;
- домен ноды с A-записью на сервер;
- TCP/80 и TCP/443;
- `SECRET_KEY` Remnawave Node;
- IP сервера панели Remnawave для ограничения TCP/2222.

Скрипт при необходимости устанавливает Docker, Caddy и HAProxy.

---

## Установка

Закреплённый installer snapshot:

```bash
curl -fsSL --proto '=https' --tlsv1.2 \
  https://raw.githubusercontent.com/evgmahov-blip/remna-node-scripts/152a2c1898b2404fe1843788a1c7cdfc84b27eed/install.sh \
  -o /tmp/remna-install.sh

sudo bash /tmp/remna-install.sh
```

Установщик запросит:

1. email для Let's Encrypt;
2. домен ноды;
3. `SECRET_KEY`;
4. XHTTP path — Enter создаёт случайный;
5. IP панели для защиты TCP/2222.

Во время интерактивного ввода `0` / `назад` отменяет текущее действие и возвращает в manager.

---

## Главное меню

После установки:

```bash
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh
```

Актуальное меню:

```text
[1]  Полная установка
[2]  Переустановка с нуля
[3]  Только фронт Caddy
[4]  Сгенерировать XHTTP-путь
[5]  Изменить XHTTP-путь
[6]  Обновить стрим-сайт
[7]  Сводка настроек
[8]  Диагностика
[9]  Статус сервисов
[10] Подготовить профиль XHTTP+REALITY
[11] Переключить :443 на XHTTP+REALITY
[12] Вернуть Caddy на :443
[13] Профиль для копипасты (XHTTP + REALITY :443)
[14] Repair Caddy / XHTTP / REALITY
[15] Clean Remnanode/Caddy
[16] Защита ноды (RKN/TSPU/GOV/GeoIP/Allow/Deny)
[17] Закрыть TCP/2222 только для IP панели
[18] Полный self-test инфраструктуры
[19] РКН защита (TSPU/GOV)
[0]  Выход
```

---

## Config Profile для копипасты

Сначала подготовить профиль:

```bash
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh reality-prepare
```

Потом вывести готовый JSON прямо в терминал:

```bash
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh config-profile
```

Или выбрать **пункт 13**.

Вывод — это полный:

```json
{
  "inbounds": [
    ...
  ]
}
```

Его можно целиком копировать в Remnawave Config Profile.

Файл на диске:

```text
/opt/remnanode/reality/inbounds-ready.json
```

Внутренний объект:

```text
/opt/remnanode/reality/xhttp-reality-inbound.json
```

**Важно:** JSON содержит REALITY private key. Не публикуйте его.

---

## Как работает self-steal

В Config Profile используется:

```text
"target": "/dev/shm/nginx.sock"
"xver": 1
```

Для этого скрипт создаёт host socket:

```text
/dev/shm/remna-reality/nginx.sock
```

Каталог `/dev/shm/remna-reality` bind-mount'ится в контейнер Remnanode как `/dev/shm`, поэтому для rw-core тот же socket виден как:

```text
/dev/shm/nginx.sock
```

Отдельный systemd unit:

```text
remna-reality-fallback.service
```

запускает HAProxy. Он принимает PROXY protocol от REALITY `xver=1` на Unix socket и передаёт TLS в Caddy:

```text
127.0.0.1:8443
```

До активации профиля Caddy держит публичный TCP/443. После того как rw-core занимает TCP/443, topology guard переводит Caddy на локальный 8443.

---

## РКН защита

В главное меню вынесен отдельный пункт:

```text
[19] РКН защита (TSPU/GOV)
```

Подменю:

```text
[1] Включить / установить RKN-защиту
[2] Обновить TSPU/GOV списки сейчас
[3] Статус RKN-защиты
[4] Выключить TSPU/GOV фильтрацию
[0] Назад
```

CLI:

```bash
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh rkn
```

По умолчанию TSPU/GOV применяются к TCP/443. Выключение RKN-фильтрации не удаляет отдельную защиту Node API TCP/2222.

---

## Защита Node API TCP/2222

Порт 2222 должен быть разрешён только серверу панели.

Задать IP панели:

```bash
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh panel-set 203.0.113.10
```

Полное меню firewall:

```bash
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh protection
```

Подробности: [PROTECTION.md](./PROTECTION.md).

---

## Диагностика

Статус:

```bash
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh status
```

Read-only диагностика:

```bash
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh diagnose
```

Полный self-test:

```bash
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh selftest
```

Repair трафикового тракта:

```bash
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh repair
```

Repair и self-test — разные механизмы:

| Команда | Назначение |
|---|---|
| `repair` | Caddy, сайт, профиль XHTTP+REALITY, TCP/443, self-steal |
| `selftest` | compose, SECRET_KEY, NET_ADMIN, firewall, TCP/2222, systemd, topology |

---

## Порты и endpoints

| Endpoint | Назначение |
|---|---|
| TCP/80 | ACME / HTTP |
| TCP/443 | единый rw-core XHTTP+REALITY inbound после активации |
| TCP/2222 | Remnawave Node API, только IP панели |
| 127.0.0.1:8443 | Caddy fallback за REALITY |
| /dev/shm/nginx.sock | REALITY self-steal target внутри Remnanode |

**Отдельного XHTTP backend-порта в этой схеме нет.**

---

## Основные файлы

| Файл | Назначение |
|---|---|
| `install.sh` | установка |
| `clean-install.sh` | clean reinstall |
| `full-clean-reinstall.sh` | проверяемый launcher |
| `install-caddy-node-reality-stream.sh` | основной manager |
| `install-caddy-node-reality-stream-core.sh` | установка и генерация профиля |
| `protection-manager.sh` | TCP/2222, RKN/TSPU/GOV, GeoIP, allow/deny |
| `caddy-resilient-start.sh` | Caddy topology guard |

---

## Supply-chain

Launcher-цепочка использует immutable commit SHA + Git blob SHA:

```text
install.sh / clean-install.sh
  -> pinned full-clean-reinstall.sh
      -> pinned manager
          -> pinned core / protection / Caddy guard
```

CI дополнительно проверяет:

- Bash syntax;
- shellcheck;
- pin-chain;
- отсутствие старой схемы с отдельным XHTTP backend-портом;
- обязательный XHTTP+REALITY профиль на `0.0.0.0:443`;
- `mode:auto`;
- `target=/dev/shm/nginx.sock`;
- наличие RKN-пункта в основном меню;
- защиту manager от перезаписи core.

---

## Что репозиторий не устанавливает

- Remnawave Panel;
- 3x-ui;
- Telemt.

Также скрипт не делает глобальный `ufw reset` и не должен трогать чужие Docker-сервисы.
