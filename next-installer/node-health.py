#!/usr/bin/env python3
"""Bounded local checks. Never print command output, configuration or secrets."""
import argparse
import copy
import datetime
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile

BASE = Path('/opt/remnanode')
PROFILES = {'xhttp': 'xhttp-reality.json', 'raw': 'raw-reality.json',
            'hysteria': 'hysteria2-tls.json', 'combined': 'xhttp-hysteria2.json'}


def capture(*args):
    result = subprocess.run(args, capture_output=True, text=True, timeout=8)
    if result.returncode:
        raise ValueError('command failed')
    return result.stdout.strip()


def public_inbounds(config):
    items = config.get('inbounds', [])
    if not isinstance(items, list):
        raise ValueError('invalid inbounds')
    return [x for x in items if x.get('protocol') in ('vless', 'hysteria')]


def normalize(inbound):
    item = copy.deepcopy(inbound)
    item.pop('tag', None)
    item.setdefault('settings', {})['clients'] = []
    if item.get('sniffing', {}).get('metadataOnly') is False:
        item['sniffing'].pop('metadataOnly')
    return item


def same_profile(expected, actual):
    def normalized(config):
        return sorted(json.dumps(normalize(x), sort_keys=True) for x in public_inbounds(config))
    return bool(public_inbounds(expected)) and normalized(expected) == normalized(actual)


