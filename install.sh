#!/usr/bin/env bash
#
# install.sh — deja nginx-sync andando como servicio de systemd.
#
#   sudo ./install.sh                # instala todo y arranca el servicio
#   sudo ./install.sh --dry-run      # muestra qué haría, sin tocar nada
#   sudo ./install.sh --no-reload    # sin la regla de sudoers para recargar nginx
#
# Hace, en orden: resuelve bun, crea el usuario de servicio, prepara .env y
# dependencias, instala la regla de sudoers, enlaza /etc/nginx/sites-enabled a
# este directorio (con backup) y arranca la unidad.
#
# Sobre bun: resuelve la ruta REAL del binario. Si cuelga de un home inaccesible
# (p.ej. /root/.bun/bin/bun, con /root en 700), lo copia a /usr/local/bin. Un
# symlink no arregla los permisos del directorio y systemd falla con 203/EXEC:
# el usuario del servicio no puede atravesar /root.

set -euo pipefail

SERVICE_USER="nginx-sync"
DRY_RUN=0
WITH_RELOAD=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT_TEMPLATE="$SCRIPT_DIR/deploy/nginx-sync.service"
UNIT_PATH="/etc/systemd/system/nginx-sync.service"
SUDOERS_PATH="/etc/sudoers.d/nginx-sync"
SITES_LINK="${NGINX_SITES_ENABLED:-/etc/nginx/sites-enabled}"
SITES_TARGET="$SCRIPT_DIR/sites-enabled"
BUN_TARGET="/usr/local/bin/bun"

log()  { printf '[install] %s\n' "$*"; }
warn() { printf '[install] AVISO: %s\n' "$*" >&2; }
fail() { printf '[install] ERROR: %s\n' "$*" >&2; exit 1; }
step() { printf '\n[install] == %s ==\n' "$*"; }

usage() {
  sed -n '3,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)   DRY_RUN=1; shift ;;
    --no-reload) WITH_RELOAD=0; shift ;;
    -h|--help)   usage ;;
    *)           fail "Opción desconocida: $1 (probá --help)" ;;
  esac
done

if [[ $DRY_RUN -eq 0 && $EUID -ne 0 ]]; then
  fail "este script necesita root. Ejecutá: sudo $0"
fi

[[ -f "$UNIT_TEMPLATE" ]] || fail "falta $UNIT_TEMPLATE. ¿Corriste el script desde la raíz del repo?"

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
  [[ -n "${SUDO_USER:-}" ]] && candidates+=("$(getent passwd "$SUDO_USER" | cut -d: -f6)/.bun/bin/bun")
  candidates+=("/root/.bun/bin/bun" "$HOME/.bun/bin/bun")

  for candidate in "${candidates[@]}"; do
    [[ -n "$candidate" && -x "$candidate" ]] && { readlink -f "$candidate"; return 0; }
  done
  return 1
}

step "bun"

BUN_REAL="$(find_bun)" || fail "no encontré bun. Instalalo con:
    curl -fsSL https://bun.sh/install | sudo BUN_INSTALL=/usr/local bash"
log "binario real: $BUN_REAL"

BUN="$BUN_REAL"
if ! runnable_by_service_user "$BUN_REAL"; then
  log "'$SERVICE_USER' no puede ejecutar $BUN_REAL (esto causa 203/EXEC)."
  if [[ $DRY_RUN -eq 1 ]]; then
    log "[dry-run] copiaría $BUN_REAL → $BUN_TARGET"
  else
    install -m 0755 "$BUN_REAL" "$BUN_TARGET"
    log "copiado a $BUN_TARGET"
  fi
  BUN="$BUN_TARGET"
fi

# --- unidad ----------------------------------------------------------------

UNIT_CONTENT="$(sed \
  -e "s|@USER@|$SERVICE_USER|g" \
  -e "s|@DIR@|$SCRIPT_DIR|g" \
  -e "s|@BUN@|$BUN|g" \
  "$UNIT_TEMPLATE")"

if [[ $DRY_RUN -eq 1 ]]; then
  step "resumen (dry-run: no se escribe nada)"
  log "usuario:    $SERVICE_USER"
  log "directorio: $SCRIPT_DIR"
  log "bun:        $BUN"
  log "symlink:    $SITES_LINK -> $SITES_TARGET"
  if [[ $WITH_RELOAD -eq 1 ]]; then
    log "sudoers:    $SUDOERS_PATH"
  else
    log "sudoers:    omitido (--no-reload)"
  fi
  printf '\n--- %s ---\n%s\n' "$UNIT_PATH" "$UNIT_CONTENT"
  exit 0
fi

# --- usuario ---------------------------------------------------------------

step "usuario de servicio"

if id "$SERVICE_USER" >/dev/null 2>&1; then
  log "'$SERVICE_USER' ya existe."
else
  useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
  log "'$SERVICE_USER' creado."
fi

# --- .env y dependencias ---------------------------------------------------

step "configuración"

if [[ ! -f "$SCRIPT_DIR/.env" ]]; then
  cp "$SCRIPT_DIR/.env.example" "$SCRIPT_DIR/.env"
  fail "creé $SCRIPT_DIR/.env desde el ejemplo.
    Completá ENDPOINT_URL y SYNC_TOKEN, y volvé a correr este script."
fi

# Sin ENDPOINT_URL el servicio arranca y muere; mejor avisar acá.
if ! grep -qE '^ENDPOINT_URL=.+' "$SCRIPT_DIR/.env" \
   || grep -qE '^ENDPOINT_URL=https://example\.com' "$SCRIPT_DIR/.env"; then
  fail "ENDPOINT_URL falta o sigue con el valor de ejemplo en $SCRIPT_DIR/.env."
fi

if [[ -d "$SCRIPT_DIR/node_modules" ]]; then
  log "dependencias ya instaladas."
else
  log "instalando dependencias..."
  (cd "$SCRIPT_DIR" && "$BUN" install)
fi

mkdir -p "$SITES_TARGET"
chown -R "$SERVICE_USER:$SERVICE_USER" "$SCRIPT_DIR"
chmod 600 "$SCRIPT_DIR/.env"
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
    grep -qE '^NGINX_RELOAD=true' "$SCRIPT_DIR/.env" \
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

sleep 2
printf '\n'
systemctl --no-pager --full status nginx-sync || true
printf '\n'
journalctl -u nginx-sync -n 20 --no-pager || true

printf '\n[install] listo. Logs en vivo:  journalctl -u nginx-sync -f\n'
