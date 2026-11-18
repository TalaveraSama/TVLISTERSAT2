#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="${MINI_ASTRA_REPO_URL:-https://github.com/TalaveraSama/TVLISTERSAT2.git}"
REF="${MINI_ASTRA_REF:-main}"
PREFIX="${MINI_ASTRA_PREFIX:-/usr/local}"
BIN="${MINI_ASTRA_BIN:-$PREFIX/bin/astra-mini}"
CLI="${MINI_ASTRA_CLI:-$PREFIX/bin/mini-astra}"
CONFIG_DIR="${MINI_ASTRA_CONFIG_DIR:-/etc/mini-astra}"
CONFIG="$CONFIG_DIR/mini-astra.lua"
STATE_DIR="${MINI_ASTRA_STATE_DIR:-/var/lib/mini-astra}"
WORK_DIR="${MINI_ASTRA_WORK_DIR:-/tmp/mini-astra-install}"
SERVICE="${MINI_ASTRA_SERVICE:-mini-astra}"

log() { printf '[mini-astra] %s\n' "$*"; }
fatal() { printf '[mini-astra] ERROR: %s\n' "$*" >&2; exit 1; }
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

[[ "$(id -u)" -eq 0 ]] || fatal "ejecuta este instalador con sudo o como root"
command -v git >/dev/null 2>&1 || fatal "git no está instalado"
command -v gcc >/dev/null 2>&1 || fatal "gcc no está instalado; instala build-essential"
command -v make >/dev/null 2>&1 || fatal "make no está instalado; instala build-essential"
command -v systemctl >/dev/null 2>&1 || fatal "systemd/systemctl no está disponible"

if [[ -z "${MINI_ASTRA_SKIP_APT:-}" ]] && command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends build-essential git ca-certificates pkg-config curl
fi

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
log "clonando $REPO_URL ($REF)"
git clone --depth 1 --branch "$REF" "$REPO_URL" "$WORK_DIR/src"
cd "$WORK_DIR/src"

log "ejecutando pruebas estáticas"
bash tests/test-static.sh

log "compilando"
./configure.sh --bin="$BIN"
make -j"$(nproc)"

log "creando usuario y directorios"
if ! id mini-astra >/dev/null 2>&1; then
    useradd --system --home-dir "$STATE_DIR" --no-create-home --shell /usr/sbin/nologin mini-astra
fi
install -d -o mini-astra -g mini-astra "$STATE_DIR" "$CONFIG_DIR" "$(dirname "$BIN")"
install -m 0755 ./astra "$BIN"
install -m 0755 ./mini-astra "$CLI"
install -m 0644 ./scripts/mini-astra.lua "$CONFIG"
install -m 0644 ./systemd/mini-astra.service "/etc/systemd/system/$SERVICE.service"
chown mini-astra:mini-astra "$STATE_DIR" "$CONFIG"

systemctl daemon-reload
systemctl enable --now "$SERVICE"

log "instalación completada"
log "binario: $BIN"
log "configuración: $CONFIG"
log "servicio: $SERVICE"
log "health: http://127.0.0.1:8000/healthz"
