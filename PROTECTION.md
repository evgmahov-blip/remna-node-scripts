# Защита Remna Node

Модуль `protection-manager.sh` управляет отдельными цепочками `REMNA_GUARD` / `REMNA_GUARD6`. Он не выполняет `ufw reset`, не очищает пользовательский `INPUT` и не удаляет посторонние firewall-правила.

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
