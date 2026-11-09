#!/usr/bin/env bash
# Runs the DataScienceCluster health check (extracted from the ArgoCD CR) under Lua, without the os, io, string
# and package libraries like Argo CD's sandbox, against status fixtures. Needs lua5.4 (or lua/luajit) and PyYAML.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
LUA=$(command -v lua5.4 || command -v lua || command -v luajit) || { echo "no Lua interpreter" >&2; exit 1; }
python3 -c 'import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
for h in d["spec"]["resourceHealthChecks"]:
    if h.get("kind") == "DataScienceCluster": open(sys.argv[2], "w").write(h["check"]); break
else: raise SystemExit("no DataScienceCluster health check")' "$HERE/../manifests/argocd.yaml" "$T/check.lua"
cat > "$T/fixtures.lua" <<'END_LUA'
local function conds(list) local t = {} for _, c in ipairs(list) do t[#t+1] = {type=c[1], status=c[2], message=c[3], reason=c[4]} end return t end
local function shape(extra)
  local list = {
    {"KserveReady","True"}, {"AIGridReady","True"}, {"ProvisioningSucceeded","True"}, {"ComponentsReady","True"},
    {"AIGatewayReady","False","0/0 deployments ready"}, {"Ready","False","Some modules are not ready: aigateway"},
    {"ModulesReady","False","Some modules are not ready: aigateway"}, {"Progressing","False"}, {"Degraded","False"},
    {"DashboardReady","False",nil,"Removed"}, {"KserveConfidentialContainerDependencies","False",nil,"PreConditionFailed"},
  }
  for _, e in ipairs(extra or {}) do list[#list+1] = e end
  return list
end
local function dsc(phase, list, maas, gen, obs, err)
  return {metadata={generation=gen}, spec={components={aigateway={modelsAsAService={managementState=maas}}}},
          status={phase=phase, conditions=list and conds(list) or nil, observedGeneration=obs, errorMessage=err}}
end
F = {
  {"no-status", {metadata={}, spec={}}, "Progressing"},
  {"stale-generation", dsc("Ready", {{"Ready","True"}}, "Managed", 3, 2), "Progressing"},
  {"error-message", dsc("Ready", {{"Ready","True"}}, "Managed", 1, 1, "boom"), "Degraded"},
  {"phase-error", dsc("Error", {{"Ready","False"}}, "Managed", 1, 1), "Degraded"},
  {"degraded-true", dsc("Ready", {{"Ready","True"},{"Degraded","True","bad"}}, "Managed", 1, 1), "Degraded"},
  {"ready-cluster", dsc("Ready", {{"Ready","True"},{"Degraded","False"}}, "Managed", 1, 1), "Healthy"},
  {"inference-only-shape", dsc("Not Ready", shape(), "Removed", 1, 1), "Progressing"},
  {"shape-plus-not-ready-condition", dsc("Not Ready", shape({{"WorkbenchesReady","False","no","Error"}}), "Removed", 1, 1), "Progressing"},
  {"shape-with-degraded-true", dsc("Not Ready", shape({{"Degraded","True","bad"}}), "Removed", 1, 1), "Degraded"},
  {"shape-with-progressing-true", dsc("Not Ready", shape({{"Progressing","True"}}), "Removed", 1, 1), "Progressing"},
  {"shape-other-gateway-message", dsc("Not Ready", shape({{"AIGatewayReady","False","1/2 deployments ready"}}), "Removed", 1, 1), "Progressing"},
  {"shape-but-maas-managed", dsc("Not Ready", shape(), "Managed", 1, 1), "Progressing"},
  {"ready-false-after-reconcile", dsc("Ready", {{"Ready","False","not ready"},{"Degraded","False"}}, "Managed", 1, 1), "Degraded"},
  {"shape-missing-progressing-condition", dsc("Not Ready", shape({{"Progressing", nil}}), "Removed", 1, 1), "Progressing"},
  {"shape-missing-degraded-condition", dsc("Not Ready", shape({{"Degraded", nil}}), "Removed", 1, 1), "Progressing"},
  {"shape-missing-observed-generation", dsc("Not Ready", shape(), "Removed", 1, nil), "Progressing"},
  {"current-operator-shape", dsc("Not Ready", {{"KserveReady","True"},{"AIGridReady","True"},{"ProvisioningSucceeded","True"},{"ComponentsReady","True"},{"AIGatewayReady","False","0/0 deployments ready"},{"Ready","False","Some modules are not ready: aigateway"},{"ModulesReady","False","Some modules are not ready: aigateway"},{"KserveConfidentialContainerDependencies","False","no runtime","PreConditionFailed"}}, "Removed", 4, nil), "Progressing"},
  {"shape-with-unknown-degraded", dsc("Not Ready", shape({{"Degraded","Unknown"}}), "Removed", 1, 1), "Progressing"},
  {"fixed-build-gateway-ready", dsc("Ready", {{"Ready","True"},{"AIGatewayReady","True"},{"Progressing","False"},{"Degraded","False"}}, "Removed", 1, 1), "Healthy"},
}
END_LUA
cat > "$T/run.lua" <<'END_LUA'
dofile(arg[1])
-- Argo CD's Lua sandbox exposes no os, io, string or package libraries to a health check; load the check
-- into an environment with only the basics it may use, so a check that reached for more would fail here.
local src = assert(io.open(arg[2])):read("a")
local function sandboxed(o)
  local env = {ipairs = ipairs, pairs = pairs, type = type, tostring = tostring, tonumber = tonumber, next = next, select = select, error = error, obj = o}
  return assert(load(src, "check", "t", env))
end
local fails, total = 0, 0
for _, f in ipairs(F) do
  total = total + 1
  local ok, hs = pcall(sandboxed(f[2]))
  local got = ok and hs and hs.status or ("error: " .. tostring(hs))
  if got == f[3] then print(string.format("   ok   %-34s %s", f[1], got))
  else print(string.format("   FAIL %-34s got %s wanted %s", f[1], got, f[3])); fails = fails + 1 end
end
print(string.format("dsc-health tests: %d ok, %d failed", total - fails, fails))
os.exit(fails)
END_LUA
# the first condition of a duplicate type wins in the check's "has"; fixtures append overrides after the base list,
# so for the overriding cases replace in place instead
sed -i 's/for _, e in ipairs(extra or {}) do list\[#list+1\] = e end/for _, e in ipairs(extra or {}) do local out = {}; local replaced = false; for _, c in ipairs(list) do if c[1] == e[1] then replaced = true; if e[2] ~= nil then out[#out+1] = e end else out[#out+1] = c end end; if not replaced then out[#out+1] = e end; list = out end/' "$T/fixtures.lua"
"$LUA" "$T/run.lua" "$T/fixtures.lua" "$T/check.lua"
