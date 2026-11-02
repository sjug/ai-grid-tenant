#!/usr/bin/env bash
# Exercises trust-maas-home-ca.sh with real certificates (openssl) and stub oc and curl (no cluster); writes are
# asserted on the stub's record.
# shellcheck disable=SC2016  # the stub curl and the sourced helper are written as literal scripts
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); SCRIPT="$HERE/../trust-maas-home-ca.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; mkdir -p "$T/bin" "$T/fx"
mkcert() { openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$T/fx/$1.key" -out "$T/fx/$1.pem" -subj "/CN=$1" -days 2 >/dev/null 2>&1; }
mkcert home-ca; mkcert existing-root; printf 'this is not a certificate\n' > "$T/fx/garbage.pem"
fp() { openssl x509 -in "$1" -noout -fingerprint -sha256; }
cat > "$T/bin/oc" <<'END_OC'
#!/usr/bin/env bash
# STUB_STATE: directory with cm/<name> files (existing ConfigMap bundles), counters and the record of writes.
# STUB_CMS: ok|fail for the mounted ConfigMaps check. STUB_PROXY: the proxy's trustedCA name. STUB_CM_ERROR: a
# ConfigMap whose read fails with a non-NotFound error. STUB_HOME_CA: file served as the home's router CA.
# STUB_SITE_FILE: bundle the mounted ConfigMap serves (default: whatever was written); STUB_SITE_BEFORE: bundle
# served for the first STUB_SITE_AFTER reads; STUB_SITE_MALFORMED=1 serves garbage; STUB_SITE_DELAY: seconds a read takes.
args="$*"; S="$STUB_STATE"
case "$args" in
  *"get configmap odh-trusted-ca-bundle openshift-service-ca.crt"*) [[ "${STUB_CMS:-ok}" == ok ]] || { echo 'Error from server (NotFound): configmaps "openshift-service-ca.crt" not found' >&2; exit 1; } ;;
  *"--kubeconfig"*"get secret router-ca"*) base64 -w0 < "$STUB_HOME_CA" ;;
  *"get proxy cluster"*) printf '%s' "${STUB_PROXY:-}" ;;
  *"-n openshift-config get configmap "*)
    set -- $args; name=""; prev=""; for a in "$@"; do [[ "$prev" == configmap ]] && name=$a; prev=$a; done
    if [[ "${STUB_CM_ERROR:-}" == "$name" ]]; then echo "Error from server (Forbidden): configmaps \"$name\" is forbidden" >&2; exit 1; fi
    if [[ -e "$S/cm/$name" ]]; then cat "$S/cm/$name"; else echo "Error from server (NotFound): configmaps \"$name\" not found" >&2; exit 1; fi ;;
  *"create configmap custom-ca --from-file=ca-bundle.crt="*) f=$(printf '%s' "$args" | sed -n 's/.*--from-file=ca-bundle.crt=\([^ ]*\).*/\1/p'); cp "$f" "$S/staged"; echo "apiVersion: v1" ;;
  *"apply -f -"*) cat > /dev/null; cp "$S/staged" "$S/written"; echo "configmap/custom-ca configured" ;;
  *"patch proxy/cluster"*) touch "$S/patched"; echo "proxy.config.openshift.io/cluster patched" ;;
  *"get configmap odh-trusted-ca-bundle -o jsonpath"*)
    n=$(cat "$S/reads" 2>/dev/null || echo 0); echo $((n+1)) > "$S/reads"
    [[ -n "${STUB_SITE_DELAY:-}" ]] && sleep "$STUB_SITE_DELAY"
    if [[ "${STUB_SITE_MALFORMED:-0}" == 1 ]]; then printf 'garbage'; exit 0; fi
    if [[ -n "${STUB_SITE_AFTER:-}" && "$n" -lt "$STUB_SITE_AFTER" ]]; then cat "$STUB_SITE_BEFORE"; exit 0; fi
    f="${STUB_SITE_FILE:-$S/written}"; [[ -e "$f" ]] && cat "$f" ;;
  *) exit 0 ;;
