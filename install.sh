#!/usr/bin/env bash
#
# install.sh — deja nginx-sync andando como servicio de systemd, desde cero.
#
# Si todavía no clonaste el repo, empezá por bootstrap.sh, que baja el código y
# después corre esto:
#
#   curl -fsSL https://raw.githubusercontent.com/aramirez92/nginx-sync/main/bootstrap.sh | sudo bash
#
#   sudo ./install.sh                     # instala todo (pregunta lo que falte)
#   sudo ./install.sh --dry-run           # muestra el plan, sin tocar nada
#   sudo -E ./install.sh --non-interactive  # desatendido, con ENDPOINT_URL en el entorno
#
# En un servidor limpio resuelve todo solo: instala las herramientas de sistema
# que falten (curl, unzip, nginx, sudo...), baja bun, baja nvm + Node LTS, arma
# el .env con un wizard si no existe, crea el usuario de servicio, instala la
# regla de sudoers, enlaza /etc/nginx/sites-enabled a este directorio (con
# backup) y arranca la unidad.
#
# Todo se valida ANTES de mutar nada: primero una fase de preflight de solo
# lectura que junta el plan completo y lo imprime; recién después se ejecuta.
#
# Sobre bun: resuelve la ruta REAL del binario. Si cuelga de un home inaccesible
# (p.ej. /root/.bun/bin/bun, con /root en 700), lo copia a /usr/local/bin. Un
# symlink no arregla los permisos del directorio y systemd falla con 203/EXEC:
# el usuario del servicio no puede atravesar /root.

set -euo pipefail

SERVICE_USER="nginx-sync"
DRY_RUN=0
WITH_RELOAD=1
INSTALL_DEPS=1
WITH_NVM=1
INTERACTIVE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT_TEMPLATE="$SCRIPT_DIR/deploy/nginx-sync.service"
UNIT_PATH="/etc/systemd/system/nginx-sync.service"
SUDOERS_PATH="/etc/sudoers.d/nginx-sync"
SITES_LINK="${NGINX_SITES_ENABLED:-/etc/nginx/sites-enabled}"
SITES_TARGET="$SCRIPT_DIR/sites-enabled"
ENV_FILE="$SCRIPT_DIR/.env"
ENV_EXAMPLE="$SCRIPT_DIR/.env.example"
BUN_TARGET="/usr/local/bin/bun"
NVM_DIR="/usr/local/nvm"
NVM_VERSION="v0.40.3"   # fijada a propósito: 'master' puede romper sin aviso

# Valores de configuración: flag > entorno > wizard > default.
CFG_ENDPOINT_URL="${ENDPOINT_URL:-}"
CFG_SYNC_TOKEN="${SYNC_TOKEN:-}"
CFG_ENDPOINT_AUTH="${ENDPOINT_AUTH:-}"
CFG_PORT="${PORT:-}"
CFG_OUTPUT_FILENAME="${OUTPUT_FILENAME:-}"

# El '|| true' es para cuando se cae la sesión SSH: escribir en una terminal
# muerta falla, y sin esto errexit mataría una instalación que puede seguir.
log()  { printf '[install] %s\n' "$*" || true; }
warn() { printf '[install] AVISO: %s\n' "$*" >&2 || true; }
fail() { printf '[install] ERROR: %s\n' "$*" >&2 || true; exit 1; }
step() { printf '\n[install] == %s ==\n' "$*" || true; }

usage() {
  cat <<'EOF'
install.sh — deja nginx-sync andando como servicio de systemd, desde cero.

  sudo ./install.sh                       instala todo (pregunta lo que falte)
  sudo ./install.sh --dry-run             muestra el plan, sin tocar nada
  sudo -E ./install.sh --non-interactive  desatendido, con la config en el entorno

Flags:
  --dry-run              imprime el plan y sale; no escribe nada
  --no-reload            sin regla de sudoers ni reload de nginx
  --no-install-deps      valida las dependencias del sistema pero no las instala
  --no-nvm               omite la instalación de nvm + Node LTS
  --non-interactive, -y  nunca pregunta; falla si falta config obligatoria
  --endpoint-url URL     valores para el .env (equivalen a ENDPOINT_URL, etc.)
  --sync-token TOKEN
  --endpoint-auth VALOR
  --port N
  -h, --help             esta ayuda
EOF
  exit 0
}

need_value() { [[ $# -ge 2 && -n "${2:-}" ]] || fail "$1 necesita un valor."; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)             DRY_RUN=1; shift ;;
    --no-reload)           WITH_RELOAD=0; shift ;;
    --no-install-deps)     INSTALL_DEPS=0; shift ;;
    --no-nvm)              WITH_NVM=0; shift ;;
    --non-interactive|-y)  INTERACTIVE=0; shift ;;
    --endpoint-url)        need_value "$1" "${2:-}"; CFG_ENDPOINT_URL="$2"; shift 2 ;;
    --sync-token)          need_value "$1" "${2:-}"; CFG_SYNC_TOKEN="$2"; shift 2 ;;
    --endpoint-auth)       need_value "$1" "${2:-}"; CFG_ENDPOINT_AUTH="$2"; shift 2 ;;
    --port)                need_value "$1" "${2:-}"; CFG_PORT="$2"; shift 2 ;;
    -h|--help)             usage ;;
    *)                     fail "Opción desconocida: $1 (probá --help)" ;;
  esac
