#!/usr/bin/env bash
# dns.sh — Ubuntu: IP actual -> estática + BIND9 + Nginx + Hola mundo.
# Ejecutar EN EL UBUNTU QUE SERA EL SERVIDOR: sudo bash dns.sh
# Solicita el dominio en la terminal y lo guarda para las siguientes acciones.
# No instala DHCP ni cambia el router. Los clientes deben usar este DNS.
# IMPORTANTE: fijar una IP en Ubuntu NO la reserva en el servidor DHCP.
# Sin reserva/exclusión en DHCP no se puede garantizar que no haya colisiones.
# Es preferible ejecutar desde la consola de la máquina/VM: la red se reactiva.
# VM accesible desde equipos físicos: adaptador puente o una red con rutas a ella.
# Si dnsmasq.service ocupa el DNS de la LAN y solo presta DNS, se respalda
# su estado y se detiene/deshabilita para sustituirlo por BIND9. No se eliminan
# paquetes ni se detienen instancias DHCP/TFTP, de NetworkManager o libvirt.
# Documentación utilizada:
# https://netplan.readthedocs.io/en/stable/netplan-set/
# https://networkmanager.dev/docs/api/latest/nm-settings-nmcli.html
# https://bind9.readthedocs.io/en/stable/reference.html
# https://nginx.org/en/docs/http/ngx_http_core_module.html
# https://thekelleys.org.uk/dnsmasq/docs/dnsmasq-man.html
set -Eeuo pipefail
export LC_ALL=C
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 022

DEFAULT_DOMAIN='midominio.linux'
DOMAIN=''
OLD_DOMAIN=''
OLD_SITE_DIR=''
SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname -- "$SCRIPT_PATH")"
SITE_DIR=''
WEB_ROOT=''
STATE_DIR='/var/lib/dns-midominio'
BACKUP_BASE='/var/backups/dns-midominio'
STATE_FILE="$STATE_DIR/estado.json"
MODE='instalar'
IFACE=''
UPSTREAM_INPUT=''
BACKUP=''
ROLLBACK_UNIT=''
TRANSACTION=0

info() { printf '\n[DNS] %s\n' "$*"; }
warn() { printf '\n[AVISO] %s\n' "$*" >&2; }
die() {
    printf '\n[ERROR] %s\n' "$*" >&2
    if ((TRANSACTION)); then on_error 1; else exit 1; fi
}
need_root() { [[ $EUID -eq 0 ]] || die "Ejecuta: sudo bash \"$SCRIPT_PATH\""; }

usage() {
    cat <<'HELP'
USO
  sudo bash dns.sh                         Instalar y configurar.
  sudo bash dns.sh --interfaz enp0s3        Elegir la tarjeta de la LAN.
  sudo bash dns.sh --dns-upstream 1.1.1.1,8.8.8.8
  sudo bash dns.sh --diagnostico            Revisar red, DNS y HTTP.
  sudo bash dns.sh --publicar               Publicar cambios de HTML/CSS/JS.
  sudo bash dns.sh --restaurar              Volver al respaldo previo.
  bash dns.sh --ayuda

Al instalar se pregunta el dominio (ejemplo: escuela.linux). Intro conserva
el sugerido. Si ya hay una instalación, escribir otro dominio la actualiza,
con respaldo de la configuración anterior. Los modos --publicar,
--diagnostico y --restaurar utilizan el dominio guardado sin volver a pedirlo.

Requisitos: Ubuntu con systemd y conexión para instalar paquetes por apt.
Compatible con una conexión Ethernet/Wi-Fi gestionada por NetworkManager
o una interfaz Ethernet/Wi-Fi de Netplan. Rechaza topologías avanzadas.

Toma la IPv4 actual (normalmente obtenida por DHCP), máscara y gateway;
desactiva el DHCP IPv4 SOLO EN ESA INTERFAZ DEL SERVIDOR y los hace fijos.
No configura un servidor DHCP ni cambia el DHCP del router.
La IPv4 fija NO constituye una reserva DHCP: podrían aparecer duplicados.

Los demás equipos siguen con IP por DHCP, pero deben usar como único DNS
la IPv4 del servidor. Abre http://TU-DOMINIO (HTTP, puerto 80).
Una VM necesita una interfaz alcanzable desde la LAN, normalmente puente.
Si dnsmasq.service ocupa 53 en la LAN y solo proporciona DNS, el script
lo sustituye por BIND9 y conserva su estado anterior en el respaldo.
Las instancias de DHCP/TFTP o de redes virtuales no se detienen.
HELP
}

