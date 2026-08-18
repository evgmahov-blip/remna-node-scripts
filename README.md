# Remna Node Scripts

Один Bash-скрипт для установки и обслуживания Remnanode с Caddy, XHTTP через CDN, стрим-сайтом и VLESS RAW REALITY Vision.

Проект рассчитан на Ubuntu/Debian и требует root-доступ или `sudo`.

## Быстрый запуск

```bash
sudo -i
mkdir -p /opt/remna-node-scripts
cd /opt/remna-node-scripts
curl -fsSLO https://raw.githubusercontent.com/evgmahov-blip/remna-node-scripts/main/install-caddy-node-reality-stream.sh
chmod 700 install-caddy-node-reality-stream.sh
./install-caddy-node-reality-stream.sh
```

Запуск **без аргументов** открывает встроенное меню.

## Меню

Встроенное меню содержит:

1. Полную установку Remnanode + Caddy + стрим-сайт.
2. Переустановку с нуля.
3. Установку только фронта Caddy.
4. Генерацию нового XHTTP-пути.
5. Обновление стрим-сайта.
6. Сводку настроек для CDN и Remnawave.
7. Диагностику.
8. Статус сервисов и портов.
9. Подготовку REALITY.
10. Включение REALITY.
11. Отключение REALITY.
12. Просмотр путей к файлам REALITY без вывода секретов.
13. Repair текущей ноды.
14. Локальный `clean` — удаление Remnanode, `/opt/remnanode`, Caddyfile и стрим-сайта.

## Команды без меню

```bash
./install-caddy-node-reality-stream.sh install
./install-caddy-node-reality-stream.sh front-only
./install-caddy-node-reality-stream.sh reinstall
./install-caddy-node-reality-stream.sh path
./install-caddy-node-reality-stream.sh path-set /api/v3/data.php
./install-caddy-node-reality-stream.sh summary
./install-caddy-node-reality-stream.sh diagnose
./install-caddy-node-reality-stream.sh status
./install-caddy-node-reality-stream.sh repair
./install-caddy-node-reality-stream.sh stream
./install-caddy-node-reality-stream.sh reality-prepare
./install-caddy-node-reality-stream.sh reality-enable
./install-caddy-node-reality-stream.sh reality-disable
./install-caddy-node-reality-stream.sh reality-info
./install-caddy-node-reality-stream.sh clean
```

## Неинтерактивная установка

```bash
EMAIL=you@example.com \
DOMAIN=node.example.com \
SECRET_KEY='ваш_secret_key' \
./install-caddy-node-reality-stream.sh --auto
```

Не публикуйте `SECRET_KEY`, REALITY private key, токены и другие секретные значения в логах, issue или сообщениях.

## Порты

| Порт | Назначение |
|---|---|
| `80/tcp` | HTTP / ACME для Caddy |
| `443/tcp` | внешний HTTPS или REALITY |
| `7443/tcp` | XHTTP backend на `127.0.0.1` |
| `8443/tcp` | локальный Caddy за REALITY на `127.0.0.1` |
| `2222/tcp` | API Remnanode / связь с панелью |

`7443` и `8443` рассчитаны на loopback и обычно не должны открываться наружу.

## Основные файлы

```text
/etc/caddy/Caddyfile
/etc/caddy/Caddyfile.public
/etc/caddy/Caddyfile.reality
/opt/remnanode/
/opt/remnanode/reality/
/var/www/mstream/
/opt/remna-node-scripts/install-caddy-node-reality-stream.sh
```

REALITY-ключи находятся в `/opt/remnanode/reality/reality.env`. Не публикуйте содержимое этого файла.

## Диагностика

```bash
./install-caddy-node-reality-stream.sh diagnose
```

Для краткого состояния:

```bash
./install-caddy-node-reality-stream.sh status
```

## Удаление

Штатная команда:

```bash
./install-caddy-node-reality-stream.sh clean
```

Она удаляет локальный контейнер Remnanode, `/opt/remnanode`, основной Caddyfile и стрим-сайт. Сам пакет Caddy и firewall не удаляются. Запись ноды и Config Profile в панели Remnawave также удаляются вручную.

## Важно

Перед изменением XHTTP-пути убедитесь, что одинаковое значение будет установлено в Config Profile, CDN Rewrite и хосте Remnawave. Несовпадение пути остановит трафик.