done

# Sin TTY no se puede preguntar nada, aunque nadie haya pasado --non-interactive.
if [[ $INTERACTIVE -eq 1 && ! -t 0 && ! -e /dev/tty ]]; then
  INTERACTIVE=0
fi

if [[ $DRY_RUN -eq 0 && $EUID -ne 0 ]]; then
  fail "este script necesita root. Ejecutá: sudo $0"
fi

[[ -f "$UNIT_TEMPLATE" ]] || fail "falta $UNIT_TEMPLATE. ¿Corriste el script desde la raíz del repo?"
[[ -f "$ENV_EXAMPLE" ]]   || fail "falta $ENV_EXAMPLE. ¿Corriste el script desde la raíz del repo?"

# Sobrevivir a que se caiga la sesión --------------------------------------
#
# En Raspberry Pi OS un apt puede reiniciar servicios de sesión (needrestart,
# los servicios de usuario de rpi-connect) y tirar la conexión SSH. Si eso pasa
# a mitad de la instalación, el sistema queda a medias. Ignorar SIGHUP deja que
# el script termine igual aunque la terminal desaparezca, y todo queda además
# en el log, para leerlo al reconectar.
trap '' HUP
trap '' PIPE

LOG_FILE="/var/log/nginx-sync-install.log"
if [[ $DRY_RUN -eq 0 && $EUID -eq 0 ]]; then
  # --output-error=warn: si la terminal muere, tee sigue escribiendo el archivo
  # en vez de abortar y llevarse el script puesto. Si la versión de tee no lo
  # soporta, se usa el modo normal.
  if tee --output-error=warn </dev/null >/dev/null 2>&1; then
    exec > >(tee -a --output-error=warn "$LOG_FILE") 2>&1
  else
    exec > >(tee -a "$LOG_FILE") 2>&1
  fi
  log "log completo en $LOG_FILE"
fi

# Y evitar el reinicio en primer lugar: needrestart reinicia servicios solo
# durante apt, incluidos los de la sesión.
export NEEDRESTART_SUSPEND=1
export NEEDRESTART_MODE=l

# ===========================================================================
# Utilidades
# ===========================================================================

have() { command -v "$1" >/dev/null 2>&1; }

# Lee una clave de un archivo .env. Sin trim de comillas: el formato es plano.
env_get() {
  local key="$1" file="$2"
  [[ -f "$file" ]] || return 1
  sed -n "s/^${key}=//p" "$file" | head -1
}

# Reemplaza (o agrega) una clave conservando los comentarios del archivo.
env_set() {
  local key="$1" val="$2" file="$3" esc tmp
  esc="$(printf '%s' "$val" | sed -e 's/[\\&|]/\\&/g')"
  tmp="$(mktemp)"
  if grep -qE "^${key}=" "$file"; then
    sed -E "s|^${key}=.*|${key}=${esc}|" "$file" > "$tmp"
  else
    { cat "$file"; printf '%s=%s\n' "$key" "$val"; } > "$tmp"
  fi
  cat "$tmp" > "$file"   # cat, no mv: preserva dueño y permisos del original
  rm -f "$tmp"
}

mask() {
  local v="$1"
  [[ -z "$v" ]] && { printf '(vacío)'; return; }
  printf '%s… (%d caracteres)' "${v:0:4}" "${#v}"
}

gen_token() {
  if have openssl; then
    openssl rand -hex 32
  else
    head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'
  fi
}

# Pregunta por /dev/tty, no por stdin: el script puede venir de un pipe.
ask() {
  local prompt="$1" default="${2:-}" answer=""
  if [[ -n "$default" ]]; then
    printf '  %s [%s]: ' "$prompt" "$default" > /dev/tty || true
  else
    printf '  %s: ' "$prompt" > /dev/tty || true
  fi
  IFS= read -r answer < /dev/tty || answer=""
  printf '%s' "${answer:-$default}"
}

# Los bucles del wizard re-preguntan hasta que el valor sea válido. Si la
# terminal desaparece, 'ask' devuelve vacío para siempre: este tope evita que
# el instalador quede girando en el vacío.
WIZARD_MAX_TRIES=5
wizard_guard() {
  local tries="$1" campo="$2"
  [[ $tries -le $WIZARD_MAX_TRIES ]] && return 0
  fail "demasiados intentos inválidos para $campo (¿se cortó la terminal?).
    Volvé a correr el instalador, o pasá los valores sin preguntas:
      sudo $0 --non-interactive --endpoint-url https://tu-servidor/nginx.conf"
}

ask_yes_no() {
  local prompt="$1" default="$2" answer
  answer="$(ask "$prompt (s/n)" "$default")"
  [[ "$answer" =~ ^[sSyY] ]]
}

# ===========================================================================
# Preflight — solo lectura. Junta el plan, no muta nada.
# ===========================================================================

step "preflight"

# --- sistema operativo -----------------------------------------------------

PKG_MGR=""
for candidate in apt-get dnf yum zypper apk pacman; do
  if have "$candidate"; then PKG_MGR="$candidate"; break; fi
