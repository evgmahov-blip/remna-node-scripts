# Remna Node Scripts

Набор Bash-скриптов для установки и обслуживания Remnanode с Caddy, XHTTP через CDN, стрим-сайтом и отдельным VLESS RAW REALITY Vision на одном сервере.

> Проект рассчитан на Ubuntu/Debian и требует root-доступ или `sudo`.

## Что умеет

Основной `install-caddy-node-reality-stream.sh` устанавливает Caddy и Remnanode, настраивает XHTTP/CDN, стрим-сайт, готовит XHTTP и REALITY inbound JSON, показывает статус, выполняет диагностику/repair и умеет менять XHTTP-путь.

`remna-node-manager.sh` добавляет постоянное интерактивное меню и безопасное подменю удаления.

## Быстрый запуск менеджера

```bash
sudo -i
mkdir -p /opt/remna-node-scripts
cd /opt/remna-node-scripts
curl -fsSLO https://raw.githubusercontent.com/evgmahov-blip/remna-node-scripts/main/install-caddy-node-reality-stream.sh
curl -fsSLO https://raw.githubusercontent.com/evgmahov-blip/remna-node-scripts/main/remna-node-manager.sh
chmod 700 install-caddy-node-reality-stream.sh remna-node-manager.sh
./remna-node-manager.sh
```

Менеджер использует основной скрипт из той же директории или `/opt/remna-node-scripts/`.

## Установка без меню

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/evgmahov-blip/remna-node-scripts/main/install-caddy-node-reality-stream.sh) install
```

Неинтерактивно:

```bash
EMAIL=you@example.com \
DOMAIN=node.example.com \
SECRET_KEY='ваш_secret_key' \
bash install-caddy-node-reality-stream.sh --auto
```

Не публикуйте `SECRET_KEY` в истории shell, логах, issue или сообщениях.

## Меню

Менеджер содержит полную установку, переустановку, Caddy-only, генерацию и изменение XHTTP-пути, обновление стрим-сайта, сводку, диагностику, статус, команды REALITY, repair и удаление.

После каждой операции менеджер возвращается в главное меню. Основной установщик запускается отдельным Bash-процессом, поэтому изменения `set`/`trap` внутри диагностики не ломают цикл менеджера.

## Удаление

В менеджере доступны четыре варианта:

1. Удалить только Remnanode и `/opt/remnanode`.
2. Удалить Caddy-конфигурацию и стрим-сайт, сохранив бэкап конфигов.
3. Выполнить штатный `clean` основного скрипта.
4. Полностью удалить локальные компоненты, включая пакет Caddy и `/opt/remna-node-scripts`.

Опасные действия требуют подтверждения. Полное удаление требует вручную ввести `DELETE`.

Удаление на сервере **не удаляет** автоматически ноду, Config Profile и другие объекты из панели Remnawave. Firewall также не изменяется.

## Основные команды

```bash
./install-caddy-node-reality-stream.sh menu
./install-caddy-node-reality-stream.sh install
./install-caddy-node-reality-stream.sh front-only
./install-caddy-node-reality-stream.sh reinstall
./install-caddy-node-reality-stream.sh status
./install-caddy-node-reality-stream.sh diagnose
./install-caddy-node-reality-stream.sh repair
./install-caddy-node-reality-stream.sh path
./install-caddy-node-reality-stream.sh path-set /api/v3/data.php
./install-caddy-node-reality-stream.sh stream
./install-caddy-node-reality-stream.sh summary
./install-caddy-node-reality-stream.sh reality-prepare
./install-caddy-node-reality-stream.sh reality-enable
./install-caddy-node-reality-stream.sh reality-disable
./install-caddy-node-reality-stream.sh reality-info
./install-caddy-node-reality-stream.sh clean
```

## Порты

| Порт | Назначение |
|---|---|
| `80/tcp` | HTTP/ACME для Caddy |
| `443/tcp` | внешний HTTPS или REALITY |
| `7443/tcp` | локальный XHTTP backend (`127.0.0.1`) |
| `8443/tcp` | локальный Caddy за REALITY (`127.0.0.1`) |
| `2222/tcp` | API Remnanode / связь с панелью |

`7443` и `8443` рассчитаны на loopback и обычно не должны открываться наружу.

## Файлы

```text
/etc/caddy/Caddyfile
/etc/caddy/Caddyfile.public
/etc/caddy/Caddyfile.reality
/opt/remnanode/
/opt/remnanode/reality/
/var/www/mstream/
/opt/remna-node-scripts/
```

REALITY-ключи находятся в `/opt/remnanode/reality/reality.env`. Не публикуйте содержимое этого файла.

## Диагностика

Через меню выберите `Диагностика` или выполните:

```bash
./install-caddy-node-reality-stream.sh diagnose
```

Ручные проверки:

```bash
systemctl status caddy --no-pager
docker ps -a --filter name=remnanode
docker logs --tail 50 remnanode
ss -lntp | grep -E ':80|:443|:2222|:7443|:8443'
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
```

## Важно

- XHTTP-путь должен совпадать в Config Profile, CDN Rewrite и хосте Remnawave.
- `path-set` делает бэкап Caddy-конфигов перед изменением пути.
- Не публикуйте `SECRET_KEY`, REALITY private key и другие секреты.
- Запись ноды в панели Remnawave после локального удаления удаляется вручную.

## Проверка синтаксиса

```bash
bash -n install-caddy-node-reality-stream.sh
bash -n remna-node-manager.sh
```

При наличии ShellCheck:

```bash
shellcheck install-caddy-node-reality-stream.sh remna-node-manager.sh
```

## GHOST OS

В основном установочном скрипте присутствует проверка лицензии GHOST OS. Не удаляйте и не изменяйте лицензионный блок без соответствующего разрешения.
