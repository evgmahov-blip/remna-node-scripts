# Защита Remna Node

Единая точка входа — `protection-manager.sh`. Она вызывает `security/remna-security.sh` и не является отдельным firewall-продуктом. Модуль по-прежнему владеет только `REMNA_GUARD` / `REMNA_GUARD6`, своими ipset `REMNA_*` и, если backend явно переключён, таблицей nftables `inet remna_security`.

Он не выполняет `ufw reset`, не делает `iptables -F INPUT`, не делает `nft flush ruleset` и не удаляет правила Docker, UFW или пользователя.

Это изменение не активирует защиту на живых нодах. NEXT по-прежнему ставит recovered `rkn-watcher-manager.sh` из pinned source bundle. Включение нового модуля на реальном RemnaNode требует отдельного human approval.

## TCP/2222 — только сервер панели

`remnanode` слушает Node API на TCP/2222. Модуль требует явный `PANEL_IP` и строит правило:

```text
src = PANEL_IP -> tcp/2222 ACCEPT
all others     -> tcp/2222 DROP
```

Если `PANEL_IP` пустой или некорректный, применение правил прерывается, чтобы не отрезать панель случайным предположением.

```bash
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh panel-set 203.0.113.10
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh protect-status
```

## TSPU / GOV snapshots

Списки больше не скачиваются из изменяемой ветки `main`.

Текущие snapshots закреплены одновременно на commit SHA и Git blob SHA:

```text
TSPU: tread-lightly/CyberOK_Skipa_ips
      commit a465e13f4cb43c1692eb650430eb857900558c5d

GOV : C24Be/AS_Network_List
      commit 0e999cd730c4d6ca3d58053407a22f63f2d464e6
```

Перед загрузкой в `ipset` файл проходит проверку Git blob SHA и санитизацию CIDR. Ошибка скачивания, несоответствие digest или пустой результат не должны заменять последний рабочий набор.

Это осознанный trade-off: timer **не получает новые адреса автоматически из чужого mutable source**. Чтобы обновить данные, сначала нужно просмотреть upstream diff, затем изменить commit/blob pins в репозитории и пройти CI/review.

## GeoIP allow-list

GeoIP по умолчанию выключен.

При включении данные берутся из `ipverse/country-ip-blocks` на закреплённом commit:

```text
6e3f7978b0391935e306060b11beba774fc7f624
```

Обновление выполняется all-or-nothing: если хотя бы одна запрошенная страна не скачалась или итоговый набор выглядит подозрительно маленьким, существующий `countries.txt` сохраняется и firewall продолжает использовать последний рабочий набор.

GeoIP — allow-list: после ACCEPT для выбранных стран защищаемые порты получают default DROP. Поэтому включайте его только после проверки списка стран и доступа к серверу.

## Порядок правил

```text
PANEL_IP -> 2222 ACCEPT
others   -> 2222 DROP
manual allow
manual deny
TSPU DROP (если включён)
GOV DROP  (если включён)
GeoIP country ACCEPT + default DROP (если включён)
RETURN
```

IPv6 Node API закрывается отдельной цепочкой.

## Systemd

```text
remna-protection.service
remna-protection-update.service
remna-protection-update.timer
```

Timer повторно проверяет и загружает **закреплённые** snapshots раз в неделю:

```text
OnCalendar=Sun *-*-* 03:00:00
Persistent=true
RandomizedDelaySec=15m
```

Это проверка доступности/целостности закреплённых данных, а не доверие свежему `main`.

## Проверка

```bash
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh protect-status
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh protect-selftest
sudo iptables -S REMNA_GUARD
sudo ufw status numbered
```

Ожидаемый порядок для TCP/2222:

```text
-A REMNA_GUARD -s <PANEL_IP> -p tcp --dport 2222 -j ACCEPT
-A REMNA_GUARD -p tcp --dport 2222 -j DROP
```

Блокировки TSPU/GOV/GeoIP/scanner остаются **только TCP** и только на `FILTER_PORTS`. UDP/443 Hysteria2 этими правилами не режется.

## Backend

По умолчанию `BACKEND=iptables`: цепочки и ipset, в том числе когда системный iptables — это iptables-nft. Это один backend, а не смесь.

`BACKEND=nftables` строит только таблицу `inet remna_security`. Preflight и apply отказывают, если активен UFW или видны цепочки Docker: нативный input hook с policy accept оборвал бы чужой filter. Автопереключения нет. Команда явная:

```bash
sudo protection-manager.sh backend-switch nftables --confirm
```

На обычной ноде с Docker остаётся iptables+ipset.

## Источники

Закреплённые TSPU/GOV/GeoIP те же commit+blob, что и раньше. Быстрый scanner feed выключен (`ENABLE_SCANNERS=0`), пока не задан `SCANNER_URL=https://...`. Для него нет pin, но есть тот же конвейер: не HTML, не пусто, валидные CIDR, отказ от prefix короче /8 и от `0.0.0.0/0`, отказ от скачка размера относительно last-known-good, вычитание сетей, которые пересекают `PANEL_IP` или allow. Любой сбой оставляет последний успешный набор.

Динамических IPv6-списков нет: pinned и fast источники здесь IPv4. IPv6 закрывает только TCP/2222 через `REMNA_GUARD6` (или nftables `ip6`). Ручные IPv6 allow/deny применяет nftables backend.

## JSON

Для AINOC, без разбора человеческого текста:

```bash
protection-manager.sh status --json
protection-manager.sh preflight --json
protection-manager.sh update --json
protection-manager.sh selftest --json
```

Схемы: `remna-security.status.v1`, `remna-security.preflight.v1`, `remna-security.update.v1`, `remna-security.selftest.v1`.

## Откат

Перед изменением настроек или фида пишется снимок `/opt/remna-protection/rollback/<id>/`. `rollback` восстанавливает последний снимок и заново применяет только owned ruleset. Неуспешный apply делает это сам.

`migrate-inplace` добавляет новые ключи в старый `settings.conf` и копирует непустые списки в `data/lkg/`, не переключая backend.
