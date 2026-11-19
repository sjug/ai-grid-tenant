#!/usr/bin/env bash
# Every Argo CD hook Job in this app must carry BeforeHookCreation in its delete policy. Argo CD names a
# generateName hook once per sync operation, and its automatic retries reuse that name, so without
# BeforeHookCreation a failed Job stays and every retry reports it failed again: the app stays OutOfSync
# even after the cause (such as the store Route arriving late) is gone.
set -Eeuo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); fails=0; total=0
ok() { total=$((total+1)); printf '   ok   %s\n' "$1"; }; bad() { total=$((total+1)); fails=$((fails+1)); printf '   FAIL %s: %s\n' "$1" "${2:-}"; }
for f in "$HERE"/../manifests/*.yaml; do
  grep -q 'argocd.argoproj.io/hook:' "$f" || continue
  name=$(basename "$f")
  policy=$(sed -n 's/^ *argocd\.argoproj\.io\/hook-delete-policy: *//p' "$f")
  case ",$policy," in
    *,BeforeHookCreation,*) ok "$name recreates its Job on retry ($policy)";;
    *) bad "$name" "hook-delete-policy is '${policy:-unset}', want BeforeHookCreation in it";;
  esac
  case ",$policy," in
    *,HookSucceeded,*) ok "$name deletes its Job after success";;
    *) bad "$name" "hook-delete-policy '${policy:-unset}' dropped HookSucceeded";;
  esac
done
[ "$total" -ge 4 ] || bad "hook count" "found $((total/2)) hook manifests, want at least 2"
printf '%d/%d ok\n' $((total-fails)) "$total"; [ "$fails" -eq 0 ]
