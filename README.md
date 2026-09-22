# Remna Node Scripts

Главный installer этого репозитория — **REMNANODE NEXT**.

NEXT восстановлен из source snapshot реально работающей ноды и снова является основной цепочкой установки. Старый Caddy-based manager оставлен только для обслуживания legacy-нод и **не вызывается** из `install.sh`, `clean-install.sh` или `full-clean-reinstall.sh`.

## Что умеет NEXT

- Remnawave Node + `remnawave-nginx`;
- SelfSteal через общий `/dev/shm/nginx.sock`;
- VLESS + REALITY + XHTTP на TCP/443;
- VLESS + REALITY + RAW на TCP/443;
- Hysteria2 + TLS на UDP/443;
- комбинированный профиль **XHTTP + Hysteria2**: TCP/443 + UDP/443;
- генерация Config Profile и Host для Remnawave;
- стабильная per-node XHTTP signature;
- RKN SAFE scanner guard с rollback и self-heal — **ставится автоматически по умолчанию**;
- runtime repair для Hysteria cert mount / RKN;
- маскировочный SelfSteal-сайт;
- BBR TUNE (SAFE/HIGHLOAD, без замены ядра) — **ставится автоматически по умолчанию**;
- безопасный backup / clean / reinstall без глобального `ufw reset`;
- **NEXT V2 для существующей/legacy-ноды**: recovery backup → адресная зачистка старых Remnanode/Caddy/Hysteria/RKN хвостов → свежая установка NEXT.

## Быстрая установка

Новая нода:

```bash
curl -fsSL --proto '=https' --tlsv1.2 \
  https://raw.githubusercontent.com/evgmahov-blip/remna-node-scripts/b3779b0bcf9e50d6423478cb29fbc8f57f1c4d2f/install.sh \
  -o /tmp/remna-install.sh

sudo bash /tmp/remna-install.sh
```

Существующая/старая нода — **NEXT V2 migration**:

```bash
curl -fsSL --proto '=https' --tlsv1.2 \
  https://raw.githubusercontent.com/evgmahov-blip/remna-node-scripts/93c28cc0489c03beb9c32ea0573bca774be7c652/clean-install.sh \
  -o /tmp/remna-clean-install.sh

sudo bash /tmp/remna-clean-install.sh
```

`clean-install.sh` теперь снова означает старый сценарий **V2 для существующей ноды**, а не обычный reinstall текущего NEXT: он сразу делает preflight, recovery backup, вычищает известные legacy-хвосты и только после успешного postcheck запускает свежую установку. Дополнительное подтверждение `MIGRATE` не требуется: сам запуск `clean-install.sh` считается подтверждением миграции.

Обе команды используют immutable commit SHA. Следующий launcher проверяется по Git blob SHA; recovered NEXT source bundle — по immutable commit + Git blob SHA, а каждый входящий в него скрипт дополнительно проверяется по SHA256.

## Главное меню

После первой синхронизации:

```bash
sudo remnanode-next
```

Меню:

```text
REMNANODE NEXT — MAIN
REPO: https://github.com/evgmahov-blip/remna-node-scripts
CLI:  sudo remnanode-next

 [1]  Установка / продолжить настройку NEXT
 [2]  Транспорт / профили (XHTTP / RAW / Hysteria2 / combined)
 [3]  Config Profile + НАСТРОЙКИ HOST REMNAWAVE
 [4]  SelfSteal / маскировочный сайт
 [5]  XHTTP signature
 [6]  РКН защита — SAFE scanner guard (DEFAULT)
 [7]  Runtime repair / guards
 [8]  Базовое управление Remnanode
 [9]  Статус
 [10] Safe clean текущей NEXT-ноды
 [11] Safe reinstall текущей NEXT-ноды
 [12] NEXT V2 — существующая/legacy нода → очистка хвостов → NEXT

 [13] СЕТЬ / BBR TUNE (DEFAULT) / BBR3 (OPTIONAL)
 [14] HYSTERIA2 DIAG — UDP/443 + DNS + RKN counters
      RUN:    sudo remnanode-next hysteria-diag

      NETWORK: sudo remnanode-next network
      TUNE:   https://github.com/Balbuto/safe-remnanode-setup
      BBR3:   https://github.com/ivan-nginx/bbr3

 [0]  Выход
```

