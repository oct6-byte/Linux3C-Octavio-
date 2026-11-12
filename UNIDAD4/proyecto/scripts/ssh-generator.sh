#!/usr/bin/env bash
# ssh-generator.sh | Ubuntu: acceso SSH a root SOLO mediante llave Ed25519.
# Asistente interactivo para Ubuntu (cliente Windows PowerShell o Linux).
# Clave Ed25519 cifrada, root sin contraseña, ssh.service estable (sin activación por socket),
# validación por protocolo con reintentos y rollback de los cambios propios.
# Uso: sudo bash ssh-generator.sh [--diagnostico]
# Menú: 1) Instalar; 2) BORRADO TOTAL SSH del servidor; 3) Diagnóstico.
# IMPORTANTE: No cerrar la sesión administrativa antes de probar el cliente.
set -Eeuo pipefail
umask 077

CONF=/etc/ssh/sshd_config.d/00-ssh-generator.conf
AUTH=/root/.ssh/authorized_keys
SOCKET_CONF=/etc/systemd/system/ssh.socket.d/zz-ssh-generator.conf
BACKUP=''
TEMP_PUB=''
GENERATED=''
GEN_KEY_DIR=''
GEN_DIR_CREATED=0
GEN_DIR_META=''
TX_ACTIVE=0
COMMITTED=0
HAD_CONF=0
HAD_AUTH=0
HAD_SOCKET=0
ROOT_SSH_EXISTED=0
ROOT_SSH_META=''
SSHD_DROP_EXISTED=0
SOCKET_DROP_EXISTED=0
RUN_SSHD_EXISTED=0
PACKAGE_INSTALLED_BY_SCRIPT=0
SOCKET_WAS_ACTIVE=0
SERVICE_WAS_ACTIVE=0
SOCKET_ENABLE_BEFORE=''
SERVICE_ENABLE_BEFORE=''
UFW_RULE_ADDED=0
HOST_KEYS_ADDED=()
HOST_KEYS_ABSENT_PREINSTALL=()
OPERATOR="${SUDO_USER:-root}"
PORT=22
SERVER=''
SERVER_LOCAL=0
LOCAL_IPS=''
KEY=''
MODE=''
ANSWER=''

