#!/usr/bin/env bash
set -Eeuo pipefail
SERVICE="${MINI_ASTRA_SERVICE:-mini-astra}"
BIN="${MINI_ASTRA_BIN:-/usr/local/bin/astra-mini}"
CLI="${MINI_ASTRA_CLI:-/usr/local/bin/mini-astra}"
CONFIG_DIR="${MINI_ASTRA_CONFIG_DIR:-/etc/mini-astra}"
STATE_DIR="${MINI_ASTRA_STATE_DIR:-/var/lib/mini-astra}"

[[ "$(id -u)" -eq 0 ]] || { echo 'Ejecuta con sudo.' >&2; exit 1; }
if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now "$SERVICE" 2>/dev/null || true
fi
rm -f "/etc/systemd/system/$SERVICE.service" "$BIN" "$CLI"
rm -rf "$CONFIG_DIR"
if command -v systemctl >/dev/null 2>&1; then systemctl daemon-reload; fi
printf 'Mini Astra desinstalado. Estado conservado en %s.\n' "$STATE_DIR"