esac
END_OC
printf '#!/usr/bin/env bash\n[[ "${STUB_CURL:-ok}" == ok ]] || { echo "curl: (60) SSL certificate problem" >&2; exit 60; }\n' > "$T/bin/curl"
# sort and comm wrappers: real behaviour unless the test makes them fail (the verification path's unchecked commands)
printf '#!/usr/bin/env bash\n[[ "${STUB_SORT:-ok}" == ok ]] || exit 1\nexec /usr/bin/sort "$@"\n' > "$T/bin/sort"
printf '#!/usr/bin/env bash\n[[ "${STUB_COMM:-ok}" == ok ]] || exit 1\nexec /usr/bin/comm "$@"\n' > "$T/bin/comm"
chmod 700 "$T/bin/oc" "$T/bin/curl" "$T/bin/sort" "$T/bin/comm"; fails=0; total=0
t() { # name expected_rc expected_write(written|none) expected_fps(file list or -) [ENV=VAL ...]
  local name=$1 want=$2 wantw=$3 wantfp=$4; shift 4; local rc w got want_fps; total=$((total+1)); rm -rf "$T/state"; mkdir -p "$T/state/cm"
  for a in "$@"; do case "$a" in CM:*) spec=${a#CM:}; cp "${spec#*=}" "$T/state/cm/${spec%%=*}";; esac; done
  local envs=(); for a in "$@"; do [[ "$a" == CM:* ]] || envs+=("$a"); done
  (cd "$T" && env -i PATH="$T/bin:/usr/bin:/bin" STUB_STATE="$T/state" STUB_HOME_CA="$T/fx/home-ca.pem" KEYCLOAK_HOST=keycloak.example.test REALM=saas HOME_KUBECONFIG=/dev/null \
     WORKDIR="$T/state/work" TIMEOUT_SECONDS=5 POLL_SECONDS=0 "${envs[@]}" bash "$SCRIPT" > "$T/out" 2>&1) && rc=0 || rc=$?
  [[ -e "$T/state/written" ]] && w=written || w=none
  if [[ "$wantfp" != - && "$w" == written ]]; then
    got=$(cd "$T" && env PATH="$T/bin:/usr/bin:/bin" bash -c 'source <(sed -n "/^fingerprints() {/,/^}/p" "$0"); WORKDIR=$1; fingerprints "$2"' "$SCRIPT" "$T/state" "$T/state/written" | sort -u)
    want_fps=$(for f in ${wantfp//,/ }; do fp "$T/fx/$f.pem"; done | sort -u)
  else got=-; want_fps=-; fi
  if [[ $rc -eq $want && "$w" == "$wantw" && "$got" == "$want_fps" ]]; then printf '   ok   %-38s rc=%s write=%s\n' "$name" "$rc" "$w"
  else printf '   FAIL %-38s rc=%s wanted %s write=%s wanted %s fps-match=%s\n%s\n' "$name" "$rc" "$want" "$w" "$wantw" "$([[ "$got" == "$want_fps" ]] && echo yes || echo no)" "$(sed 's/^/        /' "$T/out" | tail -n 6)"; fails=$((fails+1)); fi
}
t fresh-site 0 written home-ca
t proxy-bundle-preserved 0 written home-ca,existing-root STUB_PROXY=my-bundle "CM:my-bundle=$T/fx/existing-root.pem"
t unreferenced-custom-ca-preserved 0 written home-ca,existing-root "CM:custom-ca=$T/fx/existing-root.pem"
t ownership-collision-refused 1 none - STUB_PROXY=my-bundle "CM:my-bundle=$T/fx/existing-root.pem" "CM:custom-ca=$T/fx/existing-root.pem"
t read-error-not-notfound 1 none - STUB_CM_ERROR=custom-ca
t malformed-existing-bundle 1 none - "CM:custom-ca=$T/fx/garbage.pem"
t malformed-home-ca 1 none - STUB_HOME_CA="$T/fx/garbage.pem"
t mounted-configmaps-missing 1 none - STUB_CMS=fail
t propagation-parser-failure 1 written home-ca STUB_SITE_MALFORMED=1
t propagation-after-polls 0 written home-ca STUB_SITE_AFTER=3 STUB_SITE_BEFORE="$T/fx/existing-root.pem"
t propagation-never-completes 1 written home-ca STUB_SITE_FILE="$T/fx/existing-root.pem" TIMEOUT_SECONDS=1
t success-only-after-deadline 1 written home-ca STUB_SITE_DELAY=2 TIMEOUT_SECONDS=1
t tls-verification-fails 1 written home-ca STUB_CURL=fail
t sort-failure-refused 1 none - STUB_SORT=fail
t comm-failure-refused 1 written home-ca STUB_COMM=fail
echo "trust-maas-home-ca tests: $((total-fails)) ok, $fails failed"; exit "$fails"