info() { printf '\n\033[1;36m%s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m! %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

prompt() {
  local result
  read -r -p "$1 [$2]: " result
  ANSWER="${result:-$2}"
}
confirm() {
  local answer
  read -r -p "$1 [s/N]: " answer
  [[ "$answer" =~ ^([sS]|[sS][iI])$ ]]
}
# Conserva modo, UID y GID para restaurar directorios previamente existentes.
meta() { stat -c '%a %u %g' -- "$1"; }
restore_meta() {
  local mode uid gid
  read -r mode uid gid <<< "$2"
  chown -- "$uid:$gid" "$1" && chmod -- "$mode" "$1"
}
restore_file() {
  local dest=$1 stored=$2 was_present=$3
  if (( was_present )); then
    cp -a -- "$BACKUP/$stored" "$dest"
    cmp -s -- "$BACKUP/$stored" "$dest"
  else
    rm -f -- "$dest"
    [[ ! -e "$dest" && ! -L "$dest" ]]
  fi
}
# Solo revierte cambios propios. NO elimina archivos anteriores ni llaves ajenas.
rollback_and_cleanup() {
  local rc=$? restore_error=0 k
  trap - EXIT INT TERM HUP
  set +e
  if (( ! COMMITTED )); then
    if (( TX_ACTIVE )); then
      warn 'Fallo detectado. Revirtiendo los cambios de ESTA ejecución...'
      restore_file "$CONF" sshd.conf "$HAD_CONF" || restore_error=1
      restore_file "$AUTH" authorized_keys "$HAD_AUTH" || restore_error=1
      restore_file "$SOCKET_CONF" socket.conf "$HAD_SOCKET" || restore_error=1

      # El firewall solo se revierte si se añadió una regla que no existía.
      if (( UFW_RULE_ADDED )); then
        ufw --force delete allow "$PORT/tcp" >/dev/null 2>&1 || restore_error=1
      fi

      # Restaura el estado de los servicios ANTES de retirar claves host nuevas.
      systemctl daemon-reload >/dev/null 2>&1 || restore_error=1
      if (( SOCKET_WAS_ACTIVE )); then
        systemctl restart ssh.socket >/dev/null 2>&1 || restore_error=1
      else
        systemctl stop ssh.socket >/dev/null 2>&1 || true
      fi
      if (( SERVICE_WAS_ACTIVE )); then
        systemctl try-reload-or-restart ssh.service >/dev/null 2>&1 || restore_error=1
      else
        systemctl stop ssh.service >/dev/null 2>&1 || true
      fi
      case "$SOCKET_ENABLE_BEFORE" in
        enabled) systemctl enable ssh.socket >/dev/null 2>&1 || restore_error=1 ;;
        disabled|not-found) systemctl disable ssh.socket >/dev/null 2>&1 || restore_error=1 ;;
      esac
      case "$SERVICE_ENABLE_BEFORE" in
        enabled) systemctl enable ssh.service >/dev/null 2>&1 || restore_error=1 ;;
        disabled|not-found) systemctl disable ssh.service >/dev/null 2>&1 || restore_error=1 ;;
      esac

      # Elimina las claves host que este script generó, únicamente si antes
      # no existía SSH activo. Nunca toca claves host preexistentes.
      if (( ! SOCKET_WAS_ACTIVE && ! SERVICE_WAS_ACTIVE )); then
        for k in "${HOST_KEYS_ADDED[@]}"; do rm -f -- "$k" || restore_error=1; done
      fi

      if (( ROOT_SSH_EXISTED )); then
        restore_meta /root/.ssh "$ROOT_SSH_META" || restore_error=1
      else
        rmdir -- /root/.ssh 2>/dev/null || true  # solo cuando esté vacío
      fi
      (( SOCKET_DROP_EXISTED )) || rmdir /etc/systemd/system/ssh.socket.d 2>/dev/null || true
      (( SSHD_DROP_EXISTED )) || rmdir /etc/ssh/sshd_config.d 2>/dev/null || true
      (( RUN_SSHD_EXISTED )) || rmdir /run/sshd 2>/dev/null || true
    fi
    if [[ -n "$GENERATED" ]]; then
      rm -f -- "$GENERATED" "$GENERATED.pub" || restore_error=1
      warn 'Se eliminaron la llave privada y pública creadas en esta ejecución.'
    fi
    if [[ -n "$GEN_KEY_DIR" ]]; then
      if (( GEN_DIR_CREATED )); then
        rmdir -- "$GEN_KEY_DIR" 2>/dev/null || true  # NO borra contenidos ajenos
      elif [[ -n "$GEN_DIR_META" ]]; then
        restore_meta "$GEN_KEY_DIR" "$GEN_DIR_META" || restore_error=1
      fi
    fi
    if (( PACKAGE_INSTALLED_BY_SCRIPT )); then
      warn "Se conserva el paquete openssh-server recién instalado; no se desinstalan paquetes automáticamente."
    fi
    if [[ -n "$BACKUP" && -d "$BACKUP" ]]; then
      if (( ! restore_error )); then
        rm -rf -- "$BACKUP" || restore_error=1
        rmdir /var/backups/ssh-generator 2>/dev/null || true
      fi
      if (( restore_error )); then
        warn "No fue posible verificar la restauración completa. Se conserva el respaldo: $BACKUP"
      else
        ok 'Se retiraron la configuración fallida, las llaves nuevas y el respaldo temporal de esta ejecución.'
      fi
    fi
  fi
  [[ -z "$TEMP_PUB" ]] || rm -f -- "$TEMP_PUB"
  if (( restore_error )); then exit 1; fi
  exit "$rc"
}
trap rollback_and_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# Borrado TOTAL solicitado expresamente: NO es un rollback, no tiene reversión.
# Solo afecta a ESTE servidor: nunca a las llaves privadas guardadas en Windows.
# Se limita a las ubicaciones convencionales /etc/ssh, /root/.ssh,
# /home/<usuario>/.ssh y las personalizaciones systemd de SSH. Una
# aplicación podría almacenar llaves en ubicaciones personalizadas.
full_ssh_reset() {
  local line answer1 answer2 dir done_errors=0
  local remote_re='\([^)]*\)'
  local -a user_dirs=()
  info 'ELIMINACIÓN TOTAL DE SSH (OPERACIÓN DESTRUCTIVA)'
  cat <<'TEXT'
El procedimiento BORRARÁ:
  - TODAS las llaves de host y archivos en /etc/ssh (servidor Y cliente).
  - /root/.ssh y las carpetas .ssh de TODOS los usuarios bajo /home.
    Incluye authorized_keys, privadas, públicas, config y known_hosts.
  - Ajustes de ssh.socket y ssh.service en /etc/systemd/system, incluidos overrides/masks.
  - Resguardos creados en /var/backups/ssh-generator.
  - El paquete openssh-server y las configuraciones que administra.
Después NO habrá servicio SSH disponible hasta reinstalarlo.
No se genera respaldo (por decisión explícita). Se conservan logs de sistema
(apt/journal), copias ajenas, llaves de Windows y llaves fuera de esas rutas.
Si tienes servicios que usan SSH, dejarán de autenticarse con esas llaves.

IMPORTANTE: hazlo EN LA CONSOLA LOCAL/GRÁFICA DE UBUNTU O VIRTUALBOX,
jamás desde una sesión SSH que necesites para recuperar el equipo.
TEXT
  if [[ -n "${SSH_CONNECTION:-}${SSH_CLIENT:-}${SSH_TTY:-}" ]]; then
    die 'Se detectó una sesión SSH. Para el borrado total, usa la consola local de Ubuntu/VirtualBox.'
  fi
  # Una shell elevada con sudo puede haber perdido variables SSH; comprobar
  # también quien está conectado al terminal, si hay registro de ese terminal.
  if command -v who >/dev/null 2>&1; then
    line="$(who -m 2>/dev/null || true)"
    if [[ "$line" =~ $remote_re && "$line" != *'(:'* ]]; then
      die "La sesión parece remota: $line. Ejecuta desde la consola local."
    fi
  fi
  [[ -t 0 ]] || die 'Necesitas una terminal interactiva para confirmar la eliminación total.'
  if [[ -d /root/.ssh || -L /root/.ssh ]]; then user_dirs+=(/root/.ssh); fi
  if [[ -d /home ]]; then
    while IFS= read -r -d '' dir; do user_dirs+=("$dir"); done < <(
      find /home -mindepth 2 -maxdepth 2 -name .ssh -print0 2>/dev/null
    )
  fi
  printf '\nCarpetas .ssh de cuentas locales detectadas (%d):\n' "${#user_dirs[@]}"
  if ((${#user_dirs[@]})); then printf '  %s\n' "${user_dirs[@]}"; else printf '  (ninguna)\n'; fi
  printf '\nTambién se eliminarán /etc/ssh, personalizaciones de systemd SSH y respaldos del generador.\n'
  printf 'Esta operación no puede deshacerse sin copias externas.\n'
  read -r -p 'Para continuar, escribe exactamente BORRAR TODO SSH: ' answer1
  [[ "$answer1" == 'BORRAR TODO SSH' ]] || { warn 'Cancelado sin modificar nada.'; return 0; }
  read -r -p 'Confirma de nuevo escribiendo SIN RESPALDO: ' answer2
  [[ "$answer2" == 'SIN RESPALDO' ]] || { warn 'Cancelado sin modificar nada.'; return 0; }

  # Evitar usar el rollback de instalación en una operación deliberadamente
  # destructiva. El usuario ya confirmó que NO desea recuperar ese estado.
  trap - EXIT INT TERM HUP
  info '1/3 · Detener SSH y retirar el paquete servidor'
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now ssh.socket ssh.service >/dev/null 2>&1 || \
      warn 'No se pudo deshabilitar alguna unidad (puede que no exista).'
    systemctl stop ssh.socket ssh.service >/dev/null 2>&1 || true
    # Un mask sobreviviente a apt purge impide iniciar SSH en la reinstalación.
    # El usuario pidió BORRADO TOTAL, por tanto retiramos masks de estas unidades.
    systemctl unmask ssh.socket ssh.service sshd.service >/dev/null 2>&1 || true
  fi
  if dpkg-query -W -f='${Status}' openssh-server 2>/dev/null | grep -q 'install ok installed'; then
    if ! DEBIAN_FRONTEND=noninteractive apt-get purge -y openssh-server; then
      warn 'APT falló. La eliminación fue interrumpida para evitar un estado indeterminado.'
      warn 'Comprueba los paquetes y servicios antes de repetir la operación.'
      return 1
    fi
  fi

  info '2/3 · Eliminar llaves, autorizaciones, configuración y respaldos SSH'
  for dir in "${user_dirs[@]}"; do
    # No se recorren enlaces: rm -rf elimina el enlace .ssh, NO su destino.
    rm -rf -- "$dir" || done_errors=1
  done
  rm -rf -- /etc/ssh \
    /etc/systemd/system/ssh.socket.d \
    /etc/systemd/system/ssh.service.d \
    /etc/systemd/system/ssh.socket \
    /etc/systemd/system/ssh.service \
    /etc/systemd/system/sshd.service \
    /var/backups/ssh-generator || done_errors=1

  info '3/3 · Verificar eliminación y refrescar systemd'
  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload || done_errors=1
  fi
  for dir in "${user_dirs[@]}" /etc/ssh \
    /etc/systemd/system/ssh.socket.d /etc/systemd/system/ssh.service.d \
    /etc/systemd/system/ssh.socket /etc/systemd/system/ssh.service \
    /etc/systemd/system/sshd.service /var/backups/ssh-generator; do
    if [[ -e "$dir" || -L "$dir" ]]; then
      warn "No se pudo eliminar completamente: $dir"
      done_errors=1
    fi
  done
  if (( done_errors )); then
    warn 'El borrado fue PARCIAL: revisa los mensajes anteriores. No se restauraron los cambios.'
    return 1
  fi
  ok 'Eliminación completa de las rutas SSH seleccionadas; servidor OpenSSH retirado.'
  printf '\nPara reconstruir SSH desde cero, ejecuta EN LA CONSOLA de Ubuntu:\n'
  printf '  sudo bash ssh-generator.sh\n  opción 1) Instalar y configurar SSH\n'
  printf '\nEn PowerShell, una vez verificada la NUEVA huella del servidor,\n'
  printf 'podría ser necesario actualizar la entrada de known_hosts.\n'
  printf 'No se borraron logs de sistema ni llaves fuera de las rutas indicadas.\n'
}

# Modo de diagnóstico: no cambia archivos ni servicios.
if [[ "${1:-}" == '--ayuda' || "${1:-}" == '-h' ]]; then
  printf 'Uso: sudo bash ssh-generator.sh [--diagnostico]\nSin parámetros: menú (instalar, eliminación total, diagnóstico).\n--diagnostico: verifica servicio, escucha y configuración sin cambiar nada.\n'
  exit 0
fi
if [[ -n "${1:-}" && "${1:-}" != '--diagnostico' ]]; then
  die 'Argumento desconocido. Usa --ayuda.'
fi
(( EUID == 0 )) || die 'Ejecuta: sudo bash ssh-generator.sh'
if [[ "${1:-}" == '--diagnostico' ]]; then
  printf '\n=== DIAGNÓSTICO SSH (sin modificar el sistema) ===\n'
  printf '\nIPv4 del servidor:\n'; ip -br -4 addr 2>&1 || true
  printf '\nEstado de unidades:\n'; systemctl --no-pager --full status ssh.socket ssh.service 2>&1 || true
  printf '\nEscucha TCP:\n'; ss -ltnp 2>&1 || true
  if [[ -x /usr/sbin/sshd ]]; then
    printf '\nSintaxis sshd -t:\n'; /usr/sbin/sshd -t 2>&1 || true
    printf '\nPolítica root efectiva:\n'
    /usr/sbin/sshd -T -C user=root,host=localhost,addr=127.0.0.1 2>&1 | \
      grep -E '^(port|listenaddress|permitrootlogin|pubkeyauthentication|authorizedkeysfile|authenticationmethods) ' || true
  else
    printf '\nOpenSSH server no está instalado.\n'
  fi
  printf '\nÚltimos mensajes del servicio:\n'
  journalctl --no-pager -u ssh.socket -u ssh.service -n 15 2>&1 || true
  exit 0
fi
[[ -t 0 ]] || die 'Usa una terminal interactiva.' 
[[ -r /etc/os-release ]] || die 'No se pudo identificar Ubuntu.'
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == ubuntu ]] || die 'Este script está diseñado para Ubuntu.'
for cmd in apt-get systemctl mktemp awk stat; do
  command -v "$cmd" >/dev/null || die "No se encontró el comando: $cmd"
done

info 'MENÚ PRINCIPAL · SSH UBUNTU'
printf '%s\n' \
  '  1) Instalar/configurar SSH y llaves para root (modo habitual)' \
  '  2) ELIMINAR TODAS las llaves y configuraciones SSH locales (destructivo)' \
  '  3) Mostrar diagnóstico SSH (sin modificar el sistema)' \
  '  0) Salir'
while :; do
  prompt 'Selecciona 0/1/2/3' '1'
  case "$ANSWER" in
    0) printf 'Cancelado.\n'; exit 0 ;;
    1) break ;;
    2) full_ssh_reset; exit $? ;;
    3) exec bash "$0" --diagnostico ;;
    *) warn 'Opción inválida.' ;;
  esac