while (($#)); do
    case "$1" in
        --ayuda|-h|--help) usage; exit 0 ;;
        --diagnostico|--publicar|--restaurar)
            [[ $MODE == instalar ]] || die 'Usa una sola acción por ejecución.'
            MODE="${1#--}"; shift ;;
        --interfaz)
            (($# >= 2)) || die 'Falta el nombre después de --interfaz.'
            IFACE="$2"; shift 2 ;;
        --dns-upstream)
            (($# >= 2)) || die 'Faltan las IPv4 después de --dns-upstream.'
            UPSTREAM_INPUT="$2"; shift 2 ;;
        *) die "Opción desconocida: $1. Consulta --ayuda." ;;
    esac
done

json_get() {
    python3 - "$1" "$2" <<'PY'
import json, sys
value = json.load(open(sys.argv[1]))[sys.argv[2]]
print(value if not isinstance(value, (dict, list)) else json.dumps(value))
PY
}

validate_domain() {
    python3 - "$1" <<'PY'
import ipaddress, re, sys
name = sys.argv[1].strip().lower()
if name.endswith('.'):
    name = name[:-1]
try:
    name = name.encode('idna').decode('ascii')
except UnicodeError:
    sys.exit('El dominio contiene caracteres no válidos.')
try:
    ipaddress.ip_address(name)
except ValueError:
    pass
else:
    sys.exit('Escribe un dominio, no una dirección IP.')
labels = name.split('.')
if (len(name) > 253 or len(labels) < 2 or
    any(not re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?', x) for x in labels) or
    not re.search(r'[a-z]', labels[-1])):
    sys.exit('Usa un nombre como escuela.linux: al menos dos partes, letras, números y guiones; sin http://, puertos ni rutas.')
# BIND también generará www.<dominio>, dns.<dominio> y admin.<dominio>.
if len('admin.' + name) > 253:
    sys.exit('El dominio es demasiado largo para generar sus nombres auxiliares.')
print(name)
PY
}

set_domain_paths() {
    DOMAIN="$1"
    SITE_DIR="$SCRIPT_DIR/sitio-$DOMAIN"
    WEB_ROOT="/var/www/$DOMAIN"
}

load_installed_config() {
    [[ -f $STATE_FILE ]] || die 'Aún no hay una instalación registrada. Ejecuta sudo bash dns.sh.'
    local saved_domain
    # Los estados creados por la primera versión usaban midominio.linux.
    saved_domain="$(python3 - "$STATE_FILE" "$DEFAULT_DOMAIN" <<'PY'
import json, sys
print(json.load(open(sys.argv[1])).get('domain', sys.argv[2]))
PY
)"
    saved_domain="$(validate_domain "$saved_domain")"
    set_domain_paths "$saved_domain"
    SITE_DIR="$(json_get "$STATE_FILE" site_dir)"
}

ask_domain() {
    local suggested="${DOMAIN:-$DEFAULT_DOMAIN}" entered normalized
    while true; do
        printf '\nNombre del dominio local [%s]: ' "$suggested" >&2
        IFS= read -r entered || die 'No se recibió el dominio. Ejecuta el script desde una terminal o proporciona una línea por la entrada estándar.'
        [[ -n $entered ]] || entered="$suggested"
        if normalized="$(validate_domain "$entered")"; then
            set_domain_paths "$normalized"
            info "Dominio seleccionado: $DOMAIN"
            return
        fi
        warn 'Nombre no válido. Inténtalo de nuevo.'
    done
}

cancel_timer() {
    if [[ -n $ROLLBACK_UNIT ]]; then
        systemctl stop "$ROLLBACK_UNIT.timer"
    fi
}

on_error() {
    local status=$1
    trap - ERR HUP INT TERM
    set +e
    if ((TRANSACTION)); then
        warn 'La configuración no terminó. Restaurando los archivos y la red anteriores.'
        # Solo se cancela el temporizador si la restauración terminó bien.
        if bash "$BACKUP/restaurar.sh"; then cancel_timer; fi
        warn "Registro y respaldo: $BACKUP"
    fi
    ((status != 0)) || status=1
    exit "$status"
}

detect_network() {
    # Se usan los datos reales de iproute2; no se adivina /24 ni un gateway .1.
    python3 - "$IFACE" > "$STATE_DIR/red.json" <<'PY'
import ipaddress, json, pathlib, subprocess, sys
def run(*a):
    return subprocess.check_output(a, text=True).strip()
routes = json.loads(run('ip', '-j', '-4', 'route', 'show', 'default'))
requested = sys.argv[1]
routes = [r for r in routes if r.get('dev') and
          (not requested or r['dev'] == requested) and r.get('gateway')]
if not routes:
    sys.exit('No hay una ruta IPv4 por defecto con gateway. Conecta la LAN; usa --interfaz si hace falta.')
route = min(routes, key=lambda r: r.get('metric', 0))
iface, gateway = route['dev'], route['gateway']
if any(iface.startswith(p) for p in ('tun', 'tap', 'wg', 'docker', 'veth', 'virbr', 'br-', 'tailscale')):
    sys.exit('La ruta seleccionada parece de VPN/contenedor. Elige la LAN con --interfaz.')
data = json.loads(run('ip', '-j', '-4', 'address', 'show', 'dev', iface))[0]
addrs = [a for a in data['addr_info'] if a.get('family') == 'inet' and a.get('scope') == 'global']
if len(addrs) != 1:
    sys.exit('Se requiere una sola IPv4 global en la interfaz para no cambiar una configuración ambigua.')
address = ipaddress.IPv4Interface(f"{addrs[0]['local']}/{addrs[0]['prefixlen']}")
gw = ipaddress.IPv4Address(gateway)
rfc1918 = [ipaddress.IPv4Network(n) for n in ('10.0.0.0/8','172.16.0.0/12','192.168.0.0/16')]
if not any(address.network.subnet_of(n) for n in rfc1918):
    sys.exit('La dirección debe pertenecer a una red privada local.')
if address.network.prefixlen > 30 or gw not in address.network or gw == address.ip:
    sys.exit('La dirección/gateway no corresponde a una LAN IPv4 convencional.')
print(json.dumps({'iface': iface, 'ip': str(address.ip), 'cidr': str(address),
                  'network': str(address.network), 'gateway': gateway,
                  'metric': route.get('metric', 100), 'mac': data.get('address', ''),
                  'reverse': address.ip.reverse_pointer,
                  'dynamic': addrs[0].get('dynamic', False)}))
PY
    IFACE="$(json_get "$STATE_DIR/red.json" iface)"
    IP="$(json_get "$STATE_DIR/red.json" ip)"
    CIDR="$(json_get "$STATE_DIR/red.json" cidr)"
    NETWORK="$(json_get "$STATE_DIR/red.json" network)"
    GATEWAY="$(json_get "$STATE_DIR/red.json" gateway)"
    REVERSE="$(json_get "$STATE_DIR/red.json" reverse)"
}

check_ports() {
    # BIND solo escucha en la IP LAN. Los resolutores de loopback pueden seguir.
    ss -H -lnutp > "$STATE_DIR/puertos.txt"
    python3 - "$STATE_DIR/puertos.txt" "$IP" "$STATE_DIR/dns-conflictos.json" "${1:-plan}" <<'PY'
import json, pathlib, re, subprocess, sys
lines = pathlib.Path(sys.argv[1]).read_text().splitlines()
conflicts = []
dnsmasq_lines = []
for line in lines:
    fields = line.split()
    if len(fields) < 5:
        continue
    host, _, port = fields[4].rpartition(':')
    host = host.strip('[]')
    targets = ('0.0.0.0', '*', '::', sys.argv[2])
    if port == '80':
        targets += ('127.0.0.1',)
    if port not in ('53', '80') or host not in targets:
        continue
    expected = '"named"' if port == '53' else '"nginx"'
    if expected in line:
        continue
    names = re.findall(r'\("([^"\n]+)"', line)
    if port == '53' and names and set(names) == {'dnsmasq'} and sys.argv[4] == 'plan':
        dnsmasq_lines.append(line)
    else:
        sys.exit(f'Puerto {port} ocupado por otro servicio en {host}. Resuelve el conflicto antes de continuar.\n{line}')
if dnsmasq_lines:
    unit = 'dnsmasq.service'
    result = subprocess.run(['systemctl', 'show', '--property=MainPID', '--value', unit], capture_output=True, text=True)
    main_pid = result.stdout.strip()
    occupied_pids = {p for line in dnsmasq_lines for p in re.findall(r'\bpid=(\d+)\b', line)}
    if result.returncode or not main_pid.isdigit() or main_pid == '0' or main_pid not in occupied_pids:
        sys.exit('El DNS pertenece a una instancia de dnsmasq distinta de dnsmasq.service. '
                 'No se detienen instancias de NetworkManager, libvirt o procesos ajenos. '
                 'Comprueba la interfaz LAN con --interfaz y el propietario con: systemctl status dnsmasq')
    try:
        command = pathlib.Path(f'/proc/{main_pid}/cmdline').read_bytes().split(b'\0')
        argv = [x.decode(errors='replace') for x in command if x]
    except OSError:
        sys.exit('La instancia dnsmasq cambió durante la revisión. Ejecuta dns.sh de nuevo.')
    if not argv or pathlib.Path(argv[0]).name != 'dnsmasq':
        sys.exit('No se pudo confirmar el proceso dnsmasq del servicio; no se modifica.')
    # El estado del proceso importa: no tocar DHCP, DHCPv6, TFTP o PXE activos.
    for line in lines:
        if re.search(r'\bpid=' + re.escape(main_pid) + r'\b', line):
            fields = line.split()
            if len(fields) >= 5 and fields[4].rpartition(':')[2] in ('67', '547', '69', '4011'):
                sys.exit('dnsmasq.service también escucha puertos de otros servicios. '
                         'Se conserva para no interrumpir DHCP/TFTP/PXE. Solo se sustituyen instancias que prestan DNS exclusivamente.')
    # También proteger servicios configurados para interfaces que hoy no están arriba.
    protected = ('--dhcp-range', '--dhcp-relay', '--enable-tftp', '--conf-script')
    if any(any(a == k or a.startswith(k + '=') for k in protected) for a in argv[1:]):
        sys.exit('dnsmasq tiene DHCP/TFTP o configuración dinámica: no se detiene automáticamente.')
    if any(a.startswith('-F') for a in argv[1:]):
        sys.exit('dnsmasq tiene un rango DHCP en su línea de orden; no se detiene automáticamente.')
    root_file = pathlib.Path('/etc/dnsmasq.conf')
    roots = [root_file]
    default_dir = pathlib.Path('/etc/dnsmasq.d')
    # Dnsmasq puede recibir otros archivos de configuración por la línea de orden.
    for i, arg in enumerate(argv[1:], 1):
        if arg in ('-C', '--conf-file', '-7', '--conf-dir'):
            if i + 1 >= len(argv):
                sys.exit('No se pudo interpretar la configuración dnsmasq; no se detiene.')
            value = argv[i + 1]
            kind = 'dir' if arg in ('-7', '--conf-dir') else 'file'
        elif arg.startswith(('--conf-file=', '--conf-dir=')):
            kind = 'dir' if arg.startswith('--conf-dir=') else 'file'
            value = arg.split('=', 1)[1]
        elif arg.startswith('-C') and len(arg) > 2:
            kind, value = 'file', arg[2:]
        elif arg.startswith('-7') and len(arg) > 2:
            kind, value = 'dir', arg[2:]
        else:
            continue
        p = pathlib.Path(value.split(',')[0])
        if not p.is_absolute() or (kind == 'dir' and p != default_dir) or (kind == 'file' and p != root_file and default_dir not in p.parents):
            sys.exit('dnsmasq utiliza configuración personalizada fuera de /etc/dnsmasq.conf y /etc/dnsmasq.d. No se detiene automáticamente.')
        if kind == 'file':
            roots.append(p)
    if default_dir.exists():
        roots.extend(p for p in default_dir.rglob('*') if p.is_file())
    pattern = re.compile(r'^\s*(dhcp-range|dhcp-relay|enable-tftp|conf-script)(?:\s*=|\s*$)', re.M)
    for path in dict.fromkeys(roots):
        if not path.exists():
            continue
        text = path.read_text(errors='replace')
        active_text = '\n'.join(line.split('#', 1)[0] for line in text.splitlines())
        if pattern.search(active_text):
            sys.exit(f'dnsmasq tiene DHCP/TFTP o configuración dinámica en {path}; no se detiene automáticamente.')
        # Rechazar inclusiones fuera de las ubicaciones conocidas.
        for key, value in re.findall(r'^\s*(conf-file|conf-dir)\s*=\s*([^#\n]+)', text, re.M):
            p = pathlib.Path(value.strip().split(',')[0])
            if (not p.is_absolute() or (key == 'conf-dir' and p != default_dir) or
                (key == 'conf-file' and p != root_file and default_dir not in p.parents)):
                sys.exit(f'dnsmasq incluye otra configuración desde {path}; no se detiene automáticamente.')
    conflicts.append({'unit': unit, 'pid': int(main_pid), 'reason': 'DNS exclusivamente'})
pathlib.Path(sys.argv[3]).write_text(json.dumps(conflicts))
PY
}

resolve_dns_conflicts() {
    # Comprobar de nuevo justo antes del cambio; no matar un PID por su nombre.
    check_ports
    local unit
    while IFS= read -r unit; do
        [[ -n $unit ]] || continue
        info "Sustituyendo $unit (solo DNS) por BIND9. Su estado anterior está respaldado."
        systemctl disable --now "$unit"
    done < <(python3 - "$STATE_DIR/dns-conflictos.json" <<'PY'
import json, sys
for item in json.load(open(sys.argv[1])):
    print(item['unit'])
PY
)
    check_ports estricto
}

detect_manager() {
    MANAGER=''
    ORIGINAL_UUID=''
    if command -v nmcli >/dev/null && systemctl is-active --quiet NetworkManager; then
        ORIGINAL_UUID="$(nmcli -g GENERAL.CON-UUID device show "$IFACE" 2>/dev/null || true)"
        if [[ $ORIGINAL_UUID =~ ^[a-fA-F0-9-]{36}$ ]]; then
            local type
            type="$(nmcli -g connection.type connection show uuid "$ORIGINAL_UUID")"
            [[ $type == 802-3-ethernet || $type == 802-11-wireless ]] ||
                die 'Solo se admiten conexiones Ethernet o Wi-Fi normales de NetworkManager.'
            local method
            method="$(nmcli -g ipv4.method connection show uuid "$ORIGINAL_UUID")"
            [[ $method == auto || $method == manual ]] || die 'La conexión no es una LAN IPv4 normal (auto/manual).'
            MANAGER='NetworkManager'
            return
        fi
    fi
    command -v netplan >/dev/null || die 'No se encontró Netplan ni una conexión activa de NetworkManager.'
    systemctl is-active --quiet systemd-networkd || die 'La interfaz no está gestionada por NetworkManager o systemd-networkd.'
    netplan get > "$STATE_DIR/netplan-antes.yaml"
    python3 - "$STATE_DIR/red.json" "$STATE_DIR/netplan-antes.yaml" "$STATE_DIR/netplan-cambio.json" "$DOMAIN" <<'PY'
import copy, fnmatch, json, subprocess, sys, yaml
red = json.load(open(sys.argv[1]))
config = (yaml.safe_load(open(sys.argv[2])) or {}).get('network', {})
found = []
for group in ('ethernets', 'wifis'):
    for ident, entry in (config.get(group) or {}).items():
        match = entry.get('match', {})
        by_name = ident == red['iface'] or entry.get('set-name') == red['iface']
        if match:
            # Un selector compartido por varias tarjetas no se convierte en estático.
            names = json.loads(subprocess.check_output(['ip', '-j', 'link', 'show'], text=True))
            matches = [n for n in names if
                (not match.get('name') or fnmatch.fnmatchcase(n['ifname'], match['name'])) and
                (not match.get('macaddress') or n.get('address', '').lower() == match['macaddress'].lower())]
            if match.get('driver'):
                continue
            by_name = len(matches) == 1 and matches[0]['ifname'] == red['iface']
        if by_name:
            found.append((group, ident, entry))
if len(found) != 1:
    sys.exit('No se puede identificar una definición Netplan exclusiva para esta tarjeta.')
group, ident, original = found[0]
if original.get('renderer', config.get('renderer', 'networkd')) != 'networkd':
    sys.exit('Netplan usa un renderer distinto de networkd; revisa la conexión activa de NetworkManager.')
if original.get('routing-policy'):
    sys.exit('La interfaz tiene reglas avanzadas de enrutamiento; se necesita configuración manual.')
entry = copy.deepcopy(original)
entry['dhcp4'] = False
addresses = entry.get('addresses', [])
if any(not isinstance(a, str) for a in addresses):
    sys.exit('La interfaz usa opciones avanzadas de dirección; no se modificó.')
entry['addresses'] = list(dict.fromkeys(addresses + [red['cidr']]))
entry.pop('gateway4', None)
routes = [r for r in entry.get('routes', []) if not
          (str(r.get('to')) in ('default', '0.0.0.0/0') and ':' not in str(r.get('via', '')))]
routes.append({'to': '0.0.0.0/0', 'via': red['gateway'], 'metric': red['metric']})
# Conservar rutas adicionales recibidas del DHCP, si existen.
live = json.loads(subprocess.check_output(['ip', '-j', '-4', 'route', 'show', 'dev', red['iface']], text=True))
for r in live:
    if r.get('protocol') == 'dhcp' and r.get('dst') not in (None, 'default', red['network']) and r.get('gateway'):
        item = {'to': r['dst'], 'via': r['gateway'], 'metric': r.get('metric', red['metric'])}
        if item not in routes:
            routes.append(item)
entry['routes'] = routes
entry['nameservers'] = {'addresses': [red['ip']], 'search': [sys.argv[4]]}
json.dump({'group': group, 'id': ident, 'entry': entry}, open(sys.argv[3], 'w'))
PY
    MANAGER='Netplan'
}

detect_upstreams() {
    : > "$STATE_DIR/dns-candidatos.txt"
    if [[ -n $UPSTREAM_INPUT ]]; then
        printf '%s\n' "$UPSTREAM_INPUT" > "$STATE_DIR/dns-candidatos.txt"
    else
        if [[ -n $OLD_DOMAIN ]]; then
            # Cambiar el dominio no debe perder los reenviadores originales:
            # el DNS de la tarjeta ya apunta a este mismo servidor.
            python3 - "$STATE_FILE" /etc/bind/named.conf.options >> "$STATE_DIR/dns-candidatos.txt" <<'PY'
import json, pathlib, re, sys
saved = json.load(open(sys.argv[1])).get('upstreams')
if saved:
    print('\n'.join(saved))
else:
    text = pathlib.Path(sys.argv[2]).read_text()
    match = re.search(r'\bforwarders\s*\{([^}]*)\}', text, re.S)
    if match:
        print(match.group(1))
PY
        fi
        if command -v resolvectl >/dev/null; then
            resolvectl dns "$IFACE" >> "$STATE_DIR/dns-candidatos.txt" 2>/dev/null || true
        fi
        if command -v nmcli >/dev/null; then
            nmcli -g IP4.DNS device show "$IFACE" >> "$STATE_DIR/dns-candidatos.txt" 2>/dev/null || true
        fi
        # No sustituir el DNS original por servidores públicos sin necesidad.
        if [[ -r /run/systemd/resolve/resolv.conf ]]; then
            cat /run/systemd/resolve/resolv.conf >> "$STATE_DIR/dns-candidatos.txt"
        else
            cat /etc/resolv.conf >> "$STATE_DIR/dns-candidatos.txt"
        fi
    fi
    python3 - "$STATE_DIR/dns-candidatos.txt" "$IP" "$GATEWAY" "$UPSTREAM_INPUT" > "$STATE_DIR/upstreams.txt" <<'PY'
import ipaddress, re, sys
text = '\n'.join(l.split('#')[0] for l in open(sys.argv[1]))
valid = []
if sys.argv[4]:
    try:
        [ipaddress.IPv4Address(x.strip()) for x in sys.argv[4].split(',')]
    except ValueError:
        sys.exit('--dns-upstream solo acepta IPv4 separadas por comas.')
for token in re.findall(r'(?<![\d.:])(?:\d{1,3}\.){3}\d{1,3}(?![\d.:])', text):
    try:
        ip = ipaddress.IPv4Address(token)
    except ValueError:
        continue
    if token != sys.argv[2] and not (ip.is_loopback or ip.is_unspecified or ip.is_multicast or ip.is_link_local):
        if token not in valid:
            valid.append(token)
if not valid and not sys.argv[4] and sys.argv[3] != sys.argv[2]:
    valid.append(sys.argv[3])
if not valid and sys.argv[4]:
    sys.exit('Los DNS upstream no pueden ser el propio servidor ni direcciones de loopback.')
print('\n'.join(valid))
PY
    mapfile -t UPSTREAMS < "$STATE_DIR/upstreams.txt"
}

create_backup() {
    BACKUP="$BACKUP_BASE/$(date +%Y%m%d-%H%M%S)-$$"
    install -d -m 700 "$BACKUP" "$BACKUP/files"
    export BACKUP MANAGER ORIGINAL_UUID IFACE DOMAIN OLD_DOMAIN STATE_FILE STATE_DIR
    python3 - <<'PY'
import json, os, pathlib, shutil, subprocess
b = pathlib.Path(os.environ['BACKUP'])
paths = ['/etc/bind/named.conf.options', '/etc/bind/named.conf.local',
         '/etc/hosts', '/etc/cloud/cloud.cfg.d/99-dns-midominio-network.cfg',
         '/etc/systemd/system/named.service.d/99-dns-midominio-network.conf',
         os.environ['STATE_FILE']]
for domain in dict.fromkeys(d for d in (os.environ['DOMAIN'], os.environ['OLD_DOMAIN']) if d):
    paths += [f'/etc/bind/db.{domain}', f'/etc/bind/db.{domain}.rev',
              f'/etc/nginx/sites-available/{domain}', f'/etc/nginx/sites-enabled/{domain}',
              f'/var/www/{domain}']
ufw = shutil.which('ufw')
if ufw and subprocess.run([ufw,'status'],capture_output=True,text=True).stdout.startswith('Status: active'):
    paths += ['/etc/ufw/user.rules', '/etc/ufw/user6.rules']
    (b/'ufw-active').touch()
if os.environ['MANAGER'] == 'Netplan':
    paths.append('/etc/netplan')
manifest = []
for i, value in enumerate(paths):
    p, dest = pathlib.Path(value), b / 'files' / str(i)
    exists = p.exists() or p.is_symlink()
    if exists:
        if p.is_dir() and not p.is_symlink():
            shutil.copytree(p, dest, symlinks=True)
        else:
            shutil.copy2(p, dest, follow_symlinks=False)
    manifest.append({'path': value, 'saved': str(dest), 'existed': exists})
json.dump(manifest, open(b/'manifest.json', 'w'))
if os.environ['MANAGER'] == 'NetworkManager':
    old = subprocess.check_output(['nmcli', '-g', 'connection.autoconnect', 'con', 'show', 'uuid', os.environ['ORIGINAL_UUID']], text=True).strip()
    json.dump({'uuid': os.environ['ORIGINAL_UUID'], 'autoconnect': old, 'iface': os.environ['IFACE']}, open(b/'nm-original.json','w'))
services = {}
units = ['named.service', 'nginx.service']
units += [item['unit'] for item in json.load(open(pathlib.Path(os.environ['STATE_DIR'])/'dns-conflictos.json'))]
for unit in dict.fromkeys(units):
    services[unit] = {'active': subprocess.run(['systemctl','is-active','--quiet',unit]).returncode == 0,
                      'enabled': subprocess.run(['systemctl','is-enabled',unit],text=True,capture_output=True).stdout.strip()}
json.dump(services, open(b/'services.json','w'))
PY
    cat > "$BACKUP/restaurar.sh" <<'RESTORE'
#!/usr/bin/env bash
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
BACKUP="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec 8> "$BACKUP/restauracion.lock"
flock -w 60 8 || exit 1
[[ ! -f $BACKUP/restaurado ]] || exit 0
touch "$BACKUP/restauracion-iniciada"
python3 - "$BACKUP" <<'PY'
import json, pathlib, shutil, subprocess, sys
b = pathlib.Path(sys.argv[1])
services = json.load(open(b/'services.json'))
def run(args, critical=False):
    r = subprocess.run(args)
    if critical and r.returncode:
        sys.exit(r.returncode)
def remove(p):
    if p.is_symlink() or p.is_file(): p.unlink()
    elif p.exists(): shutil.rmtree(p)
if 'dnsmasq.service' in services:
    # Liberar el puerto antes de recuperar la instancia DNS que lo tenía.
    run(['systemctl','stop','named.service'], True)
for item in json.load(open(b/'manifest.json')):
    p, saved = pathlib.Path(item['path']), pathlib.Path(item['saved'])
    if item['existed'] and p.is_file() and not p.is_symlink() and saved.is_file() and not saved.is_symlink():
        # /etc/hosts puede ser un punto de montaje: conservar su inodo.
        shutil.copyfile(saved, p)
        shutil.copystat(saved, p)
    else:
        remove(p)
        if item['existed']:
            p.parent.mkdir(parents=True, exist_ok=True)
            if saved.is_dir() and not saved.is_symlink(): shutil.copytree(saved, p, symlinks=True)
            else: shutil.copy2(saved, p, follow_symlinks=False)
if (b/'ufw-active').exists():
    run(['ufw','reload'], True)
if (b/'nm-original.json').exists():
    n = json.load(open(b/'nm-original.json'))
    run(['nmcli','con','modify','uuid',n['uuid'],'connection.autoconnect',n['autoconnect']], True)
    run(['nmcli','--wait','45','con','up','uuid',n['uuid'],'ifname',n['iface']], True)
    if (b/'nm-clone.uuid').exists():
        run(['nmcli','con','delete','uuid',(b/'nm-clone.uuid').read_text().strip()])
else:
    run(['netplan','generate'], True)
    run(['netplan','apply'], True)
run(['systemctl','daemon-reload'], True)
units = sorted(services, key=lambda u: (u != 'dnsmasq.service', u))
for unit in units:
    s = services[unit]
    run(['systemctl', 'enable' if s['enabled'] in ('enabled','enabled-runtime') else 'disable', unit])
    run(['systemctl', 'restart' if s['active'] else 'stop', unit], s['active'])
if shutil.which('resolvectl'):
    run(['resolvectl','flush-caches'])
(b/'restaurado').touch()
PY
    printf '\nRestauración terminada. Los paquetes y la carpeta del sitio se conservan.\n'
RESTORE
    chmod 700 "$BACKUP/restaurar.sh"
    # Un temporizador independiente recupera la red incluso si se pierde la sesión.
    ROLLBACK_UNIT="dns-midominio-rollback-$$"
    systemd-run --quiet --unit="$ROLLBACK_UNIT" --on-active=5m \
        /bin/bash "$BACKUP/restaurar.sh"
    TRANSACTION=1
    trap 'on_error $?' ERR
    trap 'on_error 130' INT
    trap 'on_error 129' HUP
    trap 'on_error 143' TERM
}

remove_old_domain_config() {
    [[ -n $OLD_DOMAIN && $OLD_DOMAIN != "$DOMAIN" ]] || return 0
    info "Sustituyendo $OLD_DOMAIN por $DOMAIN."
    python3 - "$OLD_DOMAIN" <<'PY'
import pathlib, re, shutil, sys
domain = sys.argv[1]
p = pathlib.Path('/etc/bind/named.conf.local')
escaped = re.escape(domain)
pattern = r'\n?// BEGIN dns\.sh ' + escaped + r'\n.*?// END dns\.sh ' + escaped + r'\n?'
p.write_text(re.sub(pattern, '\n', p.read_text(), flags=re.S))
for value in (f'/etc/bind/db.{domain}', f'/etc/bind/db.{domain}.rev',
              f'/etc/nginx/sites-enabled/{domain}', f'/etc/nginx/sites-available/{domain}',
              f'/var/www/{domain}'):
    target = pathlib.Path(value)
    if target.is_symlink() or target.is_file():
        target.unlink()
    elif target.is_dir():
        shutil.rmtree(target)
PY
}

configure_bind() {
    info 'Configurando BIND9 para la red local.'
    cat > /etc/bind/named.conf.options <<EOF
// Administrado por dns.sh. Respaldo: $BACKUP
acl lan_dns_local { 127.0.0.1; $NETWORK; };
options {
    directory "/var/cache/bind";
    listen-on port 53 { $IP; };
    listen-on-v6 { none; };
    allow-query { lan_dns_local; };
    allow-recursion { lan_dns_local; };
    allow-query-cache { lan_dns_local; };
    allow-transfer { none; };
    recursion yes;
    dnssec-validation auto;
    minimal-responses yes;
    forward first;
    forwarders {
EOF
    local server
    for server in "${UPSTREAMS[@]}"; do [[ -z $server ]] || printf '        %s;\n' "$server" >> /etc/bind/named.conf.options; done
    cat >> /etc/bind/named.conf.options <<'EOF'
    };
};
EOF
    local serial
    serial="$(date +%s)"
    cat > "/etc/bind/db.$DOMAIN" <<EOF
\$TTL 300
@ IN SOA dns.$DOMAIN. admin.$DOMAIN. (
    $serial 3600 900 604800 300 )
@   IN NS dns.$DOMAIN.
@   IN A $IP
dns IN A $IP
www IN A $IP
EOF
    # Zona del host exacto: funciona también en /16, /23, /25, sin fingir /24.
    cat > "/etc/bind/db.$DOMAIN.rev" <<EOF
\$TTL 300
@ IN SOA dns.$DOMAIN. admin.$DOMAIN. (
    $serial 3600 900 604800 300 )
@ IN NS dns.$DOMAIN.
@ IN PTR $DOMAIN.
EOF
    cat >> /etc/bind/named.conf.local <<EOF

// BEGIN dns.sh $DOMAIN
zone "$DOMAIN" {
    type master;
    file "/etc/bind/db.$DOMAIN";
    allow-update { none; };
};
zone "$REVERSE" {
    type master;
    file "/etc/bind/db.$DOMAIN.rev";
    allow-update { none; };
};
// END dns.sh $DOMAIN
EOF
    chmod 644 /etc/bind/named.conf.options /etc/bind/named.conf.local "/etc/bind/db.$DOMAIN" "/etc/bind/db.$DOMAIN.rev"
    named-checkzone "$DOMAIN" "/etc/bind/db.$DOMAIN"
    named-checkzone "$REVERSE" "/etc/bind/db.$DOMAIN.rev"
    named-checkconf -z
    install -d -m 755 /etc/systemd/system/named.service.d
    cat > /etc/systemd/system/named.service.d/99-dns-midominio-network.conf <<'EOF'
[Unit]
Wants=network-online.target
After=network-online.target
EOF
    systemctl daemon-reload
    systemctl enable named.service
    systemctl restart named.service
}

create_site() {
    info "Creando el sitio en $SITE_DIR"
    [[ ! -L $SITE_DIR ]] || die "La carpeta $SITE_DIR no puede ser un enlace simbólico."
    install -d -m 755 "$SITE_DIR"
    local file
    for file in index.html style.css script.js LEEME.txt; do
        [[ ! -L $SITE_DIR/$file ]] || die "El archivo no puede ser un enlace: $SITE_DIR/$file"
        [[ ! -e $SITE_DIR/$file || -f $SITE_DIR/$file ]] || die "La ruta no es un archivo regular: $SITE_DIR/$file"
    done
    if [[ -n $OLD_DOMAIN && $OLD_DOMAIN != "$DOMAIN" && -d $OLD_SITE_DIR ]]; then
        # Conservar los archivos editables y sustituir el dominio anterior.
        python3 - "$OLD_SITE_DIR" "$SITE_DIR" "$OLD_DOMAIN" "$DOMAIN" <<'PY'
import pathlib, re, sys
source, target = map(pathlib.Path, sys.argv[1:3])
for name in ('index.html', 'style.css', 'script.js'):
    src, dst = source/name, target/name
    if not dst.exists() and src.is_file() and not src.is_symlink():
        text = re.sub(re.escape(sys.argv[3]), sys.argv[4], src.read_text(encoding='utf-8'), flags=re.I)
        dst.write_text(text, encoding='utf-8')
PY
    fi
    # Las ejecuciones posteriores conservan las modificaciones del usuario.
    if [[ ! -e $SITE_DIR/index.html ]]; then
        cat > "$SITE_DIR/index.html" <<HTML
<!doctype html>
<html lang="es">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <meta name="description" content="Mi primer sitio en la red local.">
  <title>Hola mundo · $DOMAIN</title>
  <link rel="stylesheet" href="style.css">
  <script src="script.js" defer></script>
</head>
<body>
  <main>
    <span class="eyebrow"><span class="dot" aria-hidden="true"></span> MI RED LOCAL</span>
    <p class="domain">$DOMAIN</p>
    <h1>Hola mundo<span>!</span></h1>
    <p class="intro">Este sitio vive en mi servidor Ubuntu.<br>Bienvenido a nuestra red.</p>
    <button id="saludar" type="button">Probar JavaScript <span aria-hidden="true">↗</span></button>
    <p id="mensaje" role="status" aria-live="polite">HTML + CSS + JavaScript, juntos.</p>
    <footer>Una pequeña página. Una nueva conexión.</footer>
  </main>
</body>
</html>
HTML
    fi
    if [[ ! -e $SITE_DIR/style.css ]]; then
        cat > "$SITE_DIR/style.css" <<'CSS'
:root{color-scheme:light;--ink:#163531;--accent:#17685a;--paper:#f5f3ec}
*{box-sizing:border-box}body{margin:0;min-height:100svh;display:grid;place-items:center;padding:32px 20px;background:var(--paper);color:var(--ink);font-family:system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
main{position:relative;width:min(100%,850px);padding:clamp(28px,7vw,80px);background:#fff;border:1px solid #dce6df;border-radius:28px;box-shadow:0 24px 80px #1635310a;overflow-wrap:anywhere}
.eyebrow{display:inline-flex;align-items:center;gap:9px;font-size:.72rem;font-weight:750;letter-spacing:.16em}.dot{width:8px;height:8px;background:#228063;border-radius:50%}.domain{margin:44px 0 12px;font-size:.9rem;color:#4f6b62}h1{margin:0;font-size:clamp(3rem,9vw,6.5rem);line-height:1.02;letter-spacing:-.065em}h1 span{color:#c6743c}.intro{margin:26px 0 32px;font-size:clamp(1rem,2.3vw,1.2rem);line-height:1.7;color:#49625a}
button{display:inline-flex;align-items:center;gap:28px;padding:15px 20px;border:0;border-radius:12px;background:var(--accent);color:#fff;font:inherit;font-weight:650;cursor:pointer}button:hover{background:#115043}button:focus-visible{outline:3px solid #c6743c;outline-offset:4px}#mensaje{min-height:2.8em;margin:20px 0 0;color:#49625a;font-size:.93rem;line-height:1.5}footer{margin-top:40px;padding-top:24px;border-top:1px solid #e4ebe6;font-size:.8rem;color:#587267}
@media(max-width:420px){body{padding:16px}main{padding:30px 24px;border-radius:20px}.domain{margin-top:34px}button{width:100%;justify-content:space-between;gap:12px}}
CSS
    fi
    if [[ ! -e $SITE_DIR/script.js ]]; then
        cat > "$SITE_DIR/script.js" <<'JS'
"use strict";
const boton = document.getElementById("saludar");
const mensaje = document.getElementById("mensaje");
let saludos = 0;
boton.addEventListener("click", () => {
  saludos += 1;
  const hora = new Intl.DateTimeFormat("es-MX", { timeStyle: "medium" }).format(new Date());
  mensaje.textContent = `¡Hola! JavaScript funciona. Saludo ${saludos} · ${hora}`;
});
JS
    fi
    chmod 644 "$SITE_DIR/index.html" "$SITE_DIR/style.css" "$SITE_DIR/script.js"
    if [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then
        chown "$SUDO_USER:$(id -gn "$SUDO_USER")" "$SITE_DIR" "$SITE_DIR/index.html" "$SITE_DIR/style.css" "$SITE_DIR/script.js"
    fi
}

publish_site() {
    local file
    [[ -d $SITE_DIR && ! -L $SITE_DIR ]] || die "No existe una carpeta válida: $SITE_DIR"
    [[ ! -L $WEB_ROOT ]] || die "El directorio web no debe ser un enlace: $WEB_ROOT"
    install -d -m 755 "$WEB_ROOT"
    for file in index.html style.css script.js; do
        [[ -f $SITE_DIR/$file && ! -L $SITE_DIR/$file ]] || die "Falta un archivo regular: $SITE_DIR/$file"
        install -m 644 -o root -g root "$SITE_DIR/$file" "$WEB_ROOT/$file"
    done
}

configure_nginx() {
    publish_site
    cat > "/etc/nginx/sites-available/$DOMAIN" <<EOF
# Administrado por dns.sh. No se eliminan los otros sitios de Nginx.
server {
    listen 80;
    server_name $DOMAIN www.$DOMAIN $IP;
    root $WEB_ROOT;
    index index.html;
    charset utf-8;
    server_tokens off;
    allow 127.0.0.1;
    allow $NETWORK;
    deny all;
    add_header X-Content-Type-Options nosniff always;
    location / { try_files \$uri \$uri/ =404; }
    location ~ /\. { deny all; }
}
EOF
    ln -sfn "/etc/nginx/sites-available/$DOMAIN" "/etc/nginx/sites-enabled/$DOMAIN"
    nginx -t
    systemctl enable nginx.service
    systemctl restart nginx.service
}

configure_firewall() {
    # No habilitar UFW si estaba deshabilitado, ni abrir DNS fuera de la LAN.
    if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
        info 'Permitiendo DNS UDP/TCP y HTTP en UFW solo desde la subred local.'
        local port proto
        for port in 53 80; do
            for proto in udp tcp; do
                [[ $port == 53 || $proto == tcp ]] || continue
                ufw allow in on "$IFACE" from "$NETWORK" to "$IP" port "$port" proto "$proto" comment DNS-MIDOMINIO
            done
        done
    fi
    if systemctl is-active --quiet firewalld.service; then
        warn 'Hay firewalld activo. Autoriza 53/UDP, 53/TCP y 80/TCP desde la LAN en su zona correspondiente.'
    fi
}

configure_network() {
    info "Fijando $CIDR en $IFACE mediante $MANAGER. La conexión puede interrumpirse unos segundos."
    if [[ $MANAGER == NetworkManager ]]; then
        local clone_name clone_uuid
        clone_name="dns-midominio-$IFACE-$(date +%s)-$$"
        nmcli connection clone uuid "$ORIGINAL_UUID" "$clone_name" >/dev/null
        clone_uuid="$(nmcli -g connection.uuid connection show "$clone_name")"
        printf '%s\n' "$clone_uuid" > "$BACKUP/nm-clone.uuid"
        nmcli connection modify uuid "$clone_uuid" \
            connection.interface-name "$IFACE" connection.autoconnect yes connection.autoconnect-priority 999 \
            ipv4.method manual ipv4.addresses "$CIDR" ipv4.gateway "$GATEWAY" \
            ipv4.dns "$IP" ipv4.ignore-auto-dns yes ipv4.dns-search "$DOMAIN" \
            ipv6.ignore-auto-dns yes ipv6.dns ''
        # Las rutas DHCP adicionales no están guardadas en el perfil clonado.
        python3 - "$IFACE" "$NETWORK" > "$STATE_DIR/rutas-dhcp.txt" <<'PY'
import json, subprocess, sys
routes = json.loads(subprocess.check_output(['ip','-j','-4','route','show','dev',sys.argv[1]], text=True))
for r in routes:
    if r.get('protocol') == 'dhcp' and r.get('dst') not in (None, 'default', sys.argv[2]) and r.get('gateway'):
        print(f"{r['dst']} {r['gateway']} {r.get('metric', 100)}")
PY
        local route
        while IFS= read -r route; do
            [[ -z $route ]] || nmcli connection modify uuid "$clone_uuid" +ipv4.routes "$route"
        done < "$STATE_DIR/rutas-dhcp.txt"
        nmcli connection modify uuid "$ORIGINAL_UUID" connection.autoconnect no
        nmcli --wait 45 connection up uuid "$clone_uuid" ifname "$IFACE"
    else
        # netplan set sustituye el subárbol conservando los datos de Wi-Fi/match.
        python3 - "$STATE_DIR/netplan-cambio.json" <<'PY'
import json, subprocess, sys
c = json.load(open(sys.argv[1]))
ident = c['id'].replace('.', r'\.')
value = f"network.{c['group']}.{ident}=" + json.dumps(c['entry'])
subprocess.run(['netplan', 'set', '--origin-hint=99-dns-midominio', value], check=True)
PY
        # Evita que cloud-init regenere el DHCP en el siguiente arranque.
        if [[ -d /etc/cloud/cloud.cfg.d ]]; then
            printf 'network: {config: disabled}\n' > /etc/cloud/cloud.cfg.d/99-dns-midominio-network.cfg
            chmod 600 /etc/cloud/cloud.cfg.d/99-dns-midominio-network.cfg
        fi
        netplan generate
        netplan apply
    fi
    python3 - "$IFACE" "$CIDR" <<'PY'
import json, subprocess, sys
d = json.loads(subprocess.check_output(['ip','-j','-4','addr','show','dev',sys.argv[1]], text=True))
ok = any(f"{a['local']}/{a['prefixlen']}" == sys.argv[2] for a in d[0]['addr_info'] if a.get('family') == 'inet')
if not ok: sys.exit('La interfaz no conserva la IP/prefijo esperado después del cambio.')
if any(a.get('dynamic', False) for a in d[0]['addr_info'] if a.get('family') == 'inet' and f"{a['local']}/{a['prefixlen']}" == sys.argv[2]):
    sys.exit('La dirección todavía figura como dinámica; no se confirmó la conversión a estática.')
PY
}

configure_hosts() {
    # Entrada del propio servidor; los clientes resuelven con BIND, no con hosts.
    python3 - "$IP" "$DOMAIN" "$OLD_DOMAIN" <<'PY'
import pathlib, re, sys
p = pathlib.Path('/etc/hosts')
s = p.read_text()
domain = sys.argv[2]
domains = {d for d in (domain, sys.argv[3]) if d}
for d in domains:
    escaped = re.escape(d)
    pattern = r'\n?# BEGIN dns\.sh ' + escaped + r'\n.*?# END dns\.sh ' + escaped + r'\n?'
    s = re.sub(pattern, '\n', s, flags=re.S)
names = {name for d in domains for name in (d, 'www.' + d, 'dns.' + d)}
lines = []
for line in s.splitlines():
    body, sep, comment = line.partition('#')
    fields = body.split()
    if fields and any(n in names for n in fields[1:]):
        kept = [n for n in fields[1:] if n not in names]
        if not kept:
            if sep: lines.append('#' + comment)
            continue
        line = fields[0] + '\t' + ' '.join(kept) + (' #' + comment if sep else '')
    lines.append(line)
lines += ['# BEGIN dns.sh ' + domain,
          sys.argv[1] + '\t' + ' '.join((domain, 'www.' + domain, 'dns.' + domain)),
          '# END dns.sh ' + domain]
# Escribir en el inodo existente, por si /etc/hosts es un punto de montaje.
p.write_text('\n'.join(lines) + '\n')
PY
}

verify_install() {
    info 'Comprobando IP, servicio DNS por UDP/TCP, zona inversa y sitio HTTP.'
    local answer
    systemctl is-active --quiet named.service
    systemctl is-active --quiet nginx.service
    answer="$(dig +time=2 +tries=1 +short @"$IP" "$DOMAIN" A)"
    [[ $answer == "$IP" ]] || die "La consulta DNS UDP devolvió: $answer"
    answer="$(dig +tcp +time=2 +tries=1 +short @"$IP" "www.$DOMAIN" A)"
    [[ $answer == "$IP" ]] || die "La consulta DNS TCP devolvió: $answer"
    answer="$(dig +time=2 +tries=1 +short @"$IP" -x "$IP")"
    [[ $answer == "$DOMAIN." ]] || die "La consulta inversa devolvió: $answer"
    curl --noproxy '*' --fail --silent --show-error --max-time 8 \
        --resolve "$DOMAIN:80:$IP" "http://$DOMAIN/" > "$STATE_DIR/http-verificado.html"
    cmp -s "$WEB_ROOT/index.html" "$STATE_DIR/http-verificado.html" || die 'El contenido HTTP no coincide con el HTML publicado.'
    for answer in style.css script.js; do
        curl --noproxy '*' --fail --silent --show-error --max-time 8 \
            --resolve "$DOMAIN:80:$IP" "http://$DOMAIN/$answer" >/dev/null
    done
    if ! dig +time=3 +tries=1 +short @"$IP" example.com A | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
        warn 'El dominio local funciona, pero no se pudo confirmar la resolución de Internet. Revisa los DNS upstream o la salida a Internet.'
    fi
    if command -v resolvectl >/dev/null; then resolvectl flush-caches || true; fi
}

write_guide() {
    cat > "$SITE_DIR/LEEME.txt" <<EOF
DNS LOCAL Y SITIO WEB — $DOMAIN

Servidor Ubuntu: $IP
IP/prefijo: $CIDR
Interfaz: $IFACE
Gateway: $GATEWAY
Clientes admitidos: $NETWORK
Página: http://$DOMAIN
Alias: http://www.$DOMAIN

1. CONFIGURAR CADA CLIENTE (sin modificar router ni DHCP)
Mantén su dirección IP en automática/DHCP. Cambia solamente su DNS:
usa $IP como ÚNICO servidor DNS para esta conexión, sin DNS público
alternativo. Un DNS externo no conoce $DOMAIN y puede causar
fallos intermitentes; BIND reenvía las consultas de Internet.

Windows, PowerShell como administrador:
  Get-NetAdapter
  Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses "$IP"
  Clear-DnsClientCache
Cambia "Ethernet" por el nombre real, por ejemplo "Wi-Fi".
Para volver al DNS automático:
  Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ResetServerAddresses

Ubuntu Desktop / Linux con NetworkManager:
  Ajustes > Red (o Wi-Fi) > conexión > IPv4.
  Conserva IP automática y desactiva SOLO el DNS automático.
  DNS: $IP. Dominio de búsqueda: $DOMAIN. Guarda y reconecta.
  Comprueba que DNS recibidos por IPv6 no se usen para este dominio.
  Si es necesario, ignora el DNS IPv6 automático de esa conexión.

macOS:
  Ajustes del Sistema > Red > conexión > Detalles > DNS.
  Sustituye los DNS por $IP y guarda.

2. PROBAR DESDE OTRO EQUIPO
  nslookup $DOMAIN $IP
  nslookup $DOMAIN
Ambos deben devolver $IP. Abre: http://$DOMAIN
Si la primera consulta responde y la segunda no, revisa el DNS del cliente.
No se necesita editar el archivo hosts de los clientes.

3. EDITAR Y PUBLICAR
Los tres archivos editables están junto a esta guía:
  index.html
  style.css
  script.js
Nginx sirve una copia en $WEB_ROOT para no abrir permisos de tu carpeta
personal. Después de editar, publica desde la ubicación de dns.sh:
  sudo bash dns.sh --publicar
Las próximas ejecuciones conservan tus tres archivos existentes.
Para cambiar el dominio ejecuta sudo bash dns.sh y escribe el nuevo nombre.
Los archivos editables se copian a sitio-NUEVO-DOMINIO y se reemplazan las
apariciones del dominio anterior. La carpeta anterior se conserva.

4. DIAGNÓSTICO Y RESTAURACIÓN
  sudo bash dns.sh --diagnostico
  sudo bash dns.sh --restaurar
Restauración directa desde la consola si dns.sh no está disponible:
  sudo bash "$BACKUP/restaurar.sh"
Respaldo protegido: $BACKUP
La restauración recupera archivos, perfil de red y estados de servicios
previos a la configuración, y retira las reglas UFW añadidas por el script.
Si se sustituyó dnsmasq.service porque solo prestaba DNS, recupera también
su estado anterior. Sus archivos de configuración no se modifican.
Si cambiaste el dominio, restaura el dominio anterior y su estado guardado.
Puedes volver a ejecutar --restaurar para regresar al respaldo precedente.
Conserva los paquetes instalados y los archivos editables del sitio.
No restaures este respaldo sobre cambios posteriores que quieras conservar.

5. CONDICIONES DE LA RED
- En una VM, usa adaptador puente o una red con rutas hacia ella. El NAT
  simple del hipervisor no hace accesible el servicio a la LAN física.
- Desactiva aislamiento de clientes en la red Wi-Fi, si está habilitado.
- UFW activo recibe reglas 53/UDP, 53/TCP y 80/TCP solo para $NETWORK.
  Si usas otro firewall, autoriza esos puertos desde la LAN.
- Si el navegador usa DNS seguro/DoH externo, configúralo para utilizar
  el DNS del sistema en esta red. Usa HTTP; no se instala certificado TLS.
- El servidor debe permanecer encendido para resolver los nombres.
- Este dominio solo existe en este DNS local; no se publica en Internet.
- BIND9 escucha en $IP:53. Los resolutores que usan solo loopback,
  como systemd-resolved o el DNS local de NetworkManager, pueden coexistir.
- Si dnsmasq.service ocupaba el DNS de la LAN y solo prestaba DNS, se
  detiene y deshabilita con respaldo de su estado. No se desinstala.
  Si presta DHCP/TFTP o pertenece a libvirt/NetworkManager, no se detiene.
- La configuración del servidor es IPv4. El DNS IPv6 de los clientes
  no debe desviar las consultas locales a un servidor externo.
- Si eliges un dominio terminado en .local, Linux puede utilizar mDNS:
  agrega $DOMAIN como dominio de búsqueda de la conexión del cliente
  para dirigir esas consultas al DNS indicado. Un sufijo como .test
  evita el tratamiento especial de .local.

IMPORTANTE: IP FIJA NO ES RESERVA DHCP
El script convierte la IP recibida en estática en Ubuntu, pero no puede
impedir que el DHCP del router vuelva a asignarla a otro dispositivo.
La prueba ARP detecta algunos duplicados actuales, no conflictos futuros.
Para garantizar una IP sin colisiones debe reservarse/excluirse en DHCP
o utilizarse una IP confirmada fuera de su rango. Sin tocar el router/DHCP,
esa garantía no existe. Si cambias de red, restaura y configura de nuevo.
EOF
    chmod 644 "$SITE_DIR/LEEME.txt"
    if [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then
        chown "$SUDO_USER:$(id -gn "$SUDO_USER")" "$SITE_DIR/LEEME.txt"
    fi
}

diagnostic() {
    load_installed_config
    local address iface failed=0
    address="$(json_get "$STATE_FILE" ip)"
    iface="$(json_get "$STATE_FILE" iface)"
    info "Servidor registrado: $DOMAIN -> $address ($iface)"
    ip -br -4 address show dev "$iface" || failed=1
    ip -4 route show default
    systemctl --no-pager --full status named.service nginx.service || failed=1
    ss -lnut | grep -E '(:53|:80)[[:space:]]' || failed=1
    if command -v dig >/dev/null; then
        local reply
        reply="$(dig +time=2 +tries=1 +short @"$address" "$DOMAIN" A)" || failed=1
        [[ $reply == "$address" ]] || { warn "Respuesta DNS UDP incorrecta: $reply"; failed=1; }
        reply="$(dig +tcp +time=2 +tries=1 +short @"$address" "$DOMAIN" A)" || failed=1
        [[ $reply == "$address" ]] || { warn "Respuesta DNS TCP incorrecta: $reply"; failed=1; }
        reply="$(dig +time=2 +tries=1 +short @"$address" -x "$address")" || failed=1
        [[ $reply == "$DOMAIN." ]] || { warn "Respuesta PTR incorrecta: $reply"; failed=1; }
    else
        warn 'No se encuentra dig. Reinstala dnsutils.'
        failed=1
    fi
    curl --noproxy '*' --fail --show-error --max-time 8 --resolve "$DOMAIN:80:$address" "http://$DOMAIN/" >/dev/null || failed=1
    if command -v ufw >/dev/null; then ufw status verbose || true; fi
    printf '\nEn otro equipo: DNS = %s; abrir http://%s\n' "$address" "$DOMAIN"
    return "$failed"
}

main() {
    need_root
    command -v python3 >/dev/null || die 'Instala primero python3: sudo apt-get update && sudo apt-get install -y python3'
    install -d -m 700 "$STATE_DIR"
    exec 9> "$STATE_DIR/instalacion.lock"
    flock -n 9 || die 'Ya hay otra ejecución de dns.sh en curso.'
    case "$MODE" in
        diagnostico) diagnostic; return ;;
        restaurar)
            [[ -f $STATE_FILE ]] || die 'No hay un respaldo registrado que restaurar.'
            local restore_path
            restore_path="$(json_get "$STATE_FILE" backup)"
            [[ -f $restore_path/restaurar.sh && $restore_path == "$BACKUP_BASE/"* ]] || die 'La ruta de respaldo no es válida.'
            bash "$restore_path/restaurar.sh"
            # Los respaldos nuevos recuperan también el estado del dominio previo.
            # Compatibilidad: el respaldo de la primera versión no incluía estado.
            if [[ -f $STATE_FILE ]] && [[ "$(json_get "$STATE_FILE" backup)" == "$restore_path" ]]; then
                mv "$STATE_FILE" "$STATE_DIR/estado-restaurado-$(date +%s).json"
            fi
            return ;;
        publicar)
            load_installed_config
            [[ $(dirname -- "$SITE_DIR") == "$SCRIPT_DIR" ]] || die 'Ejecuta la copia de dns.sh que está junto a la carpeta original del sitio.'
            publish_site
            nginx -t
            systemctl reload nginx.service
            info "Archivos publicados. Abre http://$DOMAIN"
            return ;;
    esac
    [[ -f /etc/os-release ]] || die 'No se reconoce el sistema operativo.'
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ ${ID:-} == ubuntu ]] || die 'Este script está preparado para Ubuntu.'
    [[ -d /run/systemd/system ]] || die 'Se requiere Ubuntu iniciado con systemd.'
    command -v ip >/dev/null && command -v ss >/dev/null || die 'Falta iproute2. Instala: sudo apt-get install -y iproute2'
    command -v flock >/dev/null || die 'Falta flock (paquete util-linux).'
    install -d -m 700 "$STATE_DIR" "$BACKUP_BASE"
    if [[ -f $STATE_FILE ]]; then
        load_installed_config
        OLD_DOMAIN="$DOMAIN"
        OLD_SITE_DIR="$SITE_DIR"
        [[ -n $IFACE ]] || IFACE="$(json_get "$STATE_FILE" iface)"
    fi
    ask_domain
    if [[ -n $OLD_DOMAIN && $OLD_DOMAIN == "$DOMAIN" ]]; then
        info 'Este dominio ya está configurado. Usa --publicar para actualizar los archivos del sitio.'
        diagnostic
        return
    fi
    detect_network
    check_ports
    info "IP que se conservará: $CIDR | gateway $GATEWAY | interfaz $IFACE"
    warn 'Esta IP se hará fija en Ubuntu, pero NO quedará reservada en DHCP; puede haber colisiones futuras.'
    if [[ $IP == 10.0.2.* ]]; then warn 'Si usas VirtualBox, verifica el modo puente: 10.0.2.x suele ser una red NAT.'; fi
    info 'Instalando BIND9, Nginx y herramientas de diagnóstico.'
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y bind9 bind9-utils dnsutils nginx curl iproute2 iputils-arping python3-yaml
    detect_manager
    detect_upstreams
    # No asegura que DHCP no reasigne esta IP en el futuro.
    info 'Buscando conflictos ARP actuales (no reserva la IP en DHCP).'
    arping -D -I "$IFACE" -c 2 -w 3 "$IP" || die 'La prueba ARP no pasó. Revisa IP duplicada, adaptador o acceso a la LAN.'
    if [[ -z $OLD_DOMAIN ]] && grep -q 'BEGIN dns.sh ' /etc/bind/named.conf.local; then
        die 'Hay una configuración anterior sin estado registrado. Restaura su respaldo antes de instalar de nuevo.'
    fi
    create_backup
    resolve_dns_conflicts
    remove_old_domain_config
    configure_bind
    create_site
    configure_nginx
    configure_firewall
    configure_network
    configure_hosts
    # Reiniciar tras reactivar la tarjeta permite a named actualizar sus sockets.
    systemctl restart named.service
    verify_install
    write_guide
    cancel_timer
    [[ ! -e $BACKUP/restauracion-iniciada ]] || die 'Se activó la recuperación por tiempo excedido. Restaura y ejecuta de nuevo.'
    python3 - "$STATE_DIR/red.json" "$STATE_FILE" "$BACKUP" "$SITE_DIR" "$MANAGER" "$DOMAIN" "$STATE_DIR/upstreams.txt" <<'PY'
import json, pathlib, sys
d = json.load(open(sys.argv[1]))
d.update(backup=sys.argv[3], site_dir=sys.argv[4], manager=sys.argv[5], domain=sys.argv[6])
d['upstreams'] = [v.strip() for v in pathlib.Path(sys.argv[7]).read_text().splitlines() if v.strip()]
p = pathlib.Path(sys.argv[2]); temp = p.with_suffix('.tmp')
temp.write_text(json.dumps(d, indent=2) + '\n'); temp.chmod(0o600); temp.replace(p)
PY
    TRANSACTION=0
    trap - ERR HUP INT TERM
    info "Configuración terminada. En cada cliente configura DNS = $IP"
    printf '\nPágina: http://%s\nCarpeta editable: %s\nGuía de clientes: %s/LEEME.txt\n' "$DOMAIN" "$SITE_DIR" "$SITE_DIR"
    printf '\nPara publicar cambios: sudo bash dns.sh --publicar\n'
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
