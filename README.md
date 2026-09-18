# Remna Node Scripts

Набор скриптов для установки, обслуживания и защиты Remnawave Node.

Главный принцип этой версии: код, который выполняется от root, не должен незаметно меняться вслед за веткой `main` или сторонним сайтом. Launcher-цепочка закреплена на commit SHA и дополнительно проверяет ожидаемый Git blob SHA перед передачей управления следующему скрипту.

## Быстрая установка

### Новая нода

Используйте immutable snapshot, а не `main`:

```bash
sudo bash -c 'tmp=$(mktemp); trap '\''rm -f "$tmp"'\'' EXIT; curl -fsSL --proto "=https" --tlsv1.2 https://raw.githubusercontent.com/evgmahov-blip/remna-node-scripts/11a11459d91356e3358fad831f86a233982fd49e/install.sh -o "$tmp" && bash -n "$tmp" && bash "$tmp"'
```

### Clean install / полная переустановка

```bash
sudo bash -c 'tmp=$(mktemp); trap '\''rm -f "$tmp"'\'' EXIT; curl -fsSL --proto "=https" --tlsv1.2 https://raw.githubusercontent.com/evgmahov-blip/remna-node-scripts/11a11459d91356e3358fad831f86a233982fd49e/clean-install.sh -o "$tmp" && bash -n "$tmp" && bash "$tmp"'
```

Перед очисткой manager сохраняет предусмотренные им backup-файлы и не делает глобальный reset firewall/Docker. SSH, default route, DNS, hostname и чужие Docker-сервисы не должны удаляться.

## Как устроена цепочка доверия

`bash -n` проверяет только синтаксис Bash. Он **не является проверкой безопасности или подлинности**.

Подлинность исполняемых helper-скриптов обеспечивается отдельно:

1. верхний URL указывает на неизменяемый commit SHA;
2. `install.sh` / `clean-install.sh` скачивают закреплённый `full-clean-reinstall.sh`;
3. перед запуском вычисляется Git blob SHA и сравнивается с ожидаемым;
4. `full-clean-reinstall.sh` таким же образом проверяет публичный manager;
5. manager загружает core / Telemt / protection / Caddy guard только из закреплённого commit и сверяет Git blob SHA.

Закрытый `setup-remna-node` в production-цепочке больше не используется.

## Что устанавливается

Основной manager поддерживает:

- Remnawave Node;
- XHTTP и REALITY;
- Caddy frontend;
- локальный маскировочный сайт;
- Telemt + Telemt Panel;
- firewall-защиту Node API и дополнительные TSPU/GOV/GeoIP списки;
- диагностику, repair и self-test.

Маскировочный сайт по умолчанию встроен в core и не загружает чужой JavaScript. Если нужен внешний HTML или архив, оператор должен явно передать HTTPS-источник и `STREAM_SITE_SHA256`.

## Универсальный launcher

[full-clean-reinstall.sh](./full-clean-reinstall.sh)

```bash
sudo bash full-clean-reinstall.sh install
sudo bash full-clean-reinstall.sh reinstall
sudo bash full-clean-reinstall.sh clean
sudo bash full-clean-reinstall.sh
```

## Безопасность

- Скрипты рассчитаны на Debian / Ubuntu и root/`sudo`.
- GHOST OS license-check, удалённый kill-switch и скрытый watermark удалены.
- Сторонний `deepbeat` reverse proxy удалён.
- TSPU/GOV snapshots закреплены на commit + Git blob SHA.
- GeoIP загружается из закреплённого commit и обновляется fail-closed: неполный набор не заменяет рабочий.
- Telemt Panel слушает только loopback и публикуется через Caddy; старый public `18443 -> 443` redirect удаляется.
- Секреты Remnawave и 3x-ui не должны печататься в stdout.
- Не публикуйте `SECRET_KEY`, REALITY private key, сертификаты, токены и файлы credentials.

## 3x-ui + Happ

Отдельный сценарий находится в [3xui-happ-node](./3xui-happ-node/README.md). Он также использует закреплённые upstream commit/release digest, держит панель на loopback и сохраняет реквизиты в root-only файл.

## Manager

[install-caddy-node-reality-stream.sh](./install-caddy-node-reality-stream.sh) является публичным проверяемым manager для launcher-цепочки. Старые установленные копии могут отличаться от текущего snapshot — перед обновлением сравнивайте версию/commit.
