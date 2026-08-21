# Remna Node Scripts

Один Bash-менеджер для установки и обслуживания Remnanode с Caddy, XHTTP через CDN, стрим-сайтом, VLESS RAW REALITY Vision и безопасной интеграцией Telemt + Telemt Panel.

Проект рассчитан на Ubuntu/Debian и требует root-доступ или `sudo`.

## Быстрый запуск — одна команда

Команда работает и на чистой ноде, где `/opt/remna-node-scripts` ещё не существует. Каталог создаётся до `curl`, файл сначала скачивается во временный путь, проверяется `bash -n` и только потом заменяет рабочий менеджер:

```bash
sudo bash -c 'set -e; install -d -m 0755 /opt/remna-node-scripts; tmp=$(mktemp); curl -fsSL https://raw.githubusercontent.com/evgmahov-blip/remna-node-scripts/main/install-caddy-node-reality-stream.sh -o "$tmp"; bash -n "$tmp"; install -m 0700 "$tmp" /opt/remna-node-scripts/install-caddy-node-reality-stream.sh; rm -f "$tmp"; exec /opt/remna-node-scripts/install-caddy-node-reality-stream.sh'
```

Так существующий рабочий менеджер не затирается при неудачном скачивании, а ошибка `curl: (23) Failure writing output to destination` из-за отсутствующего `/opt/remna-node-scripts` не возникает.

## Безопасное обновление менеджера из `main`

```bash
sudo bash -c 'set -e; install -d -m 0755 /opt/remna-node-scripts; tmp=$(mktemp); curl -fsSL https://raw.githubusercontent.com/evgmahov-blip/remna-node-scripts/main/install-caddy-node-reality-stream.sh -o "$tmp"; bash -n "$tmp"; install -m 0700 "$tmp" /opt/remna-node-scripts/install-caddy-node-reality-stream.sh; rm -f "$tmp"'
```

После обновления:

```bash
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh
```

## Что исправляет manager поверх core

Менеджер всегда получает актуальный `install-caddy-node-reality-stream-core.sh` из `main`. Если GitHub временно недоступен, допускается только уже сохранённый локальный core, который проходит `bash -n`.

### SECRET_KEY

Канонический формат установки теперь такой:

```yaml
services:
  remnanode:
    env_file:
      - .env
    environment:
      NODE_PORT: "2222"
```

Сам ключ хранится только в:

```text
/opt/remnanode/.env
```

с правами `0600`:

```text
SECRET_KEY=...
```

Менеджер автоматически мигрирует старый inline `SECRET_KEY` из `docker-compose.yml` в `.env`, не печатая значение. Строка `SECRET_KEY: "${SECRET_KEY}"` больше не используется как основной способ передачи секрета: именно на этой схеме ранее можно было получить пустой `SECRET_KEY` внутри контейнера.

Перед пересозданием контейнера проверяется, что значение в `.env` реально непустое. После запуска выполняется проверка, что `SECRET_KEY` действительно присутствует внутри `remnanode`, без вывода самого значения.

### NET_ADMIN

Менеджер обеспечивает:

```yaml
cap_add:
  - NET_ADMIN
```

и проверяет фактически применённый `HostConfig.CapAdd` через `docker inspect`. Если compose уже исправлен, но контейнер был создан раньше без capability, пересоздаётся только `remnanode`.

Нормальный лог новой Node содержит:

```text
[OK] CAP_NET_ADMIN is available
```

### Автоматический handoff TCP/443: Caddy → REALITY

Главная исправленная гонка выглядела так:

1. До назначения Config Profile сайт должен оставаться доступным через публичный Caddy на `:443`.
2. Панель позже присылает runtime-конфиг.
3. Xray/`rw-core` пытается занять `0.0.0.0:443` и получает `address already in use`, потому что Caddy всё ещё на `443`.
4. Старый сценарий требовал вручную копировать `/etc/caddy/Caddyfile.reality` и перезапускать Caddy.

Теперь менеджер устанавливает systemd watcher:

```text
remna-reality-handoff.timer
remna-reality-handoff.service
```

Watcher проверяет свежие логи Remnanode. При подтверждённой ошибке:

```text
failed to listen TCP on 443 ... address already in use
```

он автоматически:

```text
Caddy *:443
   ↓
Caddy 127.0.0.1:8443
   ↓
ожидание повторной попытки панели
   ↓
rw-core *:443
```

Если `rw-core` не появляется за таймаут, публичный Caddy автоматически возвращается на `443`, чтобы сайт не оставался недоступным.

Финальная рабочая топология:

```text
*:2222              rw-node
*:443               rw-core / REALITY
127.0.0.1:7443      rw-core / XHTTP
127.0.0.1:8443      Caddy
```

## Важная совместимость Remnawave Backend ↔ Node

Актуальная `remnawave/node:latest` использует TLS 1.3 и специальный вычисляемый SNI для mTLS-соединения панели с Node.

Старая панель на:

```text
remnawave/backend:2
Remnawave Backend v2.8.x
```

может подключаться к Node с обычным SNI домена ноды (`ger.example.com`). Новая Node такой SNI отвергает ещё до TLS ServerHello. Типичный симптом в панели:

```text
Client network socket disconnected before secure TLS connection was established
```

При этом на Node:

```text
:2222 слушает
SECRET_KEY OK
NET_ADMIN OK
Xray down (not started yet)
runtime config = 0
```

а `tcpdump` показывает TCP handshake, ClientHello от панели и немедленное закрытие соединения со стороны Node.

Для новой Node нужна панель Backend 3.x. Если compose панели закреплён так:

```yaml
image: remnawave/backend:2
```

обычный `docker compose pull` обновит только ветку 2.x. Для перехода на 3.x сначала обязательно сделайте backup compose и PostgreSQL, затем меняйте image на `remnawave/backend:3` согласно официальной инструкции миграции.

