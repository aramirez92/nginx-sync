#!/usr/bin/env bash
#
# link.sh — apunta /etc/nginx/sites-enabled al directorio sites-enabled de este proyecto.
#
# Uso:   sudo ./link.sh
# Prueba: NGINX_SITES_ENABLED=/tmp/fake-sites-enabled sudo -E ./link.sh
#
# Hace backup con timestamp del sites-enabled existente y revierte si `nginx -t` falla.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$SCRIPT_DIR/sites-enabled"
LINK="${NGINX_SITES_ENABLED:-/etc/nginx/sites-enabled}"

log()  { printf '[link] %s\n' "$*"; }
fail() { printf '[link] ERROR: %s\n' "$*" >&2; exit 1; }

if [[ $EUID -ne 0 ]]; then
  fail "este script necesita root. Ejecutá: sudo $0"
fi

mkdir -p "$TARGET"

# Idempotente: si ya apunta donde corresponde, no hay nada que hacer.
if [[ -L "$LINK" && "$(readlink -f "$LINK")" == "$(readlink -f "$TARGET")" ]]; then
  log "$LINK ya apunta a $TARGET — nada que hacer."
  exit 0
fi

BACKUP=""
if [[ -e "$LINK" || -L "$LINK" ]]; then
  BACKUP="${LINK}.bak.$(date +%Y%m%d%H%M%S)"
  mv "$LINK" "$BACKUP"
  log "backup del anterior en $BACKUP"
fi

ln -s "$TARGET" "$LINK"
log "$LINK -> $TARGET"

rollback() {
  log "revirtiendo..."
  rm -f "$LINK"
  if [[ -n "$BACKUP" ]]; then
    mv "$BACKUP" "$LINK"
    log "restaurado desde $BACKUP"
  fi
}

# En modo prueba (LINK override) no tiene sentido validar/recargar nginx.
if [[ -n "${NGINX_SITES_ENABLED:-}" ]]; then
  log "NGINX_SITES_ENABLED seteado: se omite 'nginx -t' y el reload."
  exit 0
fi

if ! command -v nginx >/dev/null 2>&1; then
  rollback
  fail "nginx no está instalado o no está en PATH."
fi

if ! nginx -t; then
  rollback
  fail "'nginx -t' falló; se restauró la configuración anterior."
fi

if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet nginx; then
  systemctl reload nginx
  log "nginx recargado vía systemctl."
else
  nginx -s reload
  log "nginx recargado vía 'nginx -s reload'."
fi

log "listo."
