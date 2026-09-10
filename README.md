# Remna Node Scripts

Набор скриптов для безопасной установки и переустановки Remnawave Node.

Основной сценарий сейчас — новый NEXT installer с XHTTP / RAW / REALITY, опциональным Hysteria2, маскировочным сайтом и RKN SAFE scanner guard.

> Для новых установок используй только ссылки ниже. Старый Caddy-manager оставлен в репозитории для совместимости и обслуживания старых нод.

## Быстрая установка

### Чистая новая нода

Скрипт запускает установку без предварительной очистки существующего stack:

```bash
sudo bash -c 'tmp=$(mktemp); curl -fsSL https://raw.githubusercontent.com/evgmahov-blip/remna-node-scripts/main/install.sh -o "$tmp" && bash -n "$tmp" && bash "$tmp"'
```

Файл: [install.sh](./install.sh)

## Clean install / полная переустановка

Для старой ноды или если нужно гарантированно убрать прежний Remnanode / Caddy / Hysteria / RKN stack и поставить заново:

```bash
sudo bash -c 'tmp=$(mktemp); curl -fsSL https://raw.githubusercontent.com/evgmahov-blip/remna-node-scripts/main/clean-install.sh -o "$tmp" && bash -n "$tmp" && bash "$tmp"'
```

Файл: [clean-install.sh](./clean-install.sh)

Перед очисткой выполняются precheck и backup. SSH, default route, DNS, hostname, Docker как пакет и чужие контейнеры глобально не сбрасываются.

## Универсальный launcher

[full-clean-reinstall.sh](./full-clean-reinstall.sh)

Поддерживает режимы:

```bash
# только установка
sudo bash full-clean-reinstall.sh install

# clean + установка
sudo bash full-clean-reinstall.sh reinstall

# только очистка
sudo bash full-clean-reinstall.sh clean

# интерактивное меню
sudo bash full-clean-reinstall.sh
```

## Что устанавливается

- Remnawave Node;
- REALITY;
- XHTTP / RAW profiles;
- опциональный Hysteria2;
- маскировочный сайт STREAM / RADIO;
- RKN SAFE scanner protection;
- boot restore и автоматическое обновление RKN guard;
- генерация Remnawave Config Profile / Host;
- диагностика и post-install verification.

## Важно

- Скрипты предназначены для Debian / Ubuntu и запускаются от root или через `sudo`.
- Перед выполнением скачанный файл проверяется `bash -n`.
- Production installer внутри launcher закрепляется на конкретные commit SHA, а не запускается вслепую из `latest`.
- Не публикуй `SECRET_KEY`, REALITY private key, сертификаты, токены и другие секреты.

## Старый installer

Старый Caddy-based manager сохранён только для уже существующих legacy-нод:

[install-caddy-node-reality-stream.sh](./install-caddy-node-reality-stream.sh)

Для новых нод используй `install.sh` или `clean-install.sh`.
