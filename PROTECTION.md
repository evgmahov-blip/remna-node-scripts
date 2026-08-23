# Защита Remna Node

Модуль `protection-manager.sh` встроен в основное меню `install-caddy-node-reality-stream.sh`.

Он использует отдельные цепочки `REMNA_GUARD` / `REMNA_GUARD6` и не выполняет `ufw reset`, не очищает пользовательский `INPUT` и не удаляет чужие firewall-правила.

## TCP/2222 — только сервер панели

`remnanode` слушает Node API на `*:2222`, но внешний доступ к этому порту должен быть разрешён только серверу Remnawave Panel.

После указания `PANEL_IP` применяется схема:

```text
src = PANEL_IP -> tcp/2222 ACCEPT
all others     -> tcp/2222 DROP
```

Для IPv6 действует отдельная цепочка. Если панель использует IPv4, входящий IPv6-доступ к `2222` закрывается полностью.

Если UFW активен, модуль также удаляет старое широкое правило `2222/tcp ALLOW Anywhere`, которое могли создать старые версии installer, и добавляет только разрешение от IP панели.

Модуль никогда не угадывает IP панели. Если `PANEL_IP` не задан или некорректен, `apply` отказывается менять firewall, чтобы не отрезать рабочую панель.

Интерактивно:

```bash
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh
# [20] Закрыть TCP/2222 только для IP панели
```

CLI:

```bash
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh panel-set 203.0.113.10
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh protect-status
```

При новой интерактивной установке/repair основной manager сам требует IP панели. Для неинтерактивной установки передайте:

```bash
PANEL_IP=203.0.113.10 EMAIL=... DOMAIN=... SECRET_KEY=... \
  sudo -E /opt/remna-node-scripts/install-caddy-node-reality-stream.sh --auto
```

## RKN/TSPU/GOV watcher

Модуль использует идеи `Balbuto/safe-remnanode-setup` / RKN-Watcher:

- TSPU CIDR list;
- GOV/ASN blacklist;
- `iptables + ipset`;
- атомарное обновление через временный ipset и `swap`;
- сохранение предыдущего рабочего списка при ошибке скачивания;
- systemd boot restore;
- ежедневный `Persistent=true` timer;
- GeoIP allow-страны;
- ручные allow/deny IP/CIDR;
- проверка поддержки `ipset/xt_set`;
- собственные логи и статус.

Источники по умолчанию:

```text
TSPU: tread-lightly/CyberOK_Skipa_ips
GOV : C24Be/AS_Network_List/blacklists_iptables/blacklist-v4.ipset
Geo : ipdeny aggregated country zones
```

GeoIP по умолчанию **выключен**, чтобы установка не могла неожиданно отрезать администратора или пользователей. TSPU/GOV включены.

Защищаемые блок-листами порты по умолчанию:

```text
443,18443,5222,5223,8530
```

`2222` обрабатывается отдельным более строгим правилом panel-only.

## Systemd

```text
remna-protection.service
remna-protection-update.service
remna-protection-update.timer
```

Timer:

```text
OnCalendar=*-*-* 03:00:00
Persistent=true
RandomizedDelaySec=15m
```

## Проверка

```bash
sudo /opt/remna-node-scripts/install-caddy-node-reality-stream.sh protect-status
sudo iptables -S REMNA_GUARD
sudo ufw status numbered
```

Ожидаемый порядок для `2222`:

```text
-A REMNA_GUARD -s <PANEL_IP> -p tcp --dport 2222 -j ACCEPT
-A REMNA_GUARD -p tcp --dport 2222 -j DROP
```

Основная диагностика manager также показывает состояние защиты Node API в секции `[E] Защита / Node API`.
