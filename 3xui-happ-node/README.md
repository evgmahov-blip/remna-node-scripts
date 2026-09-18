# 3x-ui + XHTTP + Hysteria2 + Happ

Отдельный installer для 3x-ui/Happ с XHTTP и Hysteria2.

Эта версия минимизирует внешний trust surface: 3x-ui закреплён на конкретном source commit и release digest, панель не слушает публичный интерфейс, а маскировочный сайт по умолчанию локальный.

## Что устанавливается

- 3x-ui `v3.7.0`;
- VLESS/XHTTP inbound на loopback;
- Hysteria2 UDP/443;
- Happ subscription;
- Caddy на TCP/443;
- 3x-ui Panel на `127.0.0.1:<PANEL_PORT>`, доступная снаружи только через Caddy по случайному `PANEL_PATH`;
- встроенная статическая маскировочная страница.

## Запуск

Используйте immutable snapshot репозитория:

```bash
curl -fsSL --proto '=https' --tlsv1.2 \
  https://raw.githubusercontent.com/evgmahov-blip/remna-node-scripts/40b796988351f91130c49944b4d7351da51be0ee/3xui-happ-node/install.sh \
  -o /root/install-3xui-happ-node.sh
bash -n /root/install-3xui-happ-node.sh
sudo bash /root/install-3xui-happ-node.sh
```

`bash -n` проверяет только синтаксис. Supply-chain защита находится внутри installer: upstream source и release artifacts закреплены и проверяются digest-ами.

Можно передать параметры через окружение:

```bash
sudo DOMAIN=stream.example.com EMAIL=admin@example.com \
  bash /root/install-3xui-happ-node.sh
```

## Закреплённый upstream 3x-ui

```text
version:       3.7.0
tag:           v3.7.0
source commit: f727d04f6522bb94a8fb52e8352fdcafb51c11e1
install.sh:    Git blob 4ff60a069362e618d5149abc4cbc5246629c93ea
```

Installer загружает upstream `install.sh` по commit SHA, сверяет Git blob SHA, переписывает оставшиеся upstream helper URL с `main` на тот же audited commit, отдельно скачивает release archive `v3.7.0`, сверяет официальный SHA-256 для текущей архитектуры и запускает upstream installer с явным аргументом `v3.7.0`.

Обновление версии 3x-ui требует явного изменения source commit и release SHA-256. Автоматического перехода на `latest` нет.

## Панель

После установки 3x-ui принудительно переводится на:

```text
127.0.0.1:<PANEL_PORT>
```

Caddy публикует только скрытый path:

```text
https://stream.example.com/<random-panel-path>/
```

Публичный `PANEL_PORT` не нужен. Если listener панели обнаружен не на loopback, installer завершается ошибкой.

## Credentials

Username/password больше не выводятся в stdout. Они сохраняются в:

```text
/root/3xui-happ-node.credentials
```

Права файла: `0600`. В нём находятся URL панели, username, password и URL подписки.

## Маскировочный сайт

По умолчанию `INSTALL_RADIO_STUB=no`: создаётся простая локальная HTML-страница без внешнего JS/CSS.

Если явно установить `INSTALL_RADIO_STUB=yes`, будет загружен только `index.html` из закреплённого commit `Balbuto/radio-stub-site` и проверен по Git blob SHA. `admin.html` не устанавливается.

## TLS

Caddy разрешает TLS 1.2 и TLS 1.3. Hysteria2 использует QUIC/TLS 1.3.

## Сертификаты

Certbot получает сертификат для `DOMAIN`. 3x-ui использует этот сертификат только на loopback listener, а Caddy подключается к backend по HTTPS с ожидаемым SNI. Deploy hook обновляет копию сертификата, валидирует/reload-ит Caddy и перезапускает x-ui, чтобы backend подхватил новый сертификат.

## После установки

```bash
systemctl is-active caddy
systemctl is-active x-ui
ss -lntup
curl -I https://stream.example.com/
```

Убедитесь, что TCP `PANEL_PORT` не слушает `0.0.0.0` / `[::]`. Секреты из credentials-файла не вставляйте в issue, CI logs или публичные чаты.
