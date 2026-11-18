#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

for file in README.md BUILDING-UBUNTU.md configure.sh mini-astra install.sh uninstall.sh scripts/mini-astra.lua systemd/mini-astra.service .github/workflows/release.yml; do
    test -f "$ROOT/$file" || { echo "Missing required file: $file" >&2; exit 1; }
done

grep -q 'systemctl' "$ROOT/mini-astra"
grep -q 'health' "$ROOT/mini-astra"
for route in /healthz /readyz /api/v1/status /api/v1/streams; do
    grep -q "$route" "$ROOT/scripts/mini-astra.lua" || { echo "Missing route: $route" >&2; exit 1; }
done

grep -q 'upstream = input:stream()' "$ROOT/examples/relay.lua"
grep -q 'timer({' "$ROOT/examples/relay.lua"
for directive in 'ExecStart=' 'Restart=on-failure' 'NoNewPrivileges=true' 'User=mini-astra'; do
    grep -q "$directive" "$ROOT/systemd/mini-astra.service" || { echo "Missing systemd directive: $directive" >&2; exit 1; }
done

echo 'Mini Astra static checks passed.'
