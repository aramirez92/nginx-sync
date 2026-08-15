#!/usr/bin/env bash
#
# install.sh — instala nginx-sync como servicio de systemd.
#
#   sudo ./install.sh                    # instala y arranca el servicio
#   sudo ./install.sh --with-reload      # + regla de sudoers para recargar nginx
#   sudo ./install.sh --dry-run          # muestra qué haría, sin tocar nada
#   sudo ./install.sh --user otro        # usuario de servicio distinto
#
# Resuelve la ruta REAL de bun. Si el binario cuelga de un home inaccesible
# (p.ej. /root/.bun/bin/bun, con /root en 700), lo copia a /usr/local/bin:
# un symlink no arregla los permisos del directorio y systemd falla con
# 203/EXEC — el usuario del servicio no puede atravesar /root.

set -euo pipefail

SERVICE_USER="nginx-sync"
WITH_RELOAD=0
DRY_RUN=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT_TEMPLATE="$SCRIPT_DIR/deploy/nginx-sync.service"
UNIT_PATH="/etc/systemd/system/nginx-sync.service"
SUDOERS_PATH="/etc/sudoers.d/nginx-sync"
BUN_TARGET="/usr/local/bin/bun"

log()  { printf '[install] %s\n' "$*"; }
warn() { printf '[install] AVISO: %s\n' "$*" >&2; }
fail() { printf '[install] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '3,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)         SERVICE_USER="${2:-}"; [[ -n "$SERVICE_USER" ]] || fail "--user necesita un nombre."; shift 2 ;;
    --with-reload)  WITH_RELOAD=1; shift ;;
    --dry-run)      DRY_RUN=1; shift ;;
    -h|--help)      usage ;;
    *)              fail "Opción desconocida: $1 (probá --help)" ;;
  esac
done

if [[ $DRY_RUN -eq 0 && $EUID -ne 0 ]]; then
  fail "este script necesita root. Ejecutá: sudo $0"
fi

[[ -f "$UNIT_TEMPLATE" ]] || fail "falta $UNIT_TEMPLATE. ¿Corriste el script desde la raíz del repo?"

# --- 1. Resolver bun -------------------------------------------------------

# ¿El usuario del servicio puede realmente ejecutar este binario? Es la
# comprobación que evita el 203/EXEC: no alcanza con que el archivo exista.
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
  local candidates=()
  local from_path
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

BUN_REAL="$(find_bun)" || fail "no encontré bun. Instalalo con:
    curl -fsSL https://bun.sh/install | sudo BUN_INSTALL=/usr/local bash"

log "bun encontrado en $BUN_REAL"

BUN="$BUN_REAL"
if ! runnable_by_service_user "$BUN_REAL"; then
  log "$BUN_REAL no es accesible para '$SERVICE_USER' (esto causa 203/EXEC)."
  if [[ $DRY_RUN -eq 1 ]]; then
    log "[dry-run] copiaría $BUN_REAL → $BUN_TARGET"
  else
    install -m 0755 "$BUN_REAL" "$BUN_TARGET"
    log "copiado a $BUN_TARGET"
  fi
  BUN="$BUN_TARGET"
fi

# --- 2. Unidad de systemd --------------------------------------------------

UNIT_CONTENT="$(sed \
  -e "s|@USER@|$SERVICE_USER|g" \
  -e "s|@DIR@|$SCRIPT_DIR|g" \
  -e "s|@BUN@|$BUN|g" \
  "$UNIT_TEMPLATE")"

if [[ $DRY_RUN -eq 1 ]]; then
  log "usuario de servicio: $SERVICE_USER"
  log "directorio:          $SCRIPT_DIR"
  log "bun:                 $BUN"
  [[ $WITH_RELOAD -eq 1 ]] && log "sudoers:             $SUDOERS_PATH (se crearía)"
  printf '\n--- %s ---\n%s\n' "$UNIT_PATH" "$UNIT_CONTENT"
  exit 0
fi

# --- 3. Usuario y permisos -------------------------------------------------

if id "$SERVICE_USER" >/dev/null 2>&1; then
  log "usuario '$SERVICE_USER' ya existe."
else
  useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
  log "usuario '$SERVICE_USER' creado."
fi

[[ -f "$SCRIPT_DIR/.env" ]] || fail "falta $SCRIPT_DIR/.env. Crealo con:
    cp .env.example .env && \$EDITOR .env"

[[ -d "$SCRIPT_DIR/node_modules" ]] || warn "no hay node_modules; corré 'bun install' antes de arrancar."

mkdir -p "$SCRIPT_DIR/sites-enabled"
chown -R "$SERVICE_USER:$SERVICE_USER" "$SCRIPT_DIR"
chmod 600 "$SCRIPT_DIR/.env"
log "permisos aplicados a $SCRIPT_DIR"

# Verificación explícita antes de instalar: si esto falla, el servicio fallaría
# con 203/EXEC y el motivo quedaría enterrado en el journal.
sudo -u "$SERVICE_USER" test -x "$BUN" \
  || fail "'$SERVICE_USER' no puede ejecutar $BUN. Reinstalá bun con:
    curl -fsSL https://bun.sh/install | sudo BUN_INSTALL=/usr/local bash"
log "verificado: '$SERVICE_USER' puede ejecutar $BUN ($(sudo -u "$SERVICE_USER" "$BUN" --version 2>/dev/null || echo '?'))"

# --- 4. Sudoers para el reload (opcional) ----------------------------------

if [[ $WITH_RELOAD -eq 1 ]]; then
  NGINX_BIN="$(command -v nginx || true)"
  SYSTEMCTL_BIN="$(command -v systemctl || true)"
  [[ -n "$NGINX_BIN" ]] || fail "--with-reload: no encontré nginx en el PATH."
  [[ -n "$SYSTEMCTL_BIN" ]] || fail "--with-reload: no encontré systemctl en el PATH."

  TMP_SUDOERS="$(mktemp)"
  # Sólo estos dos comandos exactos. Nunca NOPASSWD: ALL.
  printf '%s ALL=(root) NOPASSWD: %s -t, %s reload nginx\n' \
    "$SERVICE_USER" "$NGINX_BIN" "$SYSTEMCTL_BIN" > "$TMP_SUDOERS"

  # Validar ANTES de instalar: un sudoers inválido puede dejar sudo inutilizable.
  if visudo -cf "$TMP_SUDOERS" >/dev/null; then
    install -m 0440 -o root -g root "$TMP_SUDOERS" "$SUDOERS_PATH"
    rm -f "$TMP_SUDOERS"
    log "sudoers instalado en $SUDOERS_PATH"
    log "recordá poner NGINX_RELOAD=true en .env"
  else
    rm -f "$TMP_SUDOERS"
    fail "la regla de sudoers generada es inválida; no se instaló nada."
  fi
fi

# --- 5. Instalar y arrancar ------------------------------------------------

printf '%s\n' "$UNIT_CONTENT" > "$UNIT_PATH"
chmod 644 "$UNIT_PATH"
log "unidad escrita en $UNIT_PATH"

systemctl daemon-reload
systemctl enable --now nginx-sync
log "servicio habilitado y arrancado."

sleep 2
systemctl --no-pager --full status nginx-sync || true
printf '\n'
journalctl -u nginx-sync -n 20 --no-pager || true

printf '\n[install] listo. Logs en vivo:  journalctl -u nginx-sync -f\n'
