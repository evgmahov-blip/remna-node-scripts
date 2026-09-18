# Remna Node Scripts

Установка и обслуживание **Remnawave Node** с двумя вариантами подключения на одном TCP/443:

- **VLESS XHTTP** через CDN;
- **VLESS RAW + REALITY Vision** напрямую.

Скрипт поднимает Remnanode, Caddy, маскировочный сайт, готовит XHTTP/REALITY inbound-файлы, защищает Node API на TCP/2222 и умеет диагностировать/ремонтировать уже установленную ноду.

> Это не установщик панели Remnawave и не настройщик CDN. Панель, Config Profile, Host и CDN-ресурс настраиваются отдельно. После установки скрипт выводит готовые параметры и пути к JSON-файлам.

---

## Что получается после установки

До включения REALITY:

```text
Internet / CDN
      |
   TCP/443
      |
    Caddy
      |
127.0.0.1:7443
      |
 XHTTP / rw-core
```

После включения REALITY:

```text
                 TCP/443
                    |
                 rw-core
                /       \
       REALITY direct    XHTTP
              |             |
      127.0.0.1:8443    127.0.0.1:7443
              |
            Caddy
```

Caddy автоматически переключается между публичным `:443` и локальным `127.0.0.1:8443` в зависимости от того, занят ли внешний TCP/443 REALITY-inbound'ом.

---

## Требования

- Debian / Ubuntu;
- root или `sudo`;
- домен, A-запись которого указывает на сервер;
- открытые TCP/80 и TCP/443 для HTTPS/Let's Encrypt;
- `SECRET_KEY` ноды из панели Remnawave, если Remnanode ставится на этом сервере;
- IP сервера панели Remnawave для ограничения TCP/2222.

Docker и Caddy при необходимости устанавливаются скриптом.

---

## Быстрая установка новой ноды

Рекомендуемый запуск — из закреплённого snapshot, а не из изменяемой ветки `main`:

```bash
curl -fsSL --proto '=https' --tlsv1.2 \
  https://raw.githubusercontent.com/evgmahov-blip/remna-node-scripts/7c9ab91eb62bb96c0dd35d089806a5afe21968c0/install.sh \
  -o /tmp/remna-install.sh

sudo bash /tmp/remna-install.sh
```

Во время установки будут запрошены:

1. email для Let's Encrypt;
2. домен ноды;
3. `SECRET_KEY` Remnawave Node;
4. XHTTP-путь — можно просто нажать Enter и получить случайный;
5. IP панели Remnawave для закрытия TCP/2222.

`SECRET_KEY` читается скрыто и не выводится обратно в терминал.

Если оставить `SECRET_KEY` пустым, будет установлен только Caddy/frontend без Remnanode.

---

## После установки

Скрипт создаёт готовые файлы:

```text
/opt/remnanode/reality/xhttp-inbound.json
/opt/remnanode/reality/reality-inbound.json
/opt/remnanode/reality/inbounds-ready.json
/opt/remnanode/reality/reality.env
```

Права на файлы с ключами — `0600`.

Дальше нужно:

1. добавить содержимое `inbounds-ready.json` в Config Profile Remnawave;
2. назначить этот профиль ноде;
3. создать/обновить Host в панели;
4. настроить CDN-ресурс и Rewrite с **тем же XHTTP-путём**;
5. проверить ноду через диагностику/self-test.

Установщик в конце сам выводит подробную сводку **«что и куда вставлять»**.

Повторно показать её:

```bash
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh summary
```

---

## Главное меню

После первой установки manager сохраняется сюда:

```text
/opt/remna-node-scripts/install-caddy-node-reality-stream.sh
```

Запуск меню:

```bash
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh
```

В меню доступны:

```text
[1]  Полная установка
[2]  Переустановка с нуля
[3]  Только фронт Caddy
[4]  Сгенерировать XHTTP-путь
[5]  Изменить XHTTP-путь
[6]  Обновить маскировочный сайт
[7]  Сводка настроек
[8]  Диагностика
[9]  Статус сервисов
[10] Подготовить REALITY
[11] Включить REALITY
[12] Отключить REALITY
[13] Файлы REALITY
[14] Repair Caddy / XHTTP / REALITY
[15] Clean Remnanode/Caddy
[16] Защита ноды
[17] Закрыть TCP/2222 только для IP панели
[18] Полный self-test инфраструктуры
```

Пункты 14 и 18 решают разные задачи:

| Действие | Для чего |
|---|---|
| **14 — Repair Caddy / XHTTP / REALITY** | Ремонт рабочего тракта: сайт, Caddy, XHTTP/REALITY-конфиги, TCP/443 и handoff |
| **18 — Полный self-test инфраструктуры** | Проверка/авторемонт compose, SECRET_KEY, NET_ADMIN, firewall, 2222, ipset, systemd и topology guard |

---

## Полезные команды

### Диагностика

```bash
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh diagnose
```

### Полный self-test инфраструктуры

Проверяет и при необходимости восстанавливает инфраструктурные инварианты узла: compose, SECRET_KEY, NET_ADMIN, firewall/ipset, защиту TCP/2222, systemd restore/timer, Caddy topology guard и REALITY handoff watcher. В конце запускает общую диагностику.

```bash
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh selftest
```

### Статус Caddy / Remnanode / портов

