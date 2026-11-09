#!/usr/bin/env bash
# Asserts every DB_READ_CONNECTION_URL in the hub policies names maas-read-r and none names maas-read-ro,
# and that both read Services still exist on the hub. No cluster needed.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd); fails=0; total=0
ok() { total=$((total+1)); printf '   ok   %s\n' "$1"; }; bad() { total=$((total+1)); fails=$((fails+1)); printf '   FAIL %s %s\n' "$1" "${2:-}"; }
urls=$(grep -rh 'DB_READ_CONNECTION_URL' "$HERE/apps" --include='*.yaml')
n=$(printf '%s\n' "$urls" | grep -c 'DB_READ_CONNECTION_URL' || true)
if [ "$n" -ge 2 ]; then ok "found $n read connection strings"; else bad "found $n read connection strings" "expected at least 2"; fi
if printf '%s\n' "$urls" | grep -q 'maas-read-ro\.'; then bad "no read connection string names maas-read-ro"; else ok "no read connection string names maas-read-ro"; fi
if [ "$(printf '%s\n' "$urls" | grep -c '@maas-read-r\.maas-db\.svc\.cluster\.local:5432')" = "$n" ]; then ok "every read connection string names maas-read-r"; else bad "every read connection string names maas-read-r"; fi
for f in 30-read-service.yaml 31-read-service-r.yaml; do if [ -f "$HERE/apps/maas-db/primary/$f" ]; then ok "hub alias $f present"; else bad "hub alias $f present"; fi; done
echo "read-url tests: $((total-fails)) ok, $fails failed"; exit "$fails"
