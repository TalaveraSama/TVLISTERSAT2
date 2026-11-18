#!/usr/bin/env bash
# Mini Astra diagnostic collector. Read-only: does not modify the system.
set -uo pipefail

SERVICE="${MINI_ASTRA_SERVICE:-mini-astra}"
BIN="${MINI_ASTRA_BIN:-/usr/local/bin/astra-mini}"
CONFIG="${MINI_ASTRA_CONFIG:-/etc/mini-astra/mini-astra.lua}"
PORT="${MINI_ASTRA_PORT:-8000}"
UNIT="/etc/systemd/system/$SERVICE.service"

sec() { printf '\n===== %s =====\n' "$*"; }

sec "SISTEMA"
uname -a 2>/dev/null
. /etc/os-release 2>/dev/null && printf '%s %s\n' "${NAME:-}" "${VERSION_ID:-}"

sec "ARCHIVOS"
for f in "$BIN" "$CONFIG" "$UNIT"; do
    if [ -e "$f" ]; then
        ls -l "$f"
    else
        echo "FALTA: $f"
    fi
done
ls -ld /var/lib/mini-astra 2>/dev/null || echo "FALTA: /var/lib/mini-astra"

sec "CONFIG EFECTIVA"
grep -nE 'MINI_ASTRA_|ExecStart|User=|WorkingDirectory' "$UNIT" 2>/dev/null || echo "sin unidad"

sec "PUERTO $PORT"
if command -v ss >/dev/null 2>&1; then
    if ss -ltn 2>/dev/null | grep -q ":$PORT "; then
        echo "OCUPADO: algo escucha ya en el puerto $PORT:"
        ss -ltnp 2>/dev/null | grep ":$PORT " || true
    else
        echo "puerto $PORT libre"
    fi
    echo "--- puertos en escucha ---"
    ss -ltn 2>/dev/null | head -20
else
    echo "ss no disponible"
fi

sec "ESTADO SERVICIO"
systemctl status "$SERVICE" --no-pager -l 2>&1 | head -30

sec "JOURNAL (80 lineas)"
journalctl -u "$SERVICE" -n 80 --no-pager 2>&1 | tail -80

sec "EJECUCION EN PRIMER PLANO (5s, captura el error real)"
if [ -x "$BIN" ] && [ -r "$CONFIG" ]; then
    if command -v timeout >/dev/null 2>&1; then
        sudo -u mini-astra timeout 5 "$BIN" "$CONFIG" 2>&1 | head -40 \
            || echo "(termino con codigo $?)"
    else
        echo "timeout no disponible"
    fi
else
    echo "no se puede ejecutar: binario o config ausente"
fi

sec "COREDUMPS"
if command -v coredumpctl >/dev/null 2>&1; then
    coredumpctl list 2>/dev/null | tail -5 || true
else
    echo "coredumpctl no disponible"
fi

sec "ENDPOINTS"
for p in health healthz readyz api/v1/status api/v1/streams; do
    printf '%-18s ' "/$p"
    curl -s -o /dev/null -w '%{http_code}\n' --max-time 3 "http://127.0.0.1:$PORT/$p" 2>/dev/null || echo "sin respuesta"
done

printf '\n===== FIN =====\n'
