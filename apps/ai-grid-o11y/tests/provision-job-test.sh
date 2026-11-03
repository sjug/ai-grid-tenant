#!/usr/bin/env bash
# Runs the script embedded in job-provision-loki-key.yaml against stub oc and sleep (no cluster). Needs PyYAML.
# shellcheck disable=SC2001  # sed indents the captured output for readability
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; mkdir -p "$T/bin"
python3 -c 'import sys, yaml
d = yaml.safe_load(open(sys.argv[1])); c = d["spec"]["template"]["spec"]["containers"][0]
assert c["command"] == ["/bin/bash", "-c"], c["command"]; open(sys.argv[2], "w").write(c["args"][0])' \
  "$HERE/../manifests/job-provision-loki-key.yaml" "$T/job.sh"
cat > "$T/bin/sleep" <<'END_SLEEP'
#!/usr/bin/env bash
exit 0
END_SLEEP
cat > "$T/bin/oc" <<'END_OC'
#!/usr/bin/env bash
# STUB_PHASES: claim phases on successive reads (last repeats); STUB_READS=fail: every read fails;
# STUB_AK / STUB_SK / STUB_BUCKET: credential values (empty allowed); STUB_APPLY=fail: apply fails;
# STUB_READBACK=empty: the written Secret reads back without a bucket name. Writes go to $STUB_STATE.
args="$*"
[[ "${STUB_READS:-ok}" == fail && "$args" == *" get "* ]] && exit 1
case "$args" in
  *"get objectbucketclaim"*) n=$(cat "$STUB_STATE/n" 2>/dev/null || echo 0); echo $((n+1)) > "$STUB_STATE/n"
    set -- $STUB_PHASES; i=$n; [[ $i -ge $# ]] && i=$(( $# - 1 )); shift "$i"; printf '%s' "$1" ;;
  *"get cm usage-logs-bucket"*) printf '%s' "${STUB_BUCKET-}" ;;
  *"get secret usage-logs-bucket"*"AWS_ACCESS_KEY_ID"*) printf '%s' "$(printf '%s' "${STUB_AK-}" | base64)" ;;
  *"get secret usage-logs-bucket"*"AWS_SECRET_ACCESS_KEY"*) printf '%s' "$(printf '%s' "${STUB_SK-}" | base64)" ;;
  *"create secret generic usage-logs-object-storage"*) printf 'apiVersion: v1\nkind: Secret\nstringData:\n'; for a in "$@"; do case "$a" in --from-literal=*) printf '  %s\n' "${a#--from-literal=}";; esac; done ;;
  *"apply -f -"*) body=$(cat); [[ "${STUB_APPLY:-ok}" == fail ]] && exit 1; printf '%s\n' "$body" > "$STUB_STATE/secret"; echo "secret/usage-logs-object-storage configured" ;;
  *"get secret usage-logs-object-storage"*) [[ -e "$STUB_STATE/secret" && "${STUB_READBACK:-ok}" != empty ]] && printf 'dXNhZ2U=' ;;
  *) exit 0 ;;
esac
END_OC
chmod 700 "$T/bin/oc" "$T/bin/sleep"
fails=0; total=0
run() { # [ENV=VAL ...]: one execution against the retained state; prints nothing, returns the script's status
  (cd "$T" && env -i PATH="$T/bin:/usr/bin:/bin" STUB_STATE="$T/state" STUB_PHASES=Bound STUB_BUCKET=usage-logs-1 STUB_AK=ak STUB_SK=sk "$@" bash job.sh < /dev/null > "$T/out" 2>&1); }
t() { # name expected_rc expected_secret(written|absent) [ENV=VAL ...]: fresh state, one run
  local name=$1 want=$2 wantsec=$3; shift 3; local rc sec; total=$((total+1)); rm -rf "$T/state"; mkdir -p "$T/state"
  run "$@" && rc=0 || rc=$?; [[ -e "$T/state/secret" ]] && sec=written || sec=absent
  if [[ $rc -eq $want && "$sec" == "$wantsec" ]]; then printf '   ok   %-34s rc=%s secret=%s reads=%s\n' "$name" "$rc" "$sec" "$(cat "$T/state/n" 2>/dev/null || echo 0)"
  else printf '   FAIL %-34s rc=%s wanted %s secret=%s wanted %s\n%s\n' "$name" "$rc" "$want" "$sec" "$wantsec" "$(sed 's/^/        /' "$T/out")"; fails=$((fails+1)); fi
}
t bound-at-once 0 written
t bound-after-polls 0 written STUB_PHASES="Pending Pending Pending Bound"
t never-bound 1 absent STUB_PHASES=Pending
t reads-fail 1 absent STUB_READS=fail
t empty-bucket-name 1 absent STUB_BUCKET=
t empty-access-key 1 absent STUB_AK=
t empty-secret-key 1 absent STUB_SK=
t apply-fails 1 absent STUB_APPLY=fail
t read-back-empty 1 written STUB_READBACK=empty
# rerun: a second execution over the state the first one left must succeed and leave the Secret unchanged
total=$((total+1)); rm -rf "$T/state"; mkdir -p "$T/state"
if run && cp "$T/state/secret" "$T/secret-first" && run && cmp -s "$T/secret-first" "$T/state/secret" && grep -q 'bucketnames=usage-logs-1' "$T/state/secret"; then
  printf '   ok   %-34s rc=0 secret=unchanged\n' rerun-over-existing-secret
else printf '   FAIL %-34s\n%s\n' rerun-over-existing-secret "$(sed 's/^/        /' "$T/out")"; fails=$((fails+1)); fi
echo "provision-job tests: $((total-fails)) ok, $fails failed"; exit "$fails"