done

# Ubuntu mínimo puede no tener el cliente SSH instalado. No exigir
# ssh-keygen para el menú de eliminación o para el diagnóstico.
if ! command -v ssh-keygen >/dev/null 2>&1; then
  info 'Instalar utilidad ssh-keygen (paquete openssh-client)'
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-client
fi

info 'ASISTENTE SSH PARA ROOT (SOLO CON LLAVES)'
printf '%s\n' 'Se configura root únicamente con autenticación de llave pública.' \
  'Mantén abierta la sesión administrativa actual hasta probar el acceso nuevo.'
# No presumir una IP fija: en máquinas virtuales puede cambiar por DHCP o NAT.
if command -v ip >/dev/null 2>&1; then
  LOCAL_IPS="$(ip -o -4 addr show scope global 2>/dev/null | awk '{split($4, a, "/"); print a[1]}' | sort -u | tr '\n' ' ')"
fi
if [[ -z "$LOCAL_IPS" ]] && command -v hostname >/dev/null 2>&1; then
  LOCAL_IPS="$(hostname -I 2>/dev/null || true)"
fi
SERVER="${LOCAL_IPS%% *}"
[[ -n "$SERVER" ]] || SERVER='10.10.31.73'
printf 'Direcciones IPv4 detectadas en ESTA máquina: %s\n' "${LOCAL_IPS:-ninguna; verificar con ip -br -4 addr}"
while :; do
  prompt 'IP/DNS DEL SERVIDOR (para conectarte desde OTRA computadora)' "$SERVER"
  [[ "$ANSWER" =~ ^[a-zA-Z0-9.-]+$ ]] && { SERVER="$ANSWER"; break; }
  warn 'IP o nombre DNS inválido.'