RKN снова находится непосредственно в основном меню NEXT.

## Транспортные профили

Пункт 2 использует восстановленный `remnawave-transport-manager.sh`:

```text
1) VLESS + REALITY + XHTTP (основной)
2) VLESS + REALITY + RAW (fallback)
3) Hysteria2 + TLS (UDP)
4) XHTTP + Hysteria2 одновременно (TCP/443 + UDP/443)
```

Профили сохраняются в:

```text
/opt/remnanode/remnawave-profiles/xhttp-reality.json
/opt/remnanode/remnawave-profiles/raw-reality.json
/opt/remnanode/remnawave-profiles/hysteria2-tls.json
/opt/remnanode/remnawave-profiles/xhttp-hysteria2.json
```

Пункт 3 основного меню теперь показывает **и Config Profile, и настройки Host**:

```text
[1] XHTTP + REALITY
    → JSON Config Profile + HOST XHTTP

[2] RAW + REALITY
    → JSON Config Profile + HOST RAW

[3] Hysteria2 + TLS
    → JSON Config Profile + HOST HYSTERIA2

[4] XHTTP + Hysteria2
    → JSON Config Profile + HOST XHTTP + HOST HYSTERIA2

[5] ТОЛЬКО HOST XHTTP
[6] ТОЛЬКО HOST HYSTERIA2
[7] ТОЛЬКО HOST RAW
```

Для Hysteria2 в Host выводятся как минимум:

```text
Address: <node-domain>
Port: 443
Transport: Hysteria2 / UDP
Security Layer: DEFAULT
SNI: <node-domain>
Take SNI from address: ON
ALPN: h3
Auth: автоматически = UUID пользователя Remnawave
Vless Route ID: ПУСТО / DEFAULT
Xray JSON Template override: DEFAULT / пусто
Mapper: ПУСТО / DEFAULT
Final Mask: ПУСТО / DEFAULT
```

Быстрые команды без меню:

```bash
sudo remnanode-next host-xhttp
sudo remnanode-next host-hysteria2
sudo remnanode-next host-raw
```

После завершения установки NEXT дополнительно спрашивает:

```text
ПОКАЗАТЬ ГОТОВЫЙ ПРОФИЛЬ / ПРОФИЛИ ДЛЯ КОПИПАСТЫ? [Y/n]:
```

Если ответить `Y` или просто Enter, сразу выводятся текущий Config Profile и Host settings. Позже тот же текущий профиль можно вывести одной командой:

```bash
sudo remnanode-next current-profile
```

JSON XHTTP/REALITY содержит private key — не публикуйте его.

### Hysteria2: нормальный Remnawave/Xray профиль

Hysteria2 profile собран из трёх источников: восстановленного NEXT generator, реально сгенерированного Remnawave profile и проверенного рабочего Hysteria2 inbound.

В Remnawave оставляется только то, что нужно Xray и панели:

- `protocol: hysteria`;
- `settings.clients: []` — Remnawave сам добавляет пользователей и `auth`;
- `settings.version: 2`;
- `sniffing.enabled: true`;
- `sniffing.destOverride: [http, tls, quic]`;
- `sniffing.routeOnly: true`;
- `network: hysteria`;
- `security: tls`;
- `hysteriaSettings.version: 2`;
- `hysteriaSettings.udpIdleTimeout: 60`;
- TLS `minVersion: 1.2`, `maxVersion: 1.3`;
- `rejectUnknownSni: true`;
- `enableSessionResumption: true`;
- ALPN `h3`;
- сертификат и ключ из `/etc/xray/certs`.

По умолчанию **не добавляются**:

- `settings.users` — Remnawave использует `clients`;
- server-side `finalmask` — Hysteria и без него использует свой штатный congestion control;
- `masquerade` — он не нужен для рабочего authenticated Hysteria2 и только усложняет профиль;
- `hysteriaSettings.auth` — auth добавляет Remnawave per-user.

Host Hysteria2:

```text
Address: <node-domain>
Port: 443
Transport: Hysteria2 / UDP
Security Layer: DEFAULT
SNI: <node-domain>
Take SNI from address: ON
ALPN: h3
Auth: автоматически = UUID пользователя Remnawave
Vless Route ID: ПУСТО / DEFAULT
Xray JSON Template override: DEFAULT / пусто
Mapper: ПУСТО / DEFAULT
Final Mask: ПУСТО / DEFAULT
```

### Мульти-тесты сервера

В NEXT встроен отдельный tester-модуль, адаптированный из **Module D** проекта `Balbuto/safe-remnanode-setup` (source commit `274d84d9daa3b4d4a33264ba77992210aedd9b32`, source script blob `58a85a9baa4f36648d6587c5d6c4ac347096963d`). Upstream указывает, что модуль актуализирован по `saveksme/multitest v1.1`.

Запуск:

```bash
sudo remnanode-next multitest
sudo remnanode-next multitest all
sudo remnanode-next multitest 1
sudo remnanode-next multitest 12
```

Тесты:

```text
 1  IP Region / геолокация
 2  Censorcheck — геоблок
 3  Censorcheck — DPI
 4  iPerf3 — RU сервера
 5  YABS — disk fio only
 6  Geo/Media Unlock — RegionRestrictionCheck
 7  IPQuality — ASN / risk / blacklist / media / mail
 8  sysbench CPU
 9  Network Bench — HTTPS 100MB
10  NextTrace Route/MTR — loss/jitter/ASN/geo
11  NextTrace Path MTU — UDP PMTU
12  NextTrace Globalping — внешние TCP/443 точки → эта нода
99  все тесты автоматически
```

В режиме `99/all` **ничего дополнительно нажимать не нужно**: после выбора режима все тесты запускаются автоматически один за другим. Ctrl+C во время конкретного теста прерывает только его и переводит к следующему. В конце выводится PASS/FAIL/SKIP/TOTAL.

Каждый полный прогон автоматически сохраняется в `/var/log/remnanode-next/multitest/<UTC-run-id>/`:

- `summary.tsv` — test/name/status/duration/rc;
- отдельный `*.log` для каждого теста;
- `analysis.txt` — локальная детерминированная выжимка;
- `AI_REPORT.txt` — компактный отчёт для дальнейшего анализа в ChatGPT/другой модели;
- `latest.path` указывает на последний прогон.

Команды:

```bash
sudo remnanode-next multitest analyze
sudo remnanode-next multitest report
```

`analyze` повторно строит и показывает анализ последнего прогона. `report` показывает каталог и пути к `analysis.txt`, `AI_REPORT.txt` и raw logs. В меню также есть пункт `98) Анализ последнего прогона`.

Локальный анализ намеренно осторожный: он выделяет FAIL/timeout, длительность, Cloudflare throughput и ключевые строки из geo/IP-quality/fio/CPU/MTR/PMTU/Globalping. FAIL означает ошибку/timeout теста, а не автоматически плохую ноду; geo/risk базы и скорости нужно оценивать вместе.

Tester не меняет firewall, sysctl, Docker или конфигурацию Remnawave. Он может доустановить только утилиту, необходимую выбранному тесту (`iperf3`, `sysbench`, `traceroute`, `jq` и т.п.).

После отдельного аудита tester дополнительно исправлен:

- upstream YABS больше не запускается с `-4`: у YABS этот флаг означает **Geekbench 4**, а не IPv4;
- в составе REMNANODE multitest YABS запускается с `-ign`: остаётся только fio disk I/O; iperf, Geekbench и network-info отключены, потому что сеть/CPU проверяются отдельными тестами; hard timeout — 420 секунд;
- Censorcheck заранее получает обязательные `dig/jq/column`;
- iPerf3 RU заранее получает `iperf3/jq/ping/awk/timeout`;
- дублирующий IP-quality пункт заменён на `RegionRestrictionCheck` для geo/media unlock;
- ошибки выбранных тестов больше не скрываются через `|| true`; режим `99/all` показывает PASS/FAIL/SKIP;
- удалены дублирующие/низкоценные пункты: второй iPerf (bench.tlab), sysbench Memory, TLS к google.com, обычные traceroute/ping;
- Network Bench выводит Mbit/s и использует только HTTPS; для Cloudflare 100MB отправляется официальный `Referer: https://speed.cloudflare.com/`, а при отказе 100MB автоматически пробуется 50MB fallback;
- CPU-тест теперь показывает и single-thread, и all-thread (`nproc`) результат — это нужно для оценки реальной ёмкости XHTTP/Remnawave;
- анализ iPerf понимает текущий формат `itdoginfo/russian-iperf3-servers` с колонками Server/Download/Upload/Ping и значениями в Mbps;
- добавлен официальный **NextTrace v1.7.3**: Route/MTR, Path MTU и Globalping;
- NextTrace не добавляет внешний APT repository: full binary скачивается из официального GitHub release, проверяется закреплённым SHA256 и кешируется вне PATH;
- NextTrace MTR проверяет TCP/443 с 10 пробами на hop и показывает loss/jitter/ASN/geo;
- Path MTU делает отдельный UDP PMTU discovery;
- Globalping запускает внешние TCP/443 traceroute к домену ноды из Europe, North America и Asia; target берётся из `/opt/remnanode/.node_domain` или `NODE_TEST_TARGET`.

GitHub-hosted entry scripts Censorcheck, RU iPerf3, YABS, RegionRestrictionCheck и IPQuality закреплены конкретными commit + Git blob SHA и проверяются перед запуском. Некоторые сами тестеры после старта обращаются к собственным внешним API/data-файлам, поэтому pin entry script не означает pin всех сетевых данных.

NextTrace закреплён отдельно: release `v1.7.3`, SHA256 для Linux amd64 `aa75440fcdee46c16d941f48f9dabee1eb4c35bea6b739b0960fcf8307088c29`, для Linux arm64 `4fbf436e2d4737e4a491e71ce3cd140a7a268d43ec94fb9ac9497aec7eda080e`. Globalping допускает anonymous quota upstream; при наличии `GLOBALPING_TOKEN` NextTrace использует его автоматически.

Быстрая диагностика Hysteria2:

```bash
sudo remnanode-next hysteria-diag
```

Команда read-only: она не синхронизирует файлы и ничего не меняет. Она показывает UDP/443 listener, DNS адреса, counters RKN scanner guard и читает фактический Remnawave runtime через `docker exec remnanode cli --dump-config-raw`.

Runtime guard проверяет Hysteria2 version/network/TLS/sniffing, отсутствие server-side `masquerade` и `finalmask`, совпадение `auth == id` без вывода UUID, а также семантически сравнивает активный runtime с локальным `remnawave-profiles/hysteria2-tls.json`. Из сравнения исключаются только динамические `clients`, tag и `metadataOnly=false`. При drift команда завершается с FAIL/non-zero и прямо указывает, что активный Config Profile/Host Remnawave расходится с NEXT.

Для Host Hysteria2 `Vless Route ID` должен быть пустым/default: ненулевое значение меняет Hysteria auth в клиентском конфиге, тогда как Node принимает исходный UUID пользователя.

Если runtime PASS, UDP/443 слушает, но DROP counter растёт именно во время попытки через LTE, проблема уже не в Config Profile, а в firewall/RKN path для IP мобильного оператора.

## Рабочая архитектура

```text
                       rw-core

TCP/443  ───────► XHTTP + REALITY
                       │
                       │ target=/dev/shm/nginx.sock
                       ▼
                 remnawave-nginx
                 SelfSteal / mask

UDP/443  ───────► Hysteria2 + TLS/QUIC
```