При переходе 2.x → 3.x переменная:

```text
JWT_AUTH_SECRET
```

переименована в:

```text
APP_SECRET
```

**Значение остаётся тем же.** Если этого не сделать, Backend 3.x будет перезапускаться с ошибкой:

```text
APP_SECRET: Invalid input: expected string, received undefined
```

Не генерируйте новый `APP_SECRET` вместо старого `JWT_AUTH_SECRET`, если задача — обычное обновление существующей панели.

## Источники стрим-сайта

Если `STREAM_SITE_URL` не задан вручную, источники проверяются по порядку:

1. `https://rustream.remna.space`
2. `https://est.remna.2rdp.ru`
3. `https://nl.remna.2rdp.ru`

Используется первый доступный источник с валидной HTML-страницей. Если все источники недоступны, существующий `/var/www/mstream` не должен затираться.

## Диагностика

```bash
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh diagnose
```

Диагностика проверяет:

- Caddy и реальный HTTP-ответ сайта с правильным SNI через `curl --resolve`;
- Node API `2222`;
- XHTTP `127.0.0.1:7443`;
- `rw-core` на внешнем `443`;
- фактически применённый `NET_ADMIN`;
- безопасное хранение и реальную передачу `SECRET_KEY`;
- состояние s6-сервиса Xray;
- runtime-конфиг Xray;
- конфликт `Xray :443` ↔ `Caddy :443`;
- состояние auto-handoff;
- CDN только после появления локального XHTTP backend.

Если Xray показывает `down (not started yet)` и runtime-конфигов нет, отсутствие `7443` **не трактуется автоматически как закрытый локальный порт 2222**.

Если в этот момент панель сообщает TLS disconnect, диагностика подсказывает проверить major-версию Backend.

## Telemt и Telemt Panel

Используются проекты:

- `telemt/telemt` — MTProxy;
- `amirotin/telemt_panel` — веб-панель управления Telemt.

Существующие `telemt1.service`, `telemt2.service`, `telemt3.service` или `telemt.service` считаются внешней существующей установкой и не должны переустанавливаться/удаляться без явного действия пользователя.

Типовой набор:

```text
telemt1.service -> внешний порт 5222 -> API 127.0.0.1:9091
telemt2.service -> внешний порт 5223 -> API 127.0.0.1:9092
telemt3.service -> внешний порт 8530 -> API 127.0.0.1:9093
```

Telemt Panel:

```text
127.0.0.1:8080
base_path = "/telemt"
```

Внешний URL при redirect `18443 -> 443`:

```text
https://DOMAIN:18443/telemt/login
```

Маршрут `/telemt*` менеджер синхронизирует не только в активный `/etc/caddy/Caddyfile`, но также в `.public` и `.reality`, чтобы он не исчезал после переключения Caddy.

## Меню

1. Полная установка.
2. Переустановка с нуля.
3. Только фронт Caddy.
4. Генерация XHTTP-пути.
5. Изменение XHTTP-пути.
6. Обновление стрим-сайта.
7. Сводка настроек.
8. Диагностика.
9. Статус сервисов.
10. Подготовить REALITY.
11. Включить REALITY.
12. Отключить REALITY.
13. Файлы REALITY без вывода ключей.
14. Repair текущей ноды.
15. Подключить Telemt + Panel.
16. Статус Telemt + Panel.
17. Убрать интеграцию Telemt Panel.
18. Clean Remnanode/Caddy.

## Команды без меню

```bash
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh install
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh front-only
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh reinstall
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh diagnose
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh repair
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh reality-prepare
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh reality-enable
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh reality-disable
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh telemt-install
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh telemt-status
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh telemt-remove
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh clean
```

## Неинтерактивная установка

```bash
EMAIL=you@example.com \
DOMAIN=node.example.com \
SECRET_KEY='ваш_secret_key' \
sudo -E /opt/remna-node-scripts/install-caddy-node-reality-stream.sh --auto
```

Не публикуйте `SECRET_KEY`, REALITY private key, Telemt secrets, JWT/APP secrets, токены и другие чувствительные значения.

## Порты

| Порт | Назначение |
|---|---|
| `80/tcp` | HTTP / ACME для Caddy |
| `443/tcp` | публичный Caddy до профиля; после handoff — REALITY/rw-core |
| `18443/tcp` | HTTPS-доступ к Telemt Panel через redirect на `443` |
| `7443/tcp` | XHTTP backend, только `127.0.0.1` |
| `8443/tcp` | Caddy за REALITY, только `127.0.0.1` |
| `2222/tcp` | Remnanode mTLS API для панели |
| `8080/tcp` | Telemt Panel, только `127.0.0.1` |
| `9091+` | Telemt API, только `127.0.0.1` |
| `5222/5223/8530` | примеры внешних портов Telemt |

## Основные файлы

```text
/etc/caddy/Caddyfile
/etc/caddy/Caddyfile.public
/etc/caddy/Caddyfile.reality
/etc/systemd/system/remna-reality-handoff.service
/etc/systemd/system/remna-reality-handoff.timer
/etc/telemt/
/etc/telemt-panel/config.toml
/opt/remnanode/.env
/opt/remnanode/docker-compose.yml
/opt/remnanode/reality/
/var/www/mstream/
/opt/remna-node-scripts/install-caddy-node-reality-stream.sh
/opt/remna-node-scripts/install-caddy-node-reality-stream-core.sh
/opt/remna-node-scripts/telemt-manager.sh
```

## Важно

Перед изменением XHTTP-пути убедитесь, что одинаковое значение установлено в Config Profile, CDN Rewrite и хосте Remnawave. Несовпадение пути остановит XHTTP-трафик.
