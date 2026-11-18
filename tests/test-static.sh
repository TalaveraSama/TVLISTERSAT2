#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

for file in README.md BUILDING-UBUNTU.md configure.sh mini-astra install.sh uninstall.sh scripts/doctor.sh scripts/mini-astra.lua systemd/mini-astra.service .github/workflows/release.yml; do
    test -f "$ROOT/$file" || { echo "Missing required file: $file" >&2; exit 1; }
done

grep -q 'systemctl' "$ROOT/mini-astra"
grep -q 'health' "$ROOT/mini-astra"
for route in /healthz /readyz /api/v1/status /api/v1/streams; do
    grep -q "$route" "$ROOT/scripts/mini-astra.lua" || { echo "Missing route: $route" >&2; exit 1; }
done

grep -q 'upstream = input:stream()' "$ROOT/examples/relay.lua"
grep -q 'timer({' "$ROOT/examples/relay.lua"
grep -q 'streams.json' "$ROOT/scripts/mini-astra.lua"
if grep -q 'http_static' "$ROOT/scripts/mini-astra.lua"; then
    echo 'Control configuration must not register http_static.' >&2
    exit 1
fi
# El callback se invoca con request == nil al cerrar la conexion: responder
# en ese caso escribe sobre un socket ya cerrado y provoca SIGSEGV.
guards=$(grep -c 'if not request then return end' "$ROOT/scripts/mini-astra.lua")
handlers=$(grep -c '^local function on_' "$ROOT/scripts/mini-astra.lua")
if [ "$guards" -ne "$handlers" ]; then
    echo "Unsafe handlers: $guards guards for $handlers handlers." >&2
    exit 1
fi
# getifaddrs() requiere AF_NETLINK: sin ella el servicio aborta (SIGABRT).
grep -q 'AF_NETLINK' "$ROOT/systemd/mini-astra.service" || {
    echo 'systemd unit must allow AF_NETLINK.' >&2; exit 1; }
# /dev/dvb/* es root:video; sin el grupo el escaneo no abre el adaptador.
grep -q 'SupplementaryGroups=.*video' "$ROOT/systemd/mini-astra.service" || {
    echo 'systemd unit must join the video group for DVB.' >&2; exit 1; }
for route in /api/v1/adapters /api/v1/scan; do
    grep -q "$route" "$ROOT/scripts/mini-astra.lua" || { echo "Missing route: $route" >&2; exit 1; }
done
for directive in 'ExecStart=' 'Restart=on-failure' 'NoNewPrivileges=true' 'User=mini-astra'; do
    grep -q "$directive" "$ROOT/systemd/mini-astra.service" || { echo "Missing systemd directive: $directive" >&2; exit 1; }
done

echo 'Mini Astra static checks passed.'