def check(base=BASE):
    rows = []
    def row(label, status, detail):
        rows.append({'component': label, 'status': status, 'detail': detail})
    def probe(label, fn, failure, severity='FAIL'):
        try:
            row(label, 'PASS', fn())
        except (OSError, ValueError, KeyError, IndexError, TypeError, AttributeError, subprocess.SubprocessError):
            row(label, severity, failure)

    def container(name):
        state = json.loads(capture('docker', 'inspect', '-f', '{{json .State}}', name))
        if not state.get('Running') or state.get('Health', {}).get('Status') == 'unhealthy':
            raise ValueError('not healthy')
        return 'Запущен; это не проверка клиентского подключения'
    probe('Remnanode', lambda: container('remnanode'), 'Контейнер недоступен / остановлен / unhealthy')
    probe('nginx', lambda: container('remnawave-nginx'), 'Контейнер недоступен / остановлен / unhealthy')
    def nginx():
        capture('docker', 'exec', 'remnawave-nginx', 'nginx', '-t')
        if not stat.S_ISSOCK(Path('/dev/shm/nginx.sock').stat().st_mode):
            raise ValueError('socket absent')
        return 'Конфигурация принята; Unix-сокет существует'
    probe('SelfSteal', nginx, 'Конфигурация nginx / Unix-сокет не подтверждены')

    expected = None
    try:
        transport = (base / '.transport').read_text().strip()
        expected = json.loads((base / 'remnawave-profiles' / PROFILES[transport]).read_text())
        if not public_inbounds(expected) or any(not 1 <= int(x['port']) <= 65535 for x in public_inbounds(expected)):
            raise ValueError('empty profile')
        row('Локальный профиль', 'PASS', transport)
    except (OSError, ValueError, KeyError, IndexError, TypeError, AttributeError):
        expected = None
        row('Локальный профиль', 'FAIL', 'Transport / JSON отсутствует или повреждён')
    actual = None
    try:
        actual = json.loads(capture('docker', 'exec', 'remnanode', 'cli', '--dump-config-raw'))
        if not isinstance(actual, dict):
            raise ValueError('not object')
        if expected is not None:
            if not public_inbounds(actual):
                row('Активный профиль', 'WAIT', 'Нет VLESS/Hysteria inbound: примените профиль в панели')
            elif not same_profile(expected, actual):
                row('Активный профиль', 'FAIL', 'Runtime отличается от локального профиля; проверьте профиль панели')
            else:
                row('Активный профиль', 'PASS', 'Inbounds совпадают; динамические clients и tag исключены')
        def auth():
            for inbound in public_inbounds(actual):
                if inbound.get('protocol') == 'hysteria':
                    for client in inbound.get('settings', {}).get('clients', []):
                        if not client.get('id') or client.get('auth') != client['id']:
                            raise ValueError('bad auth')
            return 'Hysteria auth/id проверены; значения скрыты'
        if any(x.get('protocol') == 'hysteria' for x in public_inbounds(actual)):
            probe('Hysteria auth', auth, 'Обнаружено расхождение auth/id')
    except (OSError, ValueError, KeyError, IndexError, TypeError, AttributeError, subprocess.SubprocessError):
        actual = None
        row('Активный профиль', 'FAIL', 'Не удалось прочитать runtime; наличие свободного порта не доказывает готовность')

    if expected is not None:
        for network, flag in [('tcp', '-lnt'), ('udp', '-lnu')]:
            ports = sorted({int(x['port']) for x in public_inbounds(expected)
                            if ('udp' if x.get('protocol') == 'hysteria' else 'tcp') == network})
            for port in ports:
                def listener(flag=flag, port=port):
                    if not capture('ss', '-H', flag, f'sport = :{port}'):
                        raise ValueError('no listener')
                    return 'Listener найден; внешний доступ проверяется отдельно'
                probe(f'{network.upper()}/{port}', listener, 'Listener отсутствует',
                      'WAIT' if actual is not None and not public_inbounds(actual) else 'FAIL')
        if any(x.get('protocol') == 'hysteria' for x in public_inbounds(expected)):
            def cert():
                path = base / 'certs/fullchain.pem'
                capture('openssl', 'x509', '-in', str(path), '-noout', '-checkend', '0')
                domain = (base / '.node_domain').read_text().strip()
                if not domain:
                    raise ValueError('no domain')
                # openssl checkhost may return success even for a mismatch on older versions.
                output = capture('openssl', 'x509', '-in', str(path), '-noout', '-checkhost', domain)
                if 'does match certificate' not in output:
                    raise ValueError('name mismatch')
                return 'Срок и имя домена проверены; цепочка доверия не проверялась'
            probe('Сертификат Hysteria', cert, 'Сертификат истёк / отсутствует / имя не совпадает')

    def api():
        # Read only NODE_PORT; never pass environment or keys to diagnostics.
        ports = [line.split('=', 1)[1].strip().strip('"').strip("'")
                 for line in (base / '.env').read_text().splitlines() if line.startswith('NODE_PORT=')]
        port = int(ports[0])
        if not 1 <= port <= 65535 or not capture('ss', '-H', '-lnt', f'sport = :{port}'):
            raise ValueError('no API listener')
        return 'Listener найден; mTLS и ограничение IP панели требуют отдельной проверки'
    probe('API ноды', api, 'NODE_PORT / API listener не подтверждён')
    def secrets():
        paths = [base / '.env']
        if expected is not None:
            paths.append(base / 'remnawave-profiles' / PROFILES[transport])
        for path in paths:
            info = path.stat()
            if info.st_uid != 0 or stat.S_IMODE(info.st_mode) & 0o077:
                raise ValueError('unsafe permissions')
        return 'Проверенные env/profile доступны только root'
    probe('Секретные файлы', secrets, 'Права env/profile не подтверждены', 'WARN')

    def nofile():
        values = capture('docker', 'exec', 'remnanode', 'sh', '-c',
                         'printf "%s %s" "$(ulimit -Sn)" "$(ulimit -Hn)"').split()
        if len(values) != 2:
            raise ValueError('invalid limits')
        if any(v != 'unlimited' and int(v) < 65536 for v in values):
            raise ValueError('low limits')
        return 'Фактические soft/hard не ниже 65536'
    probe('NOFILE', nofile, 'Лимиты не подтверждены / ниже 65536', 'WARN')
    def network():
        cc = capture('sysctl', '-n', 'net.ipv4.tcp_congestion_control')
        qdisc = capture('sysctl', '-n', 'net.core.default_qdisc')
        if cc != 'bbr' or qdisc not in ('fq', 'fq_codel'):
            raise ValueError('tuning drift')
        return f'{cc} / {qdisc}; TCP, не QUIC congestion control'
    probe('Сеть', network, 'BBR/qdisc не подтверждены', 'WARN')
    def rkn():
        capture('iptables', '-C', 'INPUT', '-j', 'REMNA_RKN_SCANNERS')
        rules = capture('iptables', '-S', 'REMNA_RKN_SCANNERS')
        if not all(any('-j DROP' in line and f'-p {proto}' in line and '443' in line
                       for line in rules.splitlines()) for proto in ('tcp', 'udp')):
            raise ValueError('missing guard rules')
        return 'INPUT jump и TCP/UDP 443 DROP-правила найдены'
    probe('RKN SAFE', rkn, 'SAFE chain не подтверждён; другой backend проверяйте через protection status', 'WARN')
    row('Панель / внешний клиент', 'UNKNOWN', 'mTLS-связь, внешний доступ и VPN-сессия локально не проверяются')
    statuses = {x['status'] for x in rows}
    result = 'FAIL' if 'FAIL' in statuses else 'WAIT' if 'WAIT' in statuses else 'WARN' if 'WARN' in statuses else 'PASS'
    return {'schema': 'remnanode-health-v1', 'time': datetime.datetime.now(datetime.timezone.utc).isoformat(),
            'result': result, 'checks': rows}


def record(report):
    directory = Path('/var/lib/remnanode-next/health')
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temporary = tempfile.mkstemp(dir=directory)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(report, stream, ensure_ascii=False, indent=2)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, directory / 'post-reboot.json')
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--json', action='store_true')
    parser.add_argument('--record', action='store_true', help='save the post-reboot report only')
    args = parser.parse_args()
    report = check()
    if args.record:
        record(report)
    if args.json:
        print(json.dumps(report, ensure_ascii=False))
    else:
        for item in report['checks']:
            print(f"[{item['status']}] {item['component']}: {item['detail']}")
        print(f"ИТОГ: {report['result']} — локальные проверки; внешний VPN-доступ не подтверждён")
    return {'PASS': 0, 'WARN': 3, 'WAIT': 2, 'FAIL': 1}[report['result']]


if __name__ == '__main__':
    raise SystemExit(main())