Remnanode и Nginx используют общий `/dev/shm`. Это та схема, которая была снята с рабочей NEXT-ноды.

**Отдельный Caddy → 127.0.0.1:7443 pipeline не является основной NEXT-архитектурой.**

## RKN SAFE

Пункт 6:

```text
RKN WATCHER — SAFE SCANNER MODE

1) Установить / обновить SAFE scanner protection
2) Активировать / пере-применить guard с rollback 120 сек
3) Обновить scanner lists сейчас
4) Статус
5) ADVANCED upstream menu
6) Полностью удалить RKN Watcher
0) Назад
```

SAFE guard защищает TCP/80, TCP/443 и UDP/443 от известных scanner IP. При активации используется rollback и last-good проверка, чтобы не заменить рабочий набор повреждённым.

## VLESS/XHTTP client: `vnext should have one and only one member`

Эта ошибка относится **не к server Config Profile**, а к уже сгенерированному Remnawave клиентскому outbound.

NEXT Config Profile содержит server inbound с `settings.clients: []` и сам по себе не содержит `vnext`. Актуальный Remnawave Xray JSON generator для обычного VLESS Host создаёт один endpoint в `settings.vnext`. После этого Remnawave применяет Host → Mapper.

Поэтому для XHTTP/RAW Host, создаваемого из NEXT profile:

- **Xray JSON Template override: DEFAULT / пусто**;
- **Mapper: пусто**;
- не должно быть mapper-операций, которые меняют `settings.vnext` или `settings.vnext.*`;
- итоговый VLESS outbound должен иметь **ровно один** элемент `settings.vnext`.

Если Xray пишет:

```text
VLESS settings: "vnext" should have one and only one member
```

сначала очистите Mapper именно у проблемного Host в Remnawave и заново обновите подписку/клиентский JSON.

Генерируемый `host-xhttp.txt` и вывод transport manager теперь явно содержат этот guard.

## СЕТЬ / BBR TUNE / BBR3

В главном меню есть отдельный пункт **13**, а открыть его напрямую можно одной командой:

```bash
sudo remnanode-next network
```

Внутри прямо показаны ссылки и быстрые команды:

```text
[2] BBR TUNE — SAFE/HIGHLOAD, БЕЗ ЗАМЕНЫ ЯДРА
    SOURCE: https://github.com/Balbuto/safe-remnanode-setup
    RUN:    sudo remnanode-next bbr-tune

[3] BBR3 — КАСТОМНОЕ ЯДРО, НУЖЕН REBOOT
    SOURCE: https://github.com/ivan-nginx/bbr3
    RUN:    sudo remnanode-next bbr3
```

**BBR TUNE теперь включается автоматически при обычной установке и при NEXT V2 migration**, так же как RKN SAFE scanner guard. Он оставляет текущее ядро, включает BBR + `fq` и автоматически выбирает SAFE/HIGHLOAD по RAM. Повторный запуск идемпотентен: если профиль уже активен, он не переустанавливается.

**BBR3 не ставится автоматически**: он меняет kernel package и требует reboot. Installer закреплён по immutable commit + Git blob SHA. В контейнерах/LXC/OpenVZ BBR3-установка блокируется.

Важно: Hysteria2 использует QUIC и собственный штатный congestion control; отдельный server-side `finalmask` для него теперь не навязывается. TCP BBR/BBR3 не заменяет QUIC congestion control Hysteria2 и в первую очередь влияет на TCP/XHTTP и общую host-side сетевую очередь.

Быстрые команды:

```bash
sudo remnanode-next network-status
sudo remnanode-next bbr-tune
sudo remnanode-next bbr3
```

Источники:
- BBR3: https://github.com/ivan-nginx/bbr3
- BBR tune / SAFE-HIGHLOAD: https://github.com/Balbuto/safe-remnanode-setup

## Два сценария очистки / переустановки

### Текущий NEXT → текущий NEXT

Пункты 10/11 предназначены для уже установленной актуальной NEXT-ноды. Они делают backup текущего NEXT state и удаляют только управляемый NEXT stack.

