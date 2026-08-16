#!/usr/bin/env bash
#
# bootstrap.sh — instala nginx-sync entero con un solo comando:
#
#   curl -fsSL https://raw.githubusercontent.com/aramirez92/nginx-sync/main/bootstrap.sh | sudo bash
#
# Baja el código desde GitHub (tar.gz), lo deja en /opt/nginx-sync y corre
# install.sh, que resuelve el resto: dependencias del sistema, bun, nvm + Node,
# el .env (preguntando si hace falta), el usuario de servicio, el symlink de
# nginx y la unidad de systemd.
#
# Todo lo que va después de "--" se le pasa a install.sh:
#
#   curl -fsSL .../bootstrap.sh | sudo bash -s -- --non-interactive \
#       --endpoint-url https://tu-servidor/nginx.conf
#
# Variables:
#   NGINX_SYNC_DIR    dónde instalar          (default /opt/nginx-sync)
#   NGINX_SYNC_REF    rama, tag o commit      (default main)
#   NGINX_SYNC_REPO   repo owner/name         (default aramirez92/nginx-sync)
#
# Volver a correrlo actualiza el código sin tocar el .env ni sites-enabled/:
# ninguno de los dos viene en el tarball, así que la extracción no los pisa.

set -euo pipefail

REPO="${NGINX_SYNC_REPO:-aramirez92/nginx-sync}"
REF="${NGINX_SYNC_REF:-main}"
DEST="${NGINX_SYNC_DIR:-/opt/nginx-sync}"
TARBALL_URL="https://github.com/$REPO/archive/$REF.tar.gz"

log()  { printf '[bootstrap] %s\n' "$*"; }
fail() { printf '[bootstrap] ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

if [[ $EUID -ne 0 ]]; then
  fail "hace falta root. Corré:
    curl -fsSL https://raw.githubusercontent.com/$REPO/$REF/bootstrap.sh | sudo bash"
fi

# --- curl y tar ------------------------------------------------------------

# El caso normal es que curl ya esté (este script llegó por curl), pero también
# se puede correr el archivo a mano en una imagen mínima.
MISSING=()
have curl || MISSING+=(curl)
have tar  || MISSING+=(tar)

if [[ ${#MISSING[@]} -gt 0 ]]; then
  log "faltan: ${MISSING[*]}"
  if   have apt-get; then DEBIAN_FRONTEND=noninteractive apt-get update -qq \
                       && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${MISSING[@]}"
  elif have dnf;     then dnf install -y "${MISSING[@]}"
  elif have yum;     then yum install -y "${MISSING[@]}"
  elif have zypper;  then zypper --non-interactive install "${MISSING[@]}"
  elif have apk;     then apk add --no-cache "${MISSING[@]}"
  elif have pacman;  then pacman -Sy --needed --noconfirm "${MISSING[@]}"
  else fail "instalá ${MISSING[*]} a mano y volvé a correr esto."
  fi
  for cmd in "${MISSING[@]}"; do
    have "$cmd" || fail "'$cmd' sigue sin estar en el PATH."
  done
fi

# --- descarga --------------------------------------------------------------

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

log "bajando $REPO@$REF"
curl -fsSL "$TARBALL_URL" -o "$TMP_DIR/src.tar.gz" \
  || fail "no pude bajar $TARBALL_URL (¿existe la rama/tag '$REF'?)."

# Un proxy o un 404 disfrazado devuelven HTML: que tar liste el contenido es la
# forma barata de confirmar que bajó un tar.gz de verdad.
tar -tzf "$TMP_DIR/src.tar.gz" >/dev/null 2>&1 \
  || fail "lo que bajó de GitHub no es un tar.gz válido."

# --- extracción ------------------------------------------------------------

# .env y sites-enabled/*.conf no están en el repo, así que sobreviven a esto.
mkdir -p "$DEST"
tar -xzf "$TMP_DIR/src.tar.gz" -C "$DEST" --strip-components=1
log "código en $DEST"

[[ -f "$DEST/install.sh" ]] || fail "el tarball no trae install.sh. ¿Repo o ref equivocados?"
chmod +x "$DEST/install.sh"

# --- instalación -----------------------------------------------------------

log "ejecutando install.sh"
cd "$DEST"
# exec: install.sh se queda con la terminal, así el wizard puede preguntar.
exec ./install.sh "$@"
