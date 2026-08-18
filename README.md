# Remna Node Scripts

Один Bash-скрипт для установки и обслуживания Remnanode с Caddy, XHTTP через CDN, стрим-сайтом, VLESS RAW REALITY Vision и безопасной интеграцией Telemt + Telemt Panel.

Проект рассчитан на Ubuntu/Debian и требует root-доступ или `sudo`.

## Быстрый запуск — одна команда

Команда работает из любого текущего каталога: сама создаёт `/opt/remna-node-scripts`, скачивает актуальный скрипт из `main`, выставляет права и сразу открывает встроенное меню.

```bash
sudo bash -c 'mkdir -p /opt/remna-node-scripts && curl -fsSL https://raw.githubusercontent.com/evgmahov-blip/remna-node-scripts/main/install-caddy-node-reality-stream.sh -o /opt/remna-node-scripts/install-caddy-node-reality-stream.sh && chmod 700 /opt/remna-node-scripts/install-caddy-node-reality-stream.sh && exec /opt/remna-node-scripts/install-caddy-node-reality-stream.sh'
```

Для повторного запуска:

```bash
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh
```

## Меню

Встроенное меню содержит:

1. Полную установку Remnanode + Caddy + стрим-сайт.
2. Переустановку с нуля.
3. Только фронт Caddy.
4. Генерацию XHTTP-пути.
5. Изменение XHTTP-пути.
6. Обновление стрим-сайта.
7. Сводку настроек.
8. Диагностику.
9. Статус сервисов.
10. Подготовку REALITY.
11. Включение REALITY.
12. Отключение REALITY.
13. Просмотр файлов REALITY без вывода секретов.
14. Repair текущей ноды.
15. Установку/настройку Telemt + Telemt Panel.
16. Статус Telemt + Telemt Panel.
17. Безопасное удаление интеграции Telemt Panel.
18. Clean Remnanode/Caddy.

## Telemt и Telemt Panel

Используются проекты:

- `telemt/telemt` — MTProxy;
- `amirotin/telemt_panel` — веб-панель управления Telemt.

### Безопасная работа с существующим Telemt

Если на сервере уже существуют `telemt1.service`, `telemt2.service`, `telemt3.service` или `telemt.service`, скрипт считает их внешней существующей установкой и **не переустанавливает, не обновляет и не удаляет их**.

Для конфигурации с несколькими экземплярами скрипт использует первый подходящий API. Типовой вариант:

```text
telemt1.service -> внешний порт 5222 -> API 127.0.0.1:9091
telemt2.service -> внешний порт 5223 -> API 127.0.0.1:9092
telemt3.service -> внешний порт 8530 -> API 127.0.0.1:9093
```

Telemt Panel подключается к API выбранного экземпляра локально. API-порты `9091/9092/9093` наружу открывать не нужно.

### Telemt Panel

Панель работает локально:

```text
127.0.0.1:8080
```

В конфиг панели добавляется:

```text
base_path = "/telemt"
```

Перед изменением существующего `/etc/telemt-panel/config.toml` создаётся резервная копия.

### HTTPS панели на 18443

Внешний адрес панели имеет вид:

```text
https://DOMAIN:18443/telemt/login
```

Например:

```text
https://node.example.com:18443/telemt/login
```

Схема работы:

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

Так используется существующий сертификат домена и не создаётся второй конфликтующий TLS automation policy в Caddy.

В Caddy маршрут панели добавляется только после проверки временного конфига через `caddy validate`. Интеграционный блок помечается маркерами, чтобы при удалении можно было убрать только добавленные строки.

Для redirect создаётся отдельный systemd-unit, чтобы правило `18443 -> 443` восстанавливалось после перезагрузки сервера.

Если UFW активен, скрипт открывает `18443/tcp`. Сам Telemt использует свои отдельные внешние порты; `443/tcp` зарезервирован для схемы REALITY/Caddy и не должен использоваться Telemt.

## Проверка Telemt

Через меню выберите пункт `16` или выполните:

```bash
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh telemt-status
```

Нормальное состояние выглядит примерно так:

```text
Telemt Panel: active
127.0.0.1:8080 -> telemt-panel
127.0.0.1:9091 -> telemt API
0.0.0.0:5222 -> telemt
*:443 -> rw-core
Redirect 18443->443: присутствует
```

## Безопасное удаление Telemt-интеграции

Пункт `17` или команда:

```bash
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh telemt-remove
```

по умолчанию удаляет только интеграцию, созданную этим скриптом:

- redirect `18443 -> 443`;
- systemd-unit redirect;
- добавленный блок `/telemt` в Caddy.

Существующие `telemt1/2/3` не удаляются.

Существующая Telemt Panel также не удаляется, если она была обнаружена до подключения интеграции. Полное удаление допускается только для компонентов, которые сам скрипт установил и отметил как managed.

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
/etc/systemd/system/telemt-panel.service
/opt/remnanode/
/opt/remnanode/reality/
/var/www/mstream/
/opt/remna-node-scripts/install-caddy-node-reality-stream.sh
```

REALITY-ключи находятся в `/opt/remnanode/reality/reality.env`. Не публикуйте содержимое этого файла.

## Диагностика

```bash
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh diagnose
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh status
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh telemt-status
```

Для ручной проверки портов:

```bash
ss -ltnp | grep -E ':443 |:18443 |:5222 |:5223 |:8530 |:8080 |:9091 '
```

## Clean Remnanode/Caddy

```bash
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh clean
```

Эта команда относится к Remnanode/Caddy: удаляет локальный контейнер Remnanode, `/opt/remnanode`, основной Caddyfile и стрим-сайт. Сам пакет Caddy и записи ноды/Config Profile в панели Remnawave автоматически не удаляются.

## Важно

Перед изменением XHTTP-пути убедитесь, что одинаковое значение установлено в Config Profile, CDN Rewrite и хосте Remnawave. Несовпадение пути остановит трафик.

Перед любыми ручными изменениями Telemt рекомендуется сохранить `/etc/telemt/`, а перед изменением панели — `/etc/telemt-panel/config.toml`.