### Существующая/legacy нода → NEXT V2

Пункт 12 и `clean-install.sh` восстанавливают потерянный сценарий старого `REMNA NODE FULL CLEAN + NEXT V2`.

Перед установкой V2:

1. проверяет активный SSH/sshd и default route;
2. создаёт recovery bundle в `/root/remna-node-v2-backups/`;
3. адресно удаляет старые Remna/RKN systemd units;
4. адресно удаляет старые `REMNA_GUARD`, `REMNA_RKN_SCANNERS`, `TSPUIPS` и известные Remna ipset;
5. удаляет только контейнеры `remnanode` / `remnawave-nginx` и `/opt/remnanode`;
6. убирает legacy Caddy node-конфиги/topology guard и `/var/www/mstream`, но сохраняет пакет Caddy и его ACME cache;
7. убирает standalone `/etc/hysteria`, `/etc/hysteria2`, `/opt/remna-hysteria`;
8. убирает старые Caddy/protection/RKN helper-файлы из `/opt/remna-node-scripts`;
9. делает postcheck: SSH/сеть должны остаться живы, старые node listeners/chains не должны остаться;
10. только после PASS запускает свежую установку NEXT.

V2 **не делает глобальный `ufw reset`**, не удаляет Docker как пакет, не меняет SSH, hostname, DNS/default route и не удаляет чужие Docker-контейнеры.

## Safe clean / reinstall

Top-level NEXT manager **не вызывает legacy uninstall** для обычного NEXT clean/reinstall, потому что старый uninstall умеет делать глобальный `ufw reset`.

Перед clean/reinstall сохраняются важные настройки, профили, сертификаты и секреты в root-only backup:

```text
/root/remnanode-next-backup-YYYYMMDD-HHMMSS.tar.gz
```

Удаляются только известные компоненты текущей Remnanode/NEXT установки. Docker как пакет, SSH, DNS, default route и чужие контейнеры не удаляются.

## Восстановленный source snapshot

Source NEXT хранится внутри этого репозитория:

```text
vendor/remna-next-source.tar.gz
```

Манифест и контрольные суммы:

```text
NEXT_SOURCE_MANIFEST.md
```

В bundle входят:

```text
next-installer/setup_node-legacy.sh
next-installer/remnawave-transport-manager.sh
next-installer/selfsteal-site-manager.sh
next-installer/rkn-watcher-manager.sh
next-installer/next-runtime-guards.sh
next-installer/xhttp-signature-manager.sh
```

В recovered bundle байт-в-байт сохранены также `docker-compose.yml` и `nginx.conf` с рабочей ноды как эталон архитектуры. Installer их из bundle **не устанавливает**: для runtime используются штатные NEXT-функции. `.env`, сертификаты и приватные ключи в bundle отсутствуют.

### Известный хвост recovered snapshot

В восстановленном SelfSteal manager режим STREAM всё ещё содержит pinned URL старого `setup-remna-node`, который сейчас недоступен через GitHub. Свежая установка по умолчанию использует RANDOM/template SelfSteal и от этого URL не зависит. STREAM нужно отдельно перевендорить из рабочей копии сайта; это не причина возвращать legacy Caddy-manager в основную цепочку.

## Legacy Caddy manager

Эти файлы сохранены только для старых нод:

```text
install-caddy-node-reality-stream.sh
install-caddy-node-reality-stream-core.sh
caddy-resilient-start.sh
protection-manager.sh
```

Они **не являются main installer**.

## История восстановления

Последний корректный main до архитектурной ошибки: `cf8c8f5910b1bbd56364b99a457f2b999c743119`.

В `42d7d662c1f11b4705c8bfba3c74839ce98d669a` launcher был ошибочно переключён с NEXT на legacy Caddy-manager. Текущая ветка восстанавливает исходную роль NEXT, но хранит recovered source внутри этого репозитория, чтобы больше не зависеть от исчезнувшего внешнего `setup-remna-node`.