done
# Una IP pública/NAT puede no figurar en las interfaces locales; por ello se avisa
# y se pide confirmación, sin sobrescribir ninguna dirección por suposición.
if [[ "$SERVER" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  if [[ " $LOCAL_IPS " == *" $SERVER "* ]]; then
    SERVER_LOCAL=1
  else
    warn "La dirección $SERVER NO aparece asignada a esta máquina."
    warn "IP(s) locales: ${LOCAL_IPS:-ninguna}. Confirma red/NAT/puente de VirtualBox."
    if ! confirm '¿Continuar usando esa IP en los comandos de ejemplo?'; then
      die 'Corrige la IP del servidor y vuelve a ejecutar; no se realizaron cambios de SSH.'
    fi
  fi
fi
while :; do
  prompt 'Puerto SSH' '22'
  if [[ "$ANSWER" =~ ^[0-9]{1,5}$ ]] && (( 10#$ANSWER >= 1 && 10#$ANSWER <= 65535 )); then
    PORT=$((10#$ANSWER)); break
  fi
  warn 'El puerto debe estar entre 1 y 65535.'
done

info '¿Cómo quieres configurar la llave pública?'
printf '%s\n' \
 '  1) Generar nueva llave Ed25519 cifrada en este servidor' \
 '  2) Pegar llave pública existente (recomendado)' \
 '  3) Elegir archivo .pub existente en el servidor'
while :; do
  prompt 'Opción 1/2/3' '1'
  [[ "$ANSWER" =~ ^[123]$ ]] && { MODE="$ANSWER"; break; }
  warn 'Escribe 1, 2 o 3.'
done

if [[ "$MODE" == 1 ]]; then
  if [[ "$OPERATOR" != root ]] && id "$OPERATOR" >/dev/null 2>&1; then
    HOME_DIR="$(getent passwd "$OPERATOR" | cut -d: -f6)"
    [[ -n "$HOME_DIR" && -d "$HOME_DIR" ]] || die "No existe la carpeta personal de $OPERATOR."
  else
    OPERATOR=root
    HOME_DIR=/root
  fi
  GEN_KEY_DIR="$HOME_DIR/.ssh"
  [[ ! -L "$GEN_KEY_DIR" ]] || die 'No se admiten enlaces simbólicos para guardar llaves.'
  if [[ -d "$GEN_KEY_DIR" ]]; then
    GEN_DIR_META="$(meta "$GEN_KEY_DIR")"
  elif [[ -e "$GEN_KEY_DIR" ]]; then
    die 'La carpeta .ssh está ocupada por un archivo.'
  else
    install -d -m 700 -o "$OPERATOR" -g "$(id -gn "$OPERATOR")" "$GEN_KEY_DIR"
    GEN_DIR_CREATED=1
  fi
  chown "$OPERATOR:$(id -gn "$OPERATOR")" "$GEN_KEY_DIR"
  chmod 700 "$GEN_KEY_DIR"
  prompt 'Nombre de llave (sin rutas)' 'id_ed25519_root_ubuntu'
  [[ "$ANSWER" =~ ^[a-zA-Z0-9_-]+$ ]] || die 'Usa letras, números, _ o -.'
  GENERATED="$GEN_KEY_DIR/$ANSWER"
  if [[ -e "$GENERATED" || -L "$GENERATED" || -e "$GENERATED.pub" || -L "$GENERATED.pub" ]]; then
    GENERATED=''
    die 'Ese nombre ya existe: ninguna llave anterior será sobrescrita.'
  fi
  info 'Generar llave (introduce dos veces la frase de paso; no se muestra)'
  if [[ "$OPERATOR" == root ]]; then
    ssh-keygen -q -t ed25519 -a 100 -f "$GENERATED" -C "root@$(hostname -s)"
  else
    runuser -u "$OPERATOR" -- ssh-keygen -q -t ed25519 -a 100 \
      -f "$GENERATED" -C "root@$(hostname -s)"
  fi
  [[ -s "$GENERATED" && -s "$GENERATED.pub" ]] || die 'No se generaron ambas llaves.'
  if ssh-keygen -y -P '' -f "$GENERATED" >/dev/null 2>&1; then
    die 'La llave privada no tiene frase de paso: debe estar cifrada.'
  fi
  KEY="$(cat "$GENERATED.pub")"
elif [[ "$MODE" == 2 ]]; then
  printf '\nPega UNA línea pública ssh-ed25519 (nunca tu clave PRIVADA):\n'
  read -r KEY
else
  read -r -p 'Ruta absoluta del archivo .pub: ' FILE
  [[ -f "$FILE" && -r "$FILE" ]] || die 'Archivo público inaccesible.'
  KEY="$(cat "$FILE")"
fi

[[ "$KEY" != *$'\n'* && "$KEY" != *$'\r'* ]] || die 'La clave pública debe ser una sola línea.'
[[ "$KEY" =~ ^ssh-ed25519[[:space:]]+[A-Za-z0-9+/]+={0,2}([[:space:]].*)?$ ]] || die 'Clave pública Ed25519 inválida.'
TEMP_PUB="$(mktemp)"
printf '%s\n' "$KEY" > "$TEMP_PUB"
if ! FINGERPRINT="$(ssh-keygen -lf "$TEMP_PUB" -E sha256 2>&1)"; then
  die "Clave pública no válida: $FINGERPRINT"
fi
rm -f -- "$TEMP_PUB"; TEMP_PUB=''

info 'REVISAR OPCIONES'
printf 'Servidor: %s\nPuerto: %s\nAcceso root: exclusivamente mediante llave\nHuella: %s\n' \
  "$SERVER" "$PORT" "$FINGERPRINT"
if ! confirm '¿Instalar y activar esta configuración?'; then
  printf 'Cancelado. Se limpiarán las claves generadas en esta ejecución.\n'
  exit 0
fi

# Capturar el estado ANTES de instalar paquetes: apt puede habilitar ssh.socket.
# Una llave host creada por apt/ssh-keygen durante esta ejecución se podrá
# retirar sin tocar nunca una llave host que ya existiera antes.
systemctl is-active -q ssh.socket && SOCKET_WAS_ACTIVE=1 || true
systemctl is-active -q ssh.service && SERVICE_WAS_ACTIVE=1 || true
SOCKET_ENABLE_BEFORE="$(systemctl is-enabled ssh.socket 2>/dev/null || printf 'not-found')"
SERVICE_ENABLE_BEFORE="$(systemctl is-enabled ssh.service 2>/dev/null || printf 'not-found')"
for k in /etc/ssh/ssh_host_rsa_key /etc/ssh/ssh_host_rsa_key.pub \
         /etc/ssh/ssh_host_ecdsa_key /etc/ssh/ssh_host_ecdsa_key.pub \
         /etc/ssh/ssh_host_ed25519_key /etc/ssh/ssh_host_ed25519_key.pub; do
  [[ -e "$k" ]] || HOST_KEYS_ABSENT_PREINSTALL+=("$k")
done

info '1/4 · Instalar OpenSSH y preparar el respaldo'
if ! dpkg-query -W -f='${Status}' openssh-server 2>/dev/null | grep -q 'install ok installed'; then
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server
  PACKAGE_INSTALLED_BY_SCRIPT=1
fi
[[ -x /usr/sbin/sshd && -f /etc/ssh/sshd_config ]] || die 'La instalación de openssh-server es incompleta.'
grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config || \
  die 'sshd_config no incluye /etc/ssh/sshd_config.d/*.conf; revisa antes de continuar.'
for item in "$CONF" "$AUTH" "$SOCKET_CONF"; do
  [[ ! -L "$item" ]] || die "No se modificará un enlace simbólico: $item"
  [[ ! -e "$item" || -f "$item" ]] || die "No es archivo normal: $item"
done

# Capturar condiciones anteriores ANTES de hacer cambios al servicio y los archivos.
[[ -d /root/.ssh ]] && { ROOT_SSH_EXISTED=1; ROOT_SSH_META="$(meta /root/.ssh)"; }
[[ -d /etc/ssh/sshd_config.d ]] && SSHD_DROP_EXISTED=1
[[ -d /etc/systemd/system/ssh.socket.d ]] && SOCKET_DROP_EXISTED=1
[[ -d /run/sshd ]] && RUN_SSHD_EXISTED=1
[[ -d /var/backups/ssh-generator ]] || install -d -m 700 /var/backups/ssh-generator
BACKUP="$(mktemp -d /var/backups/ssh-generator/rollback-XXXXXXXX)"
if [[ -f "$CONF" ]]; then cp -a -- "$CONF" "$BACKUP/sshd.conf"; HAD_CONF=1; fi
if [[ -f "$AUTH" ]]; then cp -a -- "$AUTH" "$BACKUP/authorized_keys"; HAD_AUTH=1; fi
if [[ -f "$SOCKET_CONF" ]]; then cp -a -- "$SOCKET_CONF" "$BACKUP/socket.conf"; HAD_SOCKET=1; fi
TX_ACTIVE=1

# Los directorios y llaves host se generan ya bajo control de la transacción.
[[ -d /etc/ssh/sshd_config.d ]] || install -d -m 755 /etc/ssh/sshd_config.d
[[ -d /run/sshd ]] || install -d -m 755 /run/sshd
[[ -d /root/.ssh ]] || install -d -m 700 /root/.ssh
# Solo se registran como descartables las llaves que NO existían al empezar.
HOST_KEYS_ADDED=("${HOST_KEYS_ABSENT_PREINSTALL[@]}")
ssh-keygen -A >/dev/null

info '2/4 · Autorizar la llave e instalar la configuración'
KEY_BODY="$(awk '{print $2}' <<< "$KEY")"
if [[ -f "$AUTH" ]] && awk -v k="$KEY_BODY" \
  '$1=="ssh-ed25519" && $2==k {f=1} END{exit !f}' "$AUTH"; then
  ok 'La llave pública ya estaba autorizada para root.'
else
  printf '\n%s\n' "$KEY" >> "$AUTH"
  ok 'Se añadió la nueva llave pública a root.'
fi
chown root:root /root/.ssh "$AUTH"
chmod 700 /root/.ssh
chmod 600 "$AUTH"
cat > "$CONF" <<EOF
# Archivo administrado por ssh-generator.sh. NO desactiva las contraseñas de otros usuarios.
Port $PORT
PubkeyAuthentication yes
PermitRootLogin prohibit-password
EOF
chmod 600 "$CONF"
# Una versión anterior generaba este drop-in de ssh.socket. Esta versión usa
# ssh.service directo, por lo que retirarlo evita que quede una configuración
# inerte que podría interferir en futuras activaciones por socket.
# Ya está incluido en el respaldo transaccional, si existía.
if [[ -f "$SOCKET_CONF" ]]; then rm -f -- "$SOCKET_CONF"; fi

info '3/4 · Revisar sintaxis y política SSH efectiva'
if ! TEST_OUTPUT="$(/usr/sbin/sshd -t -f /etc/ssh/sshd_config 2>&1)"; then
  printf '\nError detallado de sshd -t:\n%s\n' "$TEST_OUTPUT" >&2
  die 'La configuración SSH es inválida.'
fi
if ! EFFECTIVE="$(/usr/sbin/sshd -T -C user=root,host=localhost,addr=127.0.0.1 2>&1)"; then
  printf '\nError detallado de sshd -T:\n%s\n' "$EFFECTIVE" >&2
  die 'No se pudo comprobar la política efectiva.'
fi
# OpenSSH puede imprimir 'without-password' incluso cuando el archivo usa
# 'prohibit-password': son SINÓNIMOS según sshd_config(5). Comparar la salida
# literalmente provocaba un falso conflicto y borraba innecesariamente las llaves.
ROOT_POLICY="$(awk '$1 == "permitrootlogin" { print $2; exit }' <<< "$EFFECTIVE")"
case "$ROOT_POLICY" in
  prohibit-password)
    ok 'PermitRootLogin efectivo: prohibit-password (solo acceso sin contraseña).'
    ;;
  without-password)
    ok 'PermitRootLogin efectivo: without-password (alias equivalente a prohibit-password).'
    ;;
  *)
    printf '\nValor efectivo de PermitRootLogin: %s\n' "${ROOT_POLICY:-desconocido}" >&2
    warn 'Política SSH real incompatible; las claves nuevas no se conservarán.'
    warn 'Busca precedencia de PermitRootLogin y bloques Match en:'
    grep -HnEi '^[[:space:]]*(Match|Include|PermitRootLogin)[[:space:]]' \
      /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf >&2 || true
    die 'PermitRootLogin no permite el acceso root exclusivamente sin contraseña. Revirtiendo esta ejecución.'
    ;;
esac
grep -qx 'pubkeyauthentication yes' <<< "$EFFECTIVE" || die 'Hay una directiva previa que desactiva las llaves públicas.'
grep -qx "port $PORT" <<< "$EFFECTIVE" || die 'Hay una directiva previa que anula el puerto elegido.'
grep '^authorizedkeysfile ' <<< "$EFFECTIVE" | grep -Eq '(\.ssh/authorized_keys|/root/\.ssh/authorized_keys)' || \
  die 'La configuración efectiva no consulta /root/.ssh/authorized_keys.'
AUTH_METHODS="$(awk '$1=="authenticationmethods" {print $2; exit}' <<< "$EFFECTIVE")"
case "${AUTH_METHODS:-any}" in
  any|publickey) ;;
  *) warn "AuthenticationMethods efectivo: $AUTH_METHODS";
     die 'La configuración exige métodos adicionales incompatibles con la conexión mediante una sola llave.' ;;
esac
ok 'Política SSH válida: root con llave pública y sin contraseña.' 

info '4/4 · Iniciar ssh.service y comprobar conectividad'
# En Ubuntu 24.04+ el socket activation es predeterminado; tras eliminar
# todas las configuraciones puede fallar la activación del daemon por socket.
# Elegimos el servicio tradicional, que escucha en el puerto de sshd_config.
# No se cambia el mecanismo por sorpresa a una sesión remota.
if [[ -n "${SSH_CONNECTION:-}${SSH_CLIENT:-}${SSH_TTY:-}" ]]; then
  die 'El cambio de mecanismo SSH exige usar consola local/VirtualBox para evitar perder la sesión.'
fi
systemctl daemon-reload
if [[ "$(systemctl is-enabled ssh.service 2>/dev/null || true)" == masked ]]; then
  die 'ssh.service está bloqueado (masked). Revisa: systemctl is-enabled ssh.service.'
fi
# Detenemos el socket antes de iniciar ssh.service para que el nuevo daemon
# pueda reservar el puerto por sí mismo. NO desinstalamos servicios ni llaves.
if systemctl cat ssh.socket >/dev/null 2>&1; then
  systemctl disable --now ssh.socket >/dev/null 2>&1 || \
    warn 'ssh.socket no se pudo deshabilitar; se intentará detenerlo.'
  systemctl stop ssh.socket >/dev/null 2>&1 || true
fi
# Si una versión anterior dejó ssh.service habilitado, reiniciarlo fuerza
# lectura de la nueva configuración y evita usar el socket antiguo.
if ! systemctl enable --now ssh.service; then
  warn 'Fallo al iniciar ssh.service. Estado real:'
  systemctl --no-pager --full status ssh.service ssh.socket >&2 || true
  journalctl --no-pager -u ssh.service -n 30 >&2 || true
  die 'ssh.service no se pudo activar; se restaurará el estado previo.'
fi
if ! systemctl restart ssh.service; then
  warn 'Falló el reinicio de ssh.service. Diagnóstico:'
  systemctl --no-pager --full status ssh.service >&2 || true
  journalctl --no-pager -u ssh.service -n 30 >&2 || true
  die 'El demonio SSH no pudo iniciar con la nueva configuración.'
fi
systemctl is-active -q ssh.service || die 'ssh.service no está activo tras el reinicio.'
ok 'ssh.service activo; ssh.socket no interfiere con el puerto.'

# Antes había una condición demasiado estricta: debían responder localhost
# Y la primera IP de red, lo cual fallaba con interfaces o rutas especiales.
# Ahora basta una negociación SSH real con alguna dirección local; verificamos
# loopback primero, con reintentos y errores visibles si falla.
if ! command -v ss >/dev/null 2>&1; then
  die 'Falta el comando ss (paquete iproute2); no es posible comprobar el puerto.'
fi
if ! ss -H -ltn "sport = :$PORT" | grep -q .; then
  warn "No existe un listener TCP en puerto $PORT. Estado y registros:"
  systemctl --no-pager --full status ssh.service >&2 || true
  journalctl --no-pager -u ssh.service -n 25 >&2 || true
  die "SSH no está escuchando en TCP/$PORT."
fi
printf 'Escucha TCP encontrada:\n'
ss -ltnp "sport = :$PORT" || true

PROBE_OK=0
if command -v ssh-keyscan >/dev/null 2>&1; then
  PROBE_HOSTS=(127.0.0.1)
  while IFS= read -r loc_ip; do
    [[ -n "$loc_ip" ]] && PROBE_HOSTS+=("$loc_ip")
  done < <(tr ' ' '\n' <<< "$LOCAL_IPS" | sed '/^$/d')
  PROBE_MESSAGE=''
  for PROBE_HOST in "${PROBE_HOSTS[@]}"; do
    for ATTEMPT in 1 2 3; do
      PROBE_OUTPUT="$(ssh-keyscan -T 8 -t ed25519 -p "$PORT" "$PROBE_HOST" 2>&1 || true)"
      if awk 'NF >= 3 && $2 == "ssh-ed25519" {found=1} END {exit !found}' <<< "$PROBE_OUTPUT"; then
        ok "Servidor SSH responde en $PROBE_HOST:$PORT (intento $ATTEMPT)."
        PROBE_OK=1
        break 2
      fi
      PROBE_MESSAGE="$PROBE_OUTPUT"
      sleep 1
    done
  done
else
  warn 'ssh-keyscan no disponible; se verificará el banner por TCP si está timeout.'
fi
# Fallback sin exigir una prueba en CADA interfaz. Solo si falla keyscan.
if (( ! PROBE_OK )) && command -v timeout >/dev/null 2>&1; then
  for PROBE_HOST in 127.0.0.1 ${LOCAL_IPS:-}; do
    if PROBE_HOST="$PROBE_HOST" PROBE_PORT="$PORT" timeout 8 bash -c '
      exec 3<>/dev/tcp/"$PROBE_HOST"/"$PROBE_PORT" || exit 1
      IFS= read -r -t 5 header <&3 || exit 1
      [[ "$header" == SSH-2.0-* ]]' 2>/dev/null; then
      ok "Banner SSH-2.0 recibido en $PROBE_HOST:$PORT."
      PROBE_OK=1
      break
    fi
  done
fi
if (( ! PROBE_OK )); then
  warn "SSH escucha TCP/$PORT, pero NO completó el saludo de protocolo."
  warn "Última respuesta de ssh-keyscan: ${PROBE_MESSAGE:-ninguna}"
  warn 'Revisa logs (se muestran ANTES del rollback):'
  systemctl --no-pager --full status ssh.service ssh.socket >&2 || true
  journalctl --no-pager -u ssh.service -u ssh.socket -n 45 >&2 || true
  die 'La validación real de OpenSSH falló; restaurando la configuración previa.'
fi
# La IP externa puede no ser una dirección local en NAT/VirtualBox; no se exige
# que esté disponible desde el propio servidor para declarar SSH instalado.
if (( SERVER_LOCAL )) && [[ "$SERVER" != 127.0.0.1 ]]; then
  if ! ssh-keyscan -T 5 -t ed25519 -p "$PORT" "$SERVER" 2>/dev/null | \
       awk 'NF >= 3 && $2 == "ssh-ed25519" {found=1} END {exit !found}'; then
    warn "El protocolo SSH NO respondió en $SERVER:$PORT desde Ubuntu."
    warn 'El servicio se conserva porque sí respondió en una dirección local.'
    warn 'Comprueba ListenAddress, IP y red de VirtualBox antes de usar PowerShell.'
  else
    ok "SSH también responde en la IP seleccionada $SERVER:$PORT."
  fi
fi

# El firewall se cambia AL FINAL, después de validar configuración y servicio.
if command -v ufw >/dev/null && ufw status | grep -qi '^Status: active'; then
  if confirm "UFW activo. ¿Abrir el puerto TCP/$PORT?"; then
    # Si ya existía una regla explícita de autorización, NO alterarla ni eliminarla.
    if ufw status | awk -v p="$PORT/tcp" '$1==p && $2=="ALLOW" {found=1} END{exit !found}'; then
      ok 'UFW ya tiene una regla de autorización para ese puerto.'
    else
      UFW_RULE_ADDED=1
      ufw allow "$PORT/tcp"
    fi
  else
    die "UFW activo: no se aplican cambios sin permitir TCP/$PORT."
  fi
fi

COMMITTED=1
ok 'SSH instalado: servicio clásico activo y saludo SSH local comprobado.'
printf '\n===== DATOS DEL SERVIDOR =====\nIP indicada: %s\nIP(s) locales: %s\nPuerto: %s\n' \
  "$SERVER" "${LOCAL_IPS:-desconocidas}" "$PORT"
if [[ "$SERVER_LOCAL" == 0 ]]; then
  warn 'La IP indicada no está en las interfaces locales: una conexión a esa IP podría ser RECHAZADA.'
  warn 'Si VirtualBox usa NAT, configura red puente o redirección de puerto hacia la VM.'
fi
printf 'Escucha TCP local (verificar dirección de escucha):\n'
ss -ltn "sport = :$PORT" 2>/dev/null || true
printf 'IMPORTANTE: aún debes probar desde OTRO equipo de la misma red.\n'
printf 'Respaldo de archivos anteriores: %s\n' "$BACKUP"
if [[ "$MODE" == 1 ]]; then
  printf '\nClave privada temporalmente EN UBUNTU: %s\n' "$GENERATED"
  if [[ "$OPERATOR" != root ]]; then
    printf '\n=== EJECUTAR SOLO EN WINDOWS POWERSHELL (EN OTRA COMPUTADORA) ===\n'
    printf '  Test-NetConnection %s -Port %s\n' "$SERVER" "$PORT"
    printf '  New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\.ssh"\n'
    printf '  scp -P %s %s@%s:%s "$env:USERPROFILE\.ssh\%s"\n' "$PORT" "$OPERATOR" "$SERVER" "$GENERATED" "${GENERATED##*/}"
    printf '  $key = "$env:USERPROFILE\.ssh\%s"\n' "${GENERATED##*/}"
    printf '  icacls $key /inheritance:r\n'
    printf '  icacls $key /grant:r "$($env:USERNAME):(R)"\n'
    printf '  ssh -p %s -i "$env:USERPROFILE\.ssh\%s" root@%s\n' "$PORT" "${GENERATED##*/}" "$SERVER"
  else
    warn 'La llave se generó como root en Ubuntu. Transfiérela al cliente por un canal seguro: scp con vboxuser no tendrá acceso a /root/.ssh.'
  fi
  printf '\nTRAS confirmar acceso desde Windows, eliminar SOLO la PRIVADA del servidor Ubuntu:\n'
  printf '  sudo rm -f -- %q\n' "$GENERATED"
else
  printf '\nDesde Windows PowerShell (la llave PRIVADA ya está en el cliente):\n'
  printf '  ssh -p %s -i "$env:USERPROFILE\.ssh\NOMBRE_LLAVE" root@%s\n' "$PORT" "$SERVER"
fi
printf '\nSI DESDE EL CLIENTE APARECE Connection refused:\n'
printf '  EN ESTE SERVIDOR ejecuta: ip -br -4 addr; sudo systemctl status ssh.socket ssh.service --no-pager; sudo ss -ltnp\n'
printf '  Comprueba la IP verdadera del servidor y que el TCP/%s esté accesible desde el cliente.\n' "$PORT"
printf '\nNO cierres la sesión actual hasta haber comprobado el nuevo acceso.\n'