done

if [[ -n "$PKG_MGR" ]]; then
  log "gestor de paquetes: $PKG_MGR"
else
  warn "no reconocí el gestor de paquetes; las dependencias que falten se reportan pero no se instalan."
  INSTALL_DEPS=0
fi

HAS_SYSTEMD=0
[[ -d /run/systemd/system ]] && HAS_SYSTEMD=1
if [[ $HAS_SYSTEMD -eq 0 ]]; then
  if [[ $DRY_RUN -eq 1 ]]; then
    warn "este sistema no corre systemd: la instalación real fallaría acá."
  else
    fail "este sistema no corre systemd (/run/systemd/system no existe).
    nginx-sync se despliega como unidad de systemd; probá en un Linux con systemd."
  fi
fi

# --- estado de dpkg --------------------------------------------------------

# Un dpkg interrumpido (Ctrl-C en un apt, corte de luz, imagen mal cerrada)
# hace fallar cualquier apt-get con "dpkg was interrupted". La reparación es
# 'dpkg --configure -a': termina de configurar lo que quedó a medias. Se detecta
# acá para que aparezca en el plan, no a mitad de la instalación.
DPKG_BROKEN=0
if [[ "$PKG_MGR" == "apt-get" ]] && have dpkg; then
  if [[ -n "$(dpkg --audit 2>/dev/null)" ]] || [[ -n "$(ls -A /var/lib/dpkg/updates 2>/dev/null)" ]]; then
    DPKG_BROKEN=1
    log "dpkg quedó a medias: hay que correr 'dpkg --configure -a' antes de instalar nada."
  fi
fi

# --- herramientas requeridas ----------------------------------------------

# Paquete que provee cada comando, por familia de distro.
pkg_for() {
  local cmd="$1"
  case "$cmd" in
    useradd)
      case "$PKG_MGR" in
        apt-get)          echo passwd ;;
        dnf|yum|zypper)   echo shadow-utils ;;
        apk|pacman)       echo shadow ;;
        *)                echo shadow ;;
      esac ;;
    visudo) echo sudo ;;
    *)      echo "$cmd" ;;
  esac
}

REQUIRED_CMDS=(curl unzip git useradd)
[[ $WITH_NVM -eq 1 ]] && REQUIRED_CMDS+=(tar)
if [[ $WITH_RELOAD -eq 1 ]]; then
  REQUIRED_CMDS+=(sudo visudo nginx)
fi

MISSING_CMDS=()
for cmd in "${REQUIRED_CMDS[@]}"; do
  have "$cmd" || MISSING_CMDS+=("$cmd")
done

