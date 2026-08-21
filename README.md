# Remna Node Scripts

Один Bash-менеджер для установки и обслуживания Remnanode с Caddy, XHTTP через CDN, стрим-сайтом, VLESS RAW REALITY Vision и безопасной интеграцией Telemt + Telemt Panel.

Проект рассчитан на Ubuntu/Debian и требует root-доступ или `sudo`.

## Быстрый запуск — одна команда

Эта команда работает и на чистой ноде, где `/opt/remna-node-scripts` ещё не существует. Она сама создаёт каталог, скачивает актуальный менеджер из ветки `main`, проверяет синтаксис, выставляет права и запускает меню:

```bash
sudo bash -c 'set -e; install -d -m 0755 /opt/remna-node-scripts; tmp=$(mktemp); curl -fsSL https://raw.githubusercontent.com/evgmahov-blip/remna-node-scripts/main/install-caddy-node-reality-stream.sh -o "$tmp"; bash -n "$tmp"; install -m 0700 "$tmp" /opt/remna-node-scripts/install-caddy-node-reality-stream.sh; rm -f "$tmp"; exec /opt/remna-node-scripts/install-caddy-node-reality-stream.sh'
```

Команда не пишет напрямую в конечный файл до проверки `bash -n`, поэтому при неудачном скачивании существующий рабочий менеджер не затирается.

## Безопасное обновление менеджера из `main`

Используйте ту же атомарную схему:

```bash
sudo bash -c 'set -e; install -d -m 0755 /opt/remna-node-scripts; tmp=$(mktemp); curl -fsSL https://raw.githubusercontent.com/evgmahov-blip/remna-node-scripts/main/install-caddy-node-reality-stream.sh -o "$tmp"; bash -n "$tmp"; install -m 0700 "$tmp" /opt/remna-node-scripts/install-caddy-node-reality-stream.sh; rm -f "$tmp"'
```

После обновления:

```bash
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh
```

## Что делает менеджер

Менеджер использует актуальный `install-caddy-node-reality-stream-core.sh` из `main`, а при недоступности GitHub может использовать уже сохранённый локальный core, только если он проходит `bash -n`.

Для Remnanode менеджер проверяет и при необходимости добавляет Docker capability:

```yaml
cap_add:
  - NET_ADMIN
```

Если `NET_ADMIN` уже записан в compose, но текущий контейнер был создан раньше без capability, менеджер пересоздаёт только `remnanode` и проверяет фактический `HostConfig.CapAdd` через `docker inspect`.

При подготовке REALITY менеджер не должен оставлять сайт недоступным: если Caddy уже переведён на `127.0.0.1:8443`, но `rw-core` не занял внешний `443`, выполняется безопасный возврат публичного Caddy на `443` из `/etc/caddy/Caddyfile.public`.

## Источники стрим-сайта

Если `STREAM_SITE_URL` не задан вручную, источники проверяются по порядку:

1. `https://rustream.remna.space`
2. `https://est.remna.2rdp.ru`
3. `https://nl.remna.2rdp.ru`

Используется первый доступный источник с валидной HTML-страницей. Если все источники недоступны, существующий `/var/www/mstream` не должен затираться.

## Меню

Встроенное меню содержит:

1. Полную установку Remnanode + Caddy + стрим-сайт.
2. Переустановку с нуля.
3. Только фронт Caddy.
4. Генерацию XHTTP-пути.
5. Изменение XHTTP-пути.
6. Обновление стрим-сайта.
7. Сводку настроек.
8. Безопасную диагностику.
9. Статус сервисов.
10. Подготовку REALITY.
11. Включение REALITY.
12. Отключение REALITY.
13. Просмотр файлов REALITY без вывода секретов.
14. Repair текущей ноды.
15. Безопасное подключение Telemt + Telemt Panel.
16. Статус Telemt + Telemt Panel.
17. Безопасное удаление интеграции Telemt Panel.
18. Clean Remnanode/Caddy.

## Диагностика

```bash
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh diagnose
```

Актуальная диагностика менеджера отдельно проверяет:

- состояние Caddy и внешний `443`;
- Node API на `2222`;
- XHTTP backend на `127.0.0.1:7443`;
- наличие `rw-core` на `443`;
- фактически применённый `NET_ADMIN`;
- состояние s6-сервиса Xray;
- наличие runtime-конфига Xray;
- CDN только после появления локального XHTTP backend.