```bash
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh status
```

### Подготовить XHTTP + REALITY JSON

```bash
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh reality-prepare
```

### Включить REALITY после назначения профиля

```bash
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh reality-enable
```

### Вернуть Caddy на публичный TCP/443

Сначала отключите/удалите REALITY inbound в Config Profile, затем:

```bash
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh reality-disable
```

### Repair Caddy / XHTTP / REALITY

Чинит именно рабочий тракт трафика: Caddy, маскировочный сайт и права, XHTTP/REALITY JSON, конфликт за TCP/443 и переключение Caddy между публичным :443 и локальным 127.0.0.1:8443. Это не тот же механизм, что полный инфраструктурный self-test.

```bash
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh repair
```

---

## Защита TCP/2222 и firewall

Node API Remnawave слушает TCP/2222. Для всех адресов, кроме сервера панели, порт должен быть закрыт.

Задать IP панели:

```bash
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh panel-set 203.0.113.10
```

Проверить:

```bash
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh protect-status
```

Установить полный protection-модуль с TSPU/GOV blocklists и systemd timer:

```bash
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh protect-install
```

По умолчанию дополнительные blocklists применяются к TCP/443. GeoIP allow-list выключен, пока его явно не включат.

Подробности: [PROTECTION.md](./PROTECTION.md).

---

## Переустановка с нуля

```bash
curl -fsSL --proto '=https' --tlsv1.2 \
  https://raw.githubusercontent.com/evgmahov-blip/remna-node-scripts/7c9ab91eb62bb96c0dd35d089806a5afe21968c0/clean-install.sh \
  -o /tmp/remna-clean-install.sh

sudo bash /tmp/remna-clean-install.sh
```

Или на уже установленной машине:

```bash
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh reinstall
```

**Важно:** reinstall удаляет локальный контейнер Remnanode, `/opt/remnanode`, текущий Caddyfile и маскировочный сайт, после чего создаёт новую установку и новый XHTTP-путь.

Firewall целиком не сбрасывается, пакет Caddy не удаляется, SSH/DNS/default route не трогаются.

---

## Маскировочный сайт

По умолчанию используется встроенная статическая страница без внешнего JavaScript и сторонних ресурсов.

Каталог:

```text
/var/www/mstream
```

Если нужно установить свой HTML/архив, удалённый источник принимается только вместе с явно заданным `STREAM_SITE_SHA256`.

---

## Порты

| Порт | Назначение |
|---|---|
| TCP/80 | Let's Encrypt / HTTP |
| TCP/443 | Caddy до REALITY, затем REALITY/rw-core |
| TCP/2222 | Remnawave Node API — только IP панели |
| 127.0.0.1:7443 | XHTTP backend |
| 127.0.0.1:8443 | Caddy за REALITY |

Никакие 3x-ui/Telemt-сервисы этим репозиторием не устанавливаются.

---

## Файлы

| Файл | Назначение |
|---|---|
| `install.sh` | простая установка новой ноды |
| `clean-install.sh` | clean reinstall |
| `full-clean-reinstall.sh` | проверяемый launcher |
| `install-caddy-node-reality-stream.sh` | основной manager, меню, repair/self-test |
| `install-caddy-node-reality-stream-core.sh` | установка Caddy/Remnanode, XHTTP/REALITY |
| `protection-manager.sh` | firewall, TCP/2222, blocklists, GeoIP |
| `caddy-resilient-start.sh` | topology guard Caddy ↔ REALITY |
| `PROTECTION.md` | подробности firewall-защиты |

---

## Supply-chain и безопасность

Исполняемые helper-скрипты не загружаются вслепую из `main`.

Цепочка выглядит так:

```text
install.sh
  -> pinned full-clean-reinstall.sh + Git blob SHA
      -> pinned manager + Git blob SHA
          -> pinned core / protection / Caddy guard + Git blob SHA
```

Дополнительно:

- Docker installer закреплён на конкретном commit и проверяется по Git blob SHA;
- Remnawave Node image закреплён на конкретной версии;
- TSPU/GOV источники закреплены на commit + blob SHA;
- GeoIP использует immutable commit и fail-closed обновление;
- Caddyfile валидируется до применения;
- конфиги и ключи REALITY хранятся с ограниченными правами;
- логи с потенциальными секретами редактируются перед выводом;
- CI проверяет Bash syntax, shellcheck, запрещённые mutable endpoints и невидимые zero-width символы.

`bash -n` — **только проверка синтаксиса**, а не проверка безопасности.

---

## Что репозиторий намеренно не делает

- не устанавливает Remnawave Panel;
- не создаёт CDN-ресурс через API;
- не меняет DNS;
- не содержит 3x-ui;
- не содержит Telemt;
- не делает глобальный `ufw reset`;
- не удаляет чужие Docker-сервисы;
- не печатает `SECRET_KEY` или REALITY private key.

---

## Если что-то не работает

Начните с:

```bash
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh diagnose
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh selftest
```

Для ручной проверки:

```bash
docker ps
ss -lntp
sudo caddy validate --config /etc/caddy/Caddyfile
sudo journalctl -u caddy -n 50 --no-pager
sudo docker logs --tail 50 remnanode
```

Не публикуйте в issue/чатах `SECRET_KEY`, содержимое `reality.env`, REALITY private key и другие токены.