MISSING_PKGS=()
if [[ ${#MISSING_CMDS[@]} -gt 0 ]]; then
  for cmd in "${MISSING_CMDS[@]}"; do
    pkg="$(pkg_for "$cmd")"
    # dedup
    for seen in ${MISSING_PKGS[@]+"${MISSING_PKGS[@]}"}; do
      [[ "$seen" == "$pkg" ]] && { pkg=""; break; }
    done
    [[ -n "$pkg" ]] && MISSING_PKGS+=("$pkg")
  done
  log "faltan comandos: ${MISSING_CMDS[*]}"
  log "paquetes a instalar: ${MISSING_PKGS[*]}"
  if [[ $INSTALL_DEPS -eq 0 ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
      warn "la instalación automática está desactivada: habría que instalarlas a mano con
    ${PKG_MGR:-<gestor>} install ${MISSING_PKGS[*]}"
    else
      fail "faltan dependencias y la instalación automática está desactivada.
    Instalalas con:  ${PKG_MGR:-<gestor>} install ${MISSING_PKGS[*]}"
    fi
  fi
else
  log "todas las herramientas del sistema están presentes."
fi

# --- bun -------------------------------------------------------------------

# ¿El usuario del servicio puede ejecutar este binario? Es la comprobación que
# evita el 203/EXEC: no alcanza con que el archivo exista.
runnable_by_service_user() {
  local bin="$1"
  [[ -x "$bin" ]] || return 1
  # En dry-run, o si el usuario todavía no existe, sólo se puede mirar el path.
  if [[ $DRY_RUN -eq 1 ]] || ! id "$SERVICE_USER" >/dev/null 2>&1; then
    case "$(readlink -f "$bin")" in
      /root/*|/home/*|/Users/*) return 1 ;;   # homes que suelen ser 700
      *) return 0 ;;
    esac
  fi
  sudo -u "$SERVICE_USER" test -x "$bin" 2>/dev/null
}

find_bun() {
  local candidates=() from_path
  from_path="$(command -v bun 2>/dev/null || true)"
  [[ -n "$from_path" ]] && candidates+=("$from_path")
  candidates+=("$BUN_TARGET" "/usr/bin/bun")
  if [[ -n "${SUDO_USER:-}" ]] && have getent; then
    candidates+=("$(getent passwd "$SUDO_USER" | cut -d: -f6)/.bun/bin/bun")
  fi
  candidates+=("/root/.bun/bin/bun" "$HOME/.bun/bin/bun")

  for candidate in "${candidates[@]}"; do
    [[ -n "$candidate" && -x "$candidate" ]] && { readlink -f "$candidate"; return 0; }
  done
  return 1
}

INSTALL_BUN=0
COPY_BUN=0
BUN=""
if BUN_REAL="$(find_bun)"; then
  log "bun encontrado en $BUN_REAL"
  BUN="$BUN_REAL"
  if ! runnable_by_service_user "$BUN_REAL"; then
    log "'$SERVICE_USER' no podría ejecutar $BUN_REAL (esto causa 203/EXEC): se copiará a $BUN_TARGET"
    COPY_BUN=1
    BUN="$BUN_TARGET"
  fi
else
  log "bun no está instalado: se bajará a /usr/local/bin/bun"
  INSTALL_BUN=1
  BUN="$BUN_TARGET"
fi

# --- nvm + node ------------------------------------------------------------

INSTALL_NVM=0
if [[ $WITH_NVM -eq 1 ]]; then
  if [[ -s "$NVM_DIR/nvm.sh" ]] && have node; then
    log "nvm y node ya están instalados ($(node --version 2>/dev/null || echo '?'))."
  else
    log "se instalará nvm $NVM_VERSION en $NVM_DIR + Node LTS"
    INSTALL_NVM=1
  fi
fi

# --- configuración (.env) --------------------------------------------------

NEED_ENV_WRITE=0
RUN_WIZARD=0

env_url_is_valid() {
  local url="$1"
  [[ "$url" =~ ^https?:// ]] && [[ ! "$url" =~ ^https://example\.com ]]
}

if [[ -f "$ENV_FILE" ]]; then
  EXISTING_URL="$(env_get ENDPOINT_URL "$ENV_FILE" || true)"
  if env_url_is_valid "${EXISTING_URL:-}"; then
    log ".env presente y con ENDPOINT_URL válido."
    CFG_ENDPOINT_URL="${CFG_ENDPOINT_URL:-$EXISTING_URL}"
    CFG_PORT="${CFG_PORT:-$(env_get PORT "$ENV_FILE" || true)}"
    CFG_OUTPUT_FILENAME="${CFG_OUTPUT_FILENAME:-$(env_get OUTPUT_FILENAME "$ENV_FILE" || true)}"
  else
    log ".env presente pero ENDPOINT_URL falta o sigue con el valor de ejemplo."
    NEED_ENV_WRITE=1
  fi
else
  log ".env no existe: se creará desde .env.example."
  NEED_ENV_WRITE=1
fi

if [[ $NEED_ENV_WRITE -eq 1 ]]; then
  if env_url_is_valid "${CFG_ENDPOINT_URL:-}"; then
    log "ENDPOINT_URL tomado de flag/entorno."
  elif [[ $INTERACTIVE -eq 1 ]]; then
    RUN_WIZARD=1
  else
    fail "modo no interactivo y falta la configuración obligatoria.
    Pasá ENDPOINT_URL por entorno o flag, por ejemplo:
      ENDPOINT_URL=https://tu-servidor/nginx.conf sudo -E $0 --non-interactive
    o:
      sudo $0 --non-interactive --endpoint-url https://tu-servidor/nginx.conf"
  fi
fi

CFG_PORT="${CFG_PORT:-3000}"
CFG_OUTPUT_FILENAME="${CFG_OUTPUT_FILENAME:-default.conf}"

# --- puerto ----------------------------------------------------------------

port_in_use() {
  local port="$1"
  if have ss; then
    ss -ltn 2>/dev/null | grep -qE "[:.]${port}[[:space:]]"
  elif have netstat; then
    netstat -ltn 2>/dev/null | grep -qE "[:.]${port}[[:space:]]"
  else
    return 1
  fi
}

if [[ $RUN_WIZARD -eq 0 ]] && port_in_use "$CFG_PORT"; then
  warn "el puerto $CFG_PORT ya está ocupado; el servicio podría no arrancar."
fi

# ===========================================================================
# Wizard — junta valores, todavía sin escribir el .env
# ===========================================================================

if [[ $RUN_WIZARD -eq 1 && $DRY_RUN -eq 0 ]]; then
  step "configuración interactiva"
  printf '  Falta la configuración. Respondé y se guarda en %s\n  (Enter usa el valor entre corchetes.)\n\n' "$ENV_FILE"

  tries=0
  while :; do
    tries=$((tries + 1)); wizard_guard "$tries" ENDPOINT_URL
    CFG_ENDPOINT_URL="$(ask 'URL del endpoint con la config de nginx' "$CFG_ENDPOINT_URL")"
    env_url_is_valid "$CFG_ENDPOINT_URL" && break
    printf '  ↳ tiene que empezar con http:// o https:// y no ser el ejemplo.\n' > /dev/tty || true
  done

  CFG_ENDPOINT_AUTH="$(ask 'Header Authorization para ese endpoint (opcional, ej. "Bearer abc")' "$CFG_ENDPOINT_AUTH")"

  if [[ -z "$CFG_SYNC_TOKEN" ]]; then
    if ask_yes_no 'Generar un SYNC_TOKEN para POST /sync' 's'; then
      CFG_SYNC_TOKEN="$(gen_token)"
      printf '  ↳ token generado: %s\n' "$CFG_SYNC_TOKEN" > /dev/tty || true
    else
      CFG_SYNC_TOKEN="$(ask 'SYNC_TOKEN (vacío deshabilita POST /sync)' '')"
    fi
  fi

  tries=0
  while :; do
    tries=$((tries + 1)); wizard_guard "$tries" PORT
    CFG_PORT="$(ask 'Puerto del servidor' "$CFG_PORT")"
    if [[ "$CFG_PORT" =~ ^[0-9]+$ ]] && (( CFG_PORT >= 1 && CFG_PORT <= 65535 )); then
      port_in_use "$CFG_PORT" || break
      printf '  ↳ el puerto %s está ocupado; elegí otro.\n' "$CFG_PORT" > /dev/tty || true
    else
      printf '  ↳ tiene que ser un número entre 1 y 65535.\n' > /dev/tty || true
    fi
  done

  tries=0
  while :; do
    tries=$((tries + 1)); wizard_guard "$tries" OUTPUT_FILENAME
    CFG_OUTPUT_FILENAME="$(ask 'Nombre del archivo de salida en sites-enabled/' "$CFG_OUTPUT_FILENAME")"
    [[ -n "$CFG_OUTPUT_FILENAME" && "$CFG_OUTPUT_FILENAME" != */* && "$CFG_OUTPUT_FILENAME" != *..* ]] && break
    printf '  ↳ sin barras ni ".."; es un nombre de archivo, no una ruta.\n' > /dev/tty || true
  done

  if [[ $WITH_RELOAD -eq 1 ]] && ! ask_yes_no 'Recargar nginx cuando la config cambie' 's'; then
    WITH_RELOAD=0
  fi
fi

CFG_NGINX_RELOAD=$([[ $WITH_RELOAD -eq 1 ]] && echo true || echo false)

# ===========================================================================
# Plan — lo que se va a hacer. Con --dry-run, termina acá.
# ===========================================================================

UNIT_CONTENT="$(sed \
  -e "s|@USER@|$SERVICE_USER|g" \
  -e "s|@DIR@|$SCRIPT_DIR|g" \
  -e "s|@BUN@|$BUN|g" \
  "$UNIT_TEMPLATE")"

step "plan"
log "directorio:  $SCRIPT_DIR"
log "usuario:     $SERVICE_USER"
if [[ ${#MISSING_PKGS[@]} -gt 0 ]]; then
  if [[ -n "$PKG_MGR" ]]; then
    log "paquetes:    instala ${MISSING_PKGS[*]} con $PKG_MGR"
    [[ $DPKG_BROKEN -eq 1 ]] && log "dpkg:        quedó a medias; se repara con 'dpkg --configure -a' primero"
  else
    log "paquetes:    faltan ${MISSING_PKGS[*]}; hay que instalarlos a mano (gestor desconocido)"
  fi
else
  log "paquetes:    nada que instalar"
fi
if   [[ $INSTALL_BUN -eq 1 ]]; then log "bun:         baja el instalador oficial → $BUN_TARGET"
elif [[ $COPY_BUN -eq 1 ]];   then log "bun:         copia $BUN_REAL → $BUN_TARGET (arregla 203/EXEC)"
else                               log "bun:         $BUN (ya usable por $SERVICE_USER)"; fi
if   [[ $INSTALL_NVM -eq 1 ]]; then log "nvm/node:    instala nvm $NVM_VERSION en $NVM_DIR + Node LTS"
elif [[ $WITH_NVM -eq 1 ]];    then log "nvm/node:    ya presente"
else                                log "nvm/node:    omitido (--no-nvm)"; fi
if   [[ $RUN_WIZARD -eq 1 && $DRY_RUN -eq 1 ]]; then log "config:      preguntaría los valores y escribiría $ENV_FILE"
elif [[ $NEED_ENV_WRITE -eq 1 ]];               then log "config:      escribe $ENV_FILE"
else                                                 log "config:      $ENV_FILE ya está listo"; fi
if [[ $RUN_WIZARD -eq 0 || $DRY_RUN -eq 0 ]]; then
  log "  ENDPOINT_URL     ${CFG_ENDPOINT_URL:-(del .env)}"
  log "  SYNC_TOKEN       $(mask "$CFG_SYNC_TOKEN")"
  log "  ENDPOINT_AUTH    $(mask "$CFG_ENDPOINT_AUTH")"
  log "  PORT             $CFG_PORT"
  log "  OUTPUT_FILENAME  $CFG_OUTPUT_FILENAME"
fi
log "symlink:     $SITES_LINK -> $SITES_TARGET"
if [[ $WITH_RELOAD -eq 1 ]]; then
  log "sudoers:     $SUDOERS_PATH (nginx -t + systemctl reload nginx)"
else
  log "sudoers:     omitido (sin reload de nginx)"
fi
log "unidad:      $UNIT_PATH"

if [[ $DRY_RUN -eq 1 ]]; then
  printf '\n--- %s ---\n%s\n' "$UNIT_PATH" "$UNIT_CONTENT"
  printf '\n[install] dry-run: no se escribió nada.\n'
  exit 0
fi

# ===========================================================================
# Ejecución
# ===========================================================================

# --- dependencias del sistema ----------------------------------------------

if [[ ${#MISSING_PKGS[@]} -gt 0 ]]; then
  step "dependencias del sistema"

  # Termina de configurar los paquetes que quedaron a medias. Es la reparación
  # estándar; sin esto, cualquier apt-get falla con "dpkg was interrupted".
  dpkg_repair() {
    log "reparando dpkg: dpkg --configure -a"
    # Configura los paquetes que quedaron a medias, sin abrir prompts de config.
    # En Raspberry Pi OS esto puede tocar rpi-connect y reiniciar servicios de
    # sesión: por eso el trap de SIGHUP de más arriba.
    DEBIAN_FRONTEND=noninteractive dpkg --force-confdef --force-confold --configure -a
  }

  apt_install() {
    # Lock::Timeout: en un server recién arrancado, unattended-upgrades suele
    # tener tomado el lock de apt. Esperar es mejor que fallar.
    # force-confold/confdef: sin esto, un paquete con config modificada abre un
    # prompt y la instalación desatendida se cuelga esperando una respuesta.
    apt-get -o DPkg::Lock::Timeout=120 update -qq
    apt-get -o DPkg::Lock::Timeout=120 \
            -o Dpkg::Options::=--force-confold \
            -o Dpkg::Options::=--force-confdef \
            install -y --no-install-recommends "${MISSING_PKGS[@]}"
  }

  case "$PKG_MGR" in
    apt-get)
      export DEBIAN_FRONTEND=noninteractive
      [[ $DPKG_BROKEN -eq 1 ]] && dpkg_repair
      # Segundo intento tras reparar: la detección previa no cubre todos los
      # estados rotos de dpkg, y el mensaje de apt sí.
      if ! apt_install; then
        log "apt falló; reintento tras 'dpkg --configure -a'."
        dpkg_repair || fail "'dpkg --configure -a' falló. Arreglá dpkg a mano y volvé a correr esto:
    sudo dpkg --configure -a
    sudo apt-get -f install"
        apt_install || fail "apt-get sigue fallando después de reparar dpkg. Revisá la salida de arriba."
      fi
      ;;
    dnf)    dnf install -y "${MISSING_PKGS[@]}" ;;
    yum)    yum install -y "${MISSING_PKGS[@]}" ;;
    zypper) zypper --non-interactive install "${MISSING_PKGS[@]}" ;;
    apk)    apk add --no-cache "${MISSING_PKGS[@]}" ;;
    pacman) pacman -Sy --needed --noconfirm "${MISSING_PKGS[@]}" ;;
  esac

  # Re-verificar: que el paquete instale no garantiza que el comando exista.
  for cmd in "${MISSING_CMDS[@]}"; do
    have "$cmd" || fail "instalé $(pkg_for "$cmd") pero '$cmd' sigue sin estar en el PATH."
  done
  log "instalados: ${MISSING_PKGS[*]}"
fi

# --- bun -------------------------------------------------------------------

if [[ $INSTALL_BUN -eq 1 ]]; then
  step "bun"
  BUN_INSTALLER="$(mktemp)"
  curl -fsSL https://bun.sh/install -o "$BUN_INSTALLER" \
    || fail "no pude bajar el instalador de bun desde https://bun.sh/install."
  # Un proxy o un portal cautivo devuelven HTML con 200: mejor detectarlo acá.
  [[ -s "$BUN_INSTALLER" ]] || fail "el instalador de bun vino vacío."
  head -1 "$BUN_INSTALLER" | grep -q '^#!' \
    || fail "lo que bajó de bun.sh/install no es un script (¿proxy o portal cautivo?)."

  # BUN_INSTALL=/usr/local deja el binario REAL en /usr/local/bin/bun, legible
  # por cualquier usuario. Es el arreglo de raíz del 203/EXEC.
  BUN_INSTALL=/usr/local bash "$BUN_INSTALLER" || fail "el instalador de bun falló."
  rm -f "$BUN_INSTALLER"

  [[ -x "$BUN_TARGET" ]] || fail "bun no quedó en $BUN_TARGET después de instalarlo."
  BUN="$BUN_TARGET"
  log "bun instalado: $("$BUN" --version)"
elif [[ $COPY_BUN -eq 1 ]]; then
  step "bun"
  install -m 0755 "$BUN_REAL" "$BUN_TARGET"
  BUN="$BUN_TARGET"
  log "copiado a $BUN_TARGET"
fi

"$BUN" --version >/dev/null 2>&1 || fail "'$BUN' no ejecuta. Revisá la instalación de bun."

# --- nvm + node ------------------------------------------------------------

# Extra para el servidor: nginx-sync no lo necesita, así que nada de esto es
# fatal. Si falla, se avisa y se sigue.
install_nvm() {
  local installer node_bin
  installer="$(mktemp)"
  curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VERSION/install.sh" -o "$installer" \
    || { warn "no pude bajar el instalador de nvm."; return 1; }
  head -1 "$installer" | grep -q '^#!' || { warn "el instalador de nvm no es un script."; return 1; }

  mkdir -p "$NVM_DIR"
  # PROFILE=/dev/null: no queremos que toque el .bashrc de root.
  if ! NVM_DIR="$NVM_DIR" PROFILE=/dev/null METHOD=script bash "$installer"; then
    warn "el instalador de nvm falló."
    return 1
  fi
  rm -f "$installer"

  if ! bash -c "export NVM_DIR='$NVM_DIR'; . '$NVM_DIR/nvm.sh'; nvm install --lts" >/dev/null 2>&1; then
    warn "'nvm install --lts' falló."
    return 1
  fi

  # Que sea legible por todos: vive en /usr/local, no en un home.
  chmod -R a+rX "$NVM_DIR"

  node_bin="$(find "$NVM_DIR/versions/node" -maxdepth 3 -type f -name node -perm -u+x 2>/dev/null | sort | tail -1)"
  [[ -n "$node_bin" ]] || { warn "no encontré el binario de node bajo $NVM_DIR."; return 1; }

  for tool in node npm npx; do
    [[ -e "$(dirname "$node_bin")/$tool" ]] && ln -sfn "$(dirname "$node_bin")/$tool" "/usr/local/bin/$tool"
  done

  cat > /etc/profile.d/nvm.sh <<EOF
export NVM_DIR="$NVM_DIR"
[ -s "\$NVM_DIR/nvm.sh" ] && . "\$NVM_DIR/nvm.sh"
EOF
  chmod 644 /etc/profile.d/nvm.sh

  log "node $("/usr/local/bin/node" --version 2>/dev/null || echo '?') disponible en /usr/local/bin/node"
  log "nvm en $NVM_DIR (cargalo con: source /etc/profile.d/nvm.sh)"
}

if [[ $INSTALL_NVM -eq 1 ]]; then
  step "nvm + node"
  install_nvm || warn "nvm/Node no quedaron instalados. nginx-sync igual funciona: corre con bun."
fi

# --- usuario ---------------------------------------------------------------

step "usuario de servicio"

if id "$SERVICE_USER" >/dev/null 2>&1; then
  log "'$SERVICE_USER' ya existe."
else
  useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
  log "'$SERVICE_USER' creado."
fi

# --- .env ------------------------------------------------------------------

step "configuración"

if [[ $NEED_ENV_WRITE -eq 1 ]]; then
  [[ -f "$ENV_FILE" ]] || cp "$ENV_EXAMPLE" "$ENV_FILE"
  chmod 600 "$ENV_FILE"   # antes de escribir el token, no después
  env_set ENDPOINT_URL    "$CFG_ENDPOINT_URL"    "$ENV_FILE"
  env_set SYNC_TOKEN      "$CFG_SYNC_TOKEN"      "$ENV_FILE"
  env_set ENDPOINT_AUTH   "$CFG_ENDPOINT_AUTH"   "$ENV_FILE"
  env_set PORT            "$CFG_PORT"            "$ENV_FILE"
  env_set OUTPUT_FILENAME "$CFG_OUTPUT_FILENAME" "$ENV_FILE"
  env_set NGINX_RELOAD    "$CFG_NGINX_RELOAD"    "$ENV_FILE"
  log "escrito $ENV_FILE (modo 600)"
else
  log "$ENV_FILE ya estaba configurado; no se toca."
fi

# Aviso, no error: la red del server puede no estar lista todavía.
ENDPOINT_CODE="$(curl -fsS -o /dev/null -w '%{http_code}' -I --max-time 10 "$CFG_ENDPOINT_URL" 2>/dev/null || true)"
if [[ -z "$ENDPOINT_CODE" || "$ENDPOINT_CODE" == "000" || "$ENDPOINT_CODE" == "405" ]]; then
  # Hay endpoints que no aceptan HEAD: reintentar pidiendo sólo el primer byte.
  ENDPOINT_CODE="$(curl -fsS -o /dev/null -w '%{http_code}' -r 0-0 --max-time 10 "$CFG_ENDPOINT_URL" 2>/dev/null || true)"
fi
case "$ENDPOINT_CODE" in
  2*) log "endpoint alcanzable (HTTP $ENDPOINT_CODE)." ;;
  "") warn "no pude alcanzar $CFG_ENDPOINT_URL. El servicio va a reintentar solo." ;;
  *)  warn "el endpoint respondió HTTP $ENDPOINT_CODE. Revisá ENDPOINT_URL/ENDPOINT_AUTH." ;;
esac

if [[ -d "$SCRIPT_DIR/node_modules" ]]; then
  log "dependencias ya instaladas."
else
  log "instalando dependencias..."
  (cd "$SCRIPT_DIR" && "$BUN" install)
fi

mkdir -p "$SITES_TARGET"
chown -R "$SERVICE_USER:$SERVICE_USER" "$SCRIPT_DIR"
chmod 600 "$ENV_FILE"
log "permisos aplicados a $SCRIPT_DIR"

# Verificación explícita: si esto falla, el servicio fallaría con 203/EXEC y el
# motivo quedaría enterrado en el journal.
sudo -u "$SERVICE_USER" test -x "$BUN" \
  || fail "'$SERVICE_USER' no puede ejecutar $BUN. Reinstalá bun con:
    curl -fsSL https://bun.sh/install | sudo BUN_INSTALL=/usr/local bash"
log "verificado: '$SERVICE_USER' ejecuta bun $(sudo -u "$SERVICE_USER" "$BUN" --version 2>/dev/null || echo '?')"

# --- sudoers ---------------------------------------------------------------

if [[ $WITH_RELOAD -eq 1 ]]; then
  step "sudoers para recargar nginx"

  NGINX_BIN="$(command -v nginx || true)"
  SYSTEMCTL_BIN="$(command -v systemctl || true)"
  [[ -n "$NGINX_BIN" ]] || fail "no encontré nginx en el PATH (usá --no-reload para omitir esto)."
  [[ -n "$SYSTEMCTL_BIN" ]] || fail "no encontré systemctl en el PATH."

  TMP_SUDOERS="$(mktemp)"
  # Sólo estos dos comandos exactos. Nunca NOPASSWD: ALL.
  printf '%s ALL=(root) NOPASSWD: %s -t, %s reload nginx\n' \
    "$SERVICE_USER" "$NGINX_BIN" "$SYSTEMCTL_BIN" > "$TMP_SUDOERS"

  # Validar ANTES de instalar: un sudoers inválido puede dejar sudo inutilizable.
  if visudo -cf "$TMP_SUDOERS" >/dev/null; then
    install -m 0440 -o root -g root "$TMP_SUDOERS" "$SUDOERS_PATH"
    rm -f "$TMP_SUDOERS"
    log "instalado en $SUDOERS_PATH"
    grep -qE '^NGINX_RELOAD=true' "$ENV_FILE" \
      || warn "poné NGINX_RELOAD=true en .env para que el reload se use."
  else
    rm -f "$TMP_SUDOERS"
    fail "la regla de sudoers generada es inválida; no se instaló nada."
  fi
fi

# --- symlink de nginx ------------------------------------------------------

link_sites_enabled() {
  step "enlazar $SITES_LINK"

  if [[ -L "$SITES_LINK" && "$(readlink -f "$SITES_LINK")" == "$(readlink -f "$SITES_TARGET")" ]]; then
    log "ya apunta a $SITES_TARGET — nada que hacer."
    return 0
  fi

  local backup=""
  if [[ -e "$SITES_LINK" || -L "$SITES_LINK" ]]; then
    backup="${SITES_LINK}.bak.$(date +%Y%m%d%H%M%S)"
    mv "$SITES_LINK" "$backup"
    log "backup del anterior en $backup"
  fi

  ln -s "$SITES_TARGET" "$SITES_LINK"
  log "$SITES_LINK -> $SITES_TARGET"

  # En modo prueba (LINK override) no tiene sentido validar ni recargar nginx.
  if [[ -n "${NGINX_SITES_ENABLED:-}" ]]; then
    log "NGINX_SITES_ENABLED seteado: se omite 'nginx -t' y el reload."
    return 0
  fi

  if ! nginx -t; then
    # Rollback: dejar el sistema como estaba antes de este script.
    rm -f "$SITES_LINK"
    [[ -n "$backup" ]] && { mv "$backup" "$SITES_LINK"; log "restaurado desde $backup"; }
    fail "'nginx -t' falló; se restauró la configuración anterior."
  fi

  if systemctl is-active --quiet nginx; then
    systemctl reload nginx
    log "nginx recargado."
  else
    warn "nginx no está activo; no se recargó."
  fi
}

link_sites_enabled

# --- servicio --------------------------------------------------------------

step "servicio de systemd"

printf '%s\n' "$UNIT_CONTENT" > "$UNIT_PATH"
chmod 644 "$UNIT_PATH"
log "unidad escrita en $UNIT_PATH"

systemctl daemon-reload
systemctl enable --now nginx-sync
log "habilitado y arrancado."

# --- verificación ----------------------------------------------------------

step "verificación"

ACTIVE=0
for _ in $(seq 1 15); do
  if systemctl is-active --quiet nginx-sync; then ACTIVE=1; break; fi
  sleep 1
done

if [[ $ACTIVE -eq 0 ]]; then
  printf '\n'
  systemctl --no-pager --full status nginx-sync || true
  printf '\n'
  journalctl -u nginx-sync -n 30 --no-pager || true
  fail "el servicio no quedó activo. El estado y el journal están arriba."
fi
log "unidad activa."

HEALTH="$(curl -fsS --max-time 5 "http://127.0.0.1:$CFG_PORT/health" 2>/dev/null || true)"
if [[ -n "$HEALTH" ]]; then
  log "GET /health → $HEALTH"
else
  warn "no respondió http://127.0.0.1:$CFG_PORT/health (puede tardar unos segundos más)."
fi

if [[ -f "$SITES_TARGET/$CFG_OUTPUT_FILENAME" ]]; then
  log "config descargada: $SITES_TARGET/$CFG_OUTPUT_FILENAME"
else
  warn "todavía no existe $SITES_TARGET/$CFG_OUTPUT_FILENAME; mirá el journal si no aparece."
fi

printf '\n[install] listo. Logs en vivo:  journalctl -u nginx-sync -f\n' || true
printf '[install] log de esta instalación: %s\n' "$LOG_FILE" || true