Если Xray показывает `down (not started yet)` и runtime-конфигов нет, диагностика не должна ошибочно объявлять локальный firewall `2222` причиной только из-за отсутствующего `7443`.

## Telemt и Telemt Panel

Используются проекты:

- `telemt/telemt` — MTProxy;
- `amirotin/telemt_panel` — веб-панель управления Telemt.

Если на сервере уже существуют `telemt1.service`, `telemt2.service`, `telemt3.service` или `telemt.service`, менеджер считает их внешней существующей установкой и не должен переустанавливать или удалять их без явного действия пользователя.

Типовая конфигурация нескольких экземпляров:

```text
telemt1.service -> внешний порт 5222 -> API 127.0.0.1:9091
telemt2.service -> внешний порт 5223 -> API 127.0.0.1:9092
telemt3.service -> внешний порт 8530 -> API 127.0.0.1:9093
```

Telemt Panel обычно работает локально на:

```text
127.0.0.1:8080
```

с `base_path = "/telemt"`.

Внешний адрес панели:

```text
https://DOMAIN:18443/telemt/login
```

Схема:

```text
клиент :18443
   |
   v
redirect TCP/18443 -> TCP/443
   |
   v
REALITY / rw-core :443
   |
   v
Caddy 127.0.0.1:8443
   |
   v
/telemt/* -> 127.0.0.1:8080
   |
   v
Telemt Panel
```

Перед изменением существующего `/etc/telemt-panel/config.toml` должна создаваться резервная копия.

## Команды без меню

```bash
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh install
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh front-only
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh reinstall
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh path
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh path-set /api/v3/data.php
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh summary
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh diagnose
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh status
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh repair
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh stream
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh reality-prepare
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh reality-enable
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh reality-disable
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh reality-info
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh telemt-install
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh telemt-status
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh telemt-remove
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh clean
```

## Неинтерактивная установка Remnanode

После установки менеджера:

```bash
EMAIL=you@example.com \
DOMAIN=node.example.com \
SECRET_KEY='ваш_secret_key' \
sudo -E /opt/remna-node-scripts/install-caddy-node-reality-stream.sh --auto
```

Не публикуйте `SECRET_KEY`, REALITY private key, Telemt secrets, JWT secrets, токены и другие чувствительные значения.

## Порты

| Порт | Назначение |
|---|---|
| `80/tcp` | HTTP / ACME для Caddy |
| `443/tcp` | внешний REALITY / HTTPS |
| `18443/tcp` | внешний HTTPS-доступ к Telemt Panel через redirect на `443` |
| `7443/tcp` | XHTTP backend на `127.0.0.1` |
| `8443/tcp` | локальный Caddy за REALITY на `127.0.0.1` |
| `2222/tcp` | Remnanode / связь с панелью Remnawave |
| `8080/tcp` | Telemt Panel, только `127.0.0.1` |
| `9091+` | Telemt API, только `127.0.0.1` |
| `5222/5223/8530` | пример внешних портов отдельных экземпляров Telemt |

`7443`, `8443`, `8080` и Telemt API-порты рассчитаны на loopback и не должны быть доступны напрямую из Интернета.

## Основные файлы

```text
/etc/caddy/Caddyfile
/etc/caddy/Caddyfile.public
/etc/caddy/Caddyfile.reality
/etc/telemt/
/etc/telemt-panel/config.toml
/opt/remnanode/
/opt/remnanode/reality/
/var/www/mstream/
/opt/remna-node-scripts/install-caddy-node-reality-stream.sh
/opt/remna-node-scripts/install-caddy-node-reality-stream-core.sh
/opt/remna-node-scripts/telemt-manager.sh
```

## Clean Remnanode/Caddy

```bash
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh clean
```

Команда `clean` относится к Remnanode/Caddy. Существующие внешние экземпляры Telemt не должны удаляться этой командой.

## Важно

Перед изменением XHTTP-пути убедитесь, что одинаковое значение установлено в Config Profile, CDN Rewrite и хосте Remnawave. Несовпадение пути остановит XHTTP-трафик.
