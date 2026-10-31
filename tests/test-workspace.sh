#!/usr/bin/env bash
# Workspace boards: one Project, many repos. Offline: --items and --deps are injected,
# and the workflow runs under node with agent/pipeline stubbed.
set -euo pipefail
cd "$(dirname "$0")/.."
SCRIPTS=$PWD/scripts
WAVE=$PWD/workflows/super-board-wave.js
TMP=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }

WS=$TMP/ws
mkdir -p "$WS/.claude/super-board/configs"
for r in api web; do
  git init -q "$WS/$r"; git -C "$WS/$r" remote add origin "https://github.com/acme/$r.git"
done
CFG=$WS/.claude/super-board/configs/acme.json
cat > "$CFG" <<'JSON'
{ "project": {"owner":"acme","number":1}, "base_branch":"main", "verify_commands":["true"],
  "merge_policy": {"default":"auto","auto_max_lines":400},
  "repos": {
    "api": {"path":"api","remote":"https://github.com/acme/api","base_branch":"staging","merge_policy":{"default":"human"}},
    "web": {"path":"web","remote":"https://github.com/acme/web.git","verify_commands":["npm test"]} } }
JSON
WSPY=(python3 "$SCRIPTS/super-board-workspace.py")

# 1 — resolve: repo values override, objects merge, lists replace, state is untracked.
OUT=$("${WSPY[@]}" resolve --config "$CFG")
API=$(echo "$OUT" | jq -r .api.configPath)
WEB=$(echo "$OUT" | jq -r .web.configPath)
jq -e '.base_branch=="staging" and .merge_policy.default=="human" and .merge_policy.auto_max_lines==400 and .verify_commands==["true"]' "$API" >/dev/null || fail "api override: $(cat "$API")"
jq -e '.base_branch=="main" and .verify_commands==["npm test"] and (has("repos")|not) and .workspace.repo=="web"' "$WEB" >/dev/null || fail "web override"
[ "$(jq -r .repo.path "$API")" = "$(cd "$WS/api" && pwd -P)" ] || fail "repo.path must be absolute: $(jq -r .repo.path "$API")"
grep -qx '.claude/worktrees/' "$WS/api/.git/info/exclude" || fail "worktrees must be excluded"
"${WSPY[@]}" resolve --config "$CFG" >/dev/null
[ "$(grep -c '^.claude/worktrees/$' "$WS/api/.git/info/exclude")" = 1 ] || fail "exclude must be idempotent"

# 2 — validate reports every problem, and refuses a checkout that is not the named repo.
BAD=$WS/.claude/super-board/configs/bad.json
jq '.repos.api.remote="https://github.com/acme/other" | .repos.web.path="nope" | .worker_backend="claude-p"' "$CFG" > "$BAD"
set +e; ERR=$("${WSPY[@]}" validate --config "$BAD" 2>&1); rc=$?; set -e
[ "$rc" = 66 ] || fail "bad workspace must exit 66, got $rc"
for want in 'repos.api: origin' 'repos.web:' 'worker_backend'; do
  echo "$ERR" | grep -q "$want" || fail "validate missing '$want': $ERR"
done
rm "$BAD"

# 3 — verify_commands is checked for every repo, inherited or own.
python3 "$SCRIPTS/super-board-verification-ready.py" --config "$CFG" || fail "ready workspace refused"
set +e
jq '.verify_commands=[]' "$CFG" | python3 "$SCRIPTS/super-board-verification-ready.py" --config - 2>"$TMP/err"; rc=$?
set -e
[ "$rc" = 9 ] && grep -q 'repos.api' "$TMP/err" || fail "repo inheriting no verify_commands must exit 9, got $rc"

# 4 — the plan: #12 exists in both repos and both survive; a foreign repo never runs.
cat > "$TMP/items.json" <<'JSON'
{"items":[
 {"status":"Ready","content":{"type":"Issue","number":12,"title":"api twelve","repository":"acme/api"}},
 {"status":"Ready","content":{"type":"Issue","number":12,"title":"web twelve","repository":"acme/web"},"labels":["qa"]},
 {"status":"Review","content":{"type":"Issue","number":7,"title":"web review","repository":"acme/web"}},
 {"status":"Blocked","content":{"type":"Issue","number":3,"title":"api blocked","repository":"acme/api"}},
 {"status":"Ready","content":{"type":"Issue","number":9,"title":"foreign","repository":"acme/other"}},
 {"status":"Ready","content":{"type":"DraftIssue","title":"draft"}}
],"totalCount":6}
JSON
DEP='{"number":0,"parseable":true,"runnable":true,"blockers":[],"openBlockers":[],"why":""}'
cat > "$TMP/deps.json" <<JSON
{"api":{"12":$DEP,"3":$DEP},"web":{"12":$DEP,"7":$DEP}}
JSON
PLAN=$(bash "$SCRIPTS/super-board-wave-plan.sh" --config "$CFG" --items "$TMP/items.json" --deps "$TMP/deps.json")
echo "$PLAN" | jq -e '[.cards[].key] == ["web#7","api#12","web#12"]' >/dev/null || fail "downstream-first across repos: $PLAN"
echo "$PLAN" | jq -e '.cards[] | select(.key=="web#12") | .lane=="qa" and .repo=="web" and .repoSlug=="acme/web" and (.configPath|endswith("resolved/acme/web.json"))' >/dev/null || fail "card tags: $PLAN"
echo "$PLAN" | jq -e '.cards[] | select(.key=="api#12") | .lane=="build"' >/dev/null || fail "labels must not leak between repos: $PLAN"
echo "$PLAN" | jq -e '[.sweep[].key]==["api#3"]' >/dev/null || fail "sweep must carry its key: $PLAN"
echo "$PLAN" | jq -e '.flag[] | select(.key=="acme/other#9") | .why|test("not in this workspace")' >/dev/null || fail "foreign card must be flagged: $PLAN"

# 5 — max_workers caps the merged wave, not each repo.
CAPPED=$WS/.claude/super-board/configs/capped.json
jq '.max_workers=2' "$CFG" > "$CAPPED"
bash "$SCRIPTS/super-board-wave-plan.sh" --config "$CAPPED" --items "$TMP/items.json" --deps "$TMP/deps.json" \
  | jq -e '[.cards[].key]==["web#7","api#12"]' >/dev/null || fail "cap must apply after the merge"
rm "$CAPPED"

# 6 — cross-repo blockers.
issue() { jq -n --arg b "$2" --argjson n "$1" '{number:$n,title:"t",body:("## Blocked by\n"+$b),state:"OPEN",labels:{nodes:[]},comments:{nodes:[]}}'; }
{ issue 1 '- api#5 — needs the endpoint'; issue 2 '- acme/api#6 — closed already'; issue 3 '- nobody#1 — unknown repo'
  issue 4 '- None — but api#5 first'; issue 5 '- #1 — local'; issue 6 '- web#1 — written the long way'; } | jq -s . > "$TMP/issues.json"
jq -n --arg b 'x' '[{number:8,title:"t",body:"## Blocked by\n- None.",state:"OPEN",labels:{nodes:[]},comments:{nodes:[{body:"blocked-by: 1, api#5"}]}}]' > "$TMP/issues2.json"
echo '["acme/api#5"]' > "$TMP/open.json"
ALIASES='{"api":"acme/api","acme/api":"acme/api","web":"acme/web","acme/web":"acme/web"}'
deps() { bash "$SCRIPTS/super-board-deps.sh" --repo acme/web --from "$1" --workspace-open "$TMP/open.json" --aliases "$ALIASES"; }
D=$(deps "$TMP/issues.json")
echo "$D" | jq -e '."1" | .parseable and (.runnable|not) and .openBlockers==["acme/api#5"]' >/dev/null || fail "open cross-repo blocker holds: $D"
echo "$D" | jq -e '."2" | .runnable and .blockers==["acme/api#6"]' >/dev/null || fail "closed cross-repo blocker frees: $D"
echo "$D" | jq -e '."3" | .parseable==false and .runnable==false' >/dev/null || fail "unknown repo fails safe: $D"
echo "$D" | jq -e '."4" | .parseable==false' >/dev/null || fail "None-but-names fails safe: $D"
echo "$D" | jq -e '."6" | .blockers==[1] and (.runnable|not)' >/dev/null || fail "a ref to this repo is a plain number: $D"
deps "$TMP/issues2.json" | jq -e '."8" | .blockers==[1,"acme/api#5"] and .openBlockers==["acme/api#5"]' >/dev/null || fail "blocked-by comment with a cross-repo ref"
# Without the workspace flags a qualified ref stays unreadable, as it always was.
bash "$SCRIPTS/super-board-deps.sh" --repo acme/web --from "$TMP/issues.json" | jq -e '."1".parseable==false' >/dev/null || fail "single-repo behaviour changed"

# 7 — one halt file across the workspace.
HALT() { (cd "$1" && python3 - "$SCRIPTS" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location('r', sys.argv[1] + '/super-board-github-read.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); print(m.halt_path())
PY
); }
[ "$(HALT "$WS/api")" = "$(HALT "$WS/web")" ] || fail "repos must share a halt file: $(HALT "$WS/api")"
git init -q "$TMP/solo"
case "$(HALT "$TMP/solo")" in *solo/.claude/super-board/github-halt.json) ;; *) fail "single repo halt path changed: $(HALT "$TMP/solo")" ;; esac

# 8 — the card cache cannot move the wrong repo's #12.
CACHE=$TMP/cache; mkdir -p "$CACHE"
echo '{"items":{"acme/api#12":"ITEM_API","acme/web#12":"ITEM_WEB"}}' > "$CACHE/board-acme-1.json"
for pair in api:ITEM_API web:ITEM_WEB; do
  got=$(SB_CARD_CACHE_DIR=$CACHE bash "$SCRIPTS/super-board-card.sh" --owner acme --number 1 --repo "acme/${pair%%:*}" item-id 12)
  [ "$got" = "${pair##*:}" ] || fail "cache for ${pair%%:*}#12 returned $got"
done

# 9 — Codex refuses rather than guessing a checkout.
set +e
(cd "$WS/api" && bash "$SCRIPTS/super-board-lane.sh" --backend codex --codex --config "$API" --card '{"number":1,"status":"Ready"}' --lane build >/dev/null 2>&1); [ $? = 78 ] || fail "lane must refuse a workspace config"
(cd "$WS/api" && bash "$SCRIPTS/super-board-codex-wave.sh" --config "$CFG" --cards '[]' --codex >/dev/null 2>&1); [ $? = 78 ] || fail "codex wave must refuse a workspace config"
set -e

# 10 — allowlist uses absolute paths and offers merging only when asked.
mkdir -p "$WS/.claude/bin"; touch "$WS/.claude/bin/super-board-card.sh" "$WS/.claude/bin/super-board-merge-gate.sh" "$WS/.claude/bin/super-board-run.sh"
RULES=$("${WSPY[@]}" allowlist --config "$CFG")
echo "$RULES" | jq -e --arg p "$WS/.claude/bin/super-board-card.sh" 'index("Bash(bash \($p):*)") != null' >/dev/null || fail "allowlist: $RULES"
echo "$RULES" | grep -qE 'merge-gate|super-board-run|gh pr merge' && fail "merge lines need --merge: $RULES"
"${WSPY[@]}" allowlist --config "$CFG" --merge | grep -q 'merge-gate' || fail "--merge must add the gate"

# 11 — the wave keeps colliding numbers apart and scopes every agent.
node - "$WAVE" <<'JS'
const fs = require('fs')
const src = fs.readFileSync(process.argv[2], 'utf8').replace(/^export const meta/m, 'const meta')
const AsyncFunction = (async () => {}).constructor
const fail = (m) => { console.error('FAIL: ' + m); process.exit(1) }
const card = (repo, number) => ({ number, status: 'Ready', title: `${repo}${number}`, lane: 'build', labels: ['feature'],
  repo, key: `${repo}#${number}`, configPath: `/ws/.claude/super-board/resolved/s/${repo}.json`, repoPath: `/ws/${repo}`,
  repoSlug: `acme/${repo}`, workspaceRoot: '/ws' })
const prompts = {}
const agent = async (prompt, opts) => {
  prompts[opts.label] = prompt
  if (opts.label.startsWith('preflight:api')) return { verdicts: [{ number: 12, verdict: 'hold', column: 'Blocked', detail: 'duplicate' }] }
  if (opts.label.startsWith('preflight:web')) return { verdicts: [{ number: 12, verdict: 'proceed', detail: 'clean' }] }
  if (opts.label.startsWith('classify')) return { kind: 'feature', complexity: 'low' }
  return { status: 'advanced', column: opts.label.startsWith('review') ? 'Done' : 'next', detail: 'ok' }
}
const pipeline = async (items, ...stages) => Promise.all(items.map(async (it) => {
  let v = it
  for (const [i, st] of stages.entries()) v = i === 0 ? await st(it) : await st(v, it)
  return v
}))
const cfg = '/ws/.claude/super-board/configs/s.json'
new AsyncFunction('args', 'agent', 'pipeline', 'log', src)({ configPath: cfg, cards: [card('api', 12), card('web', 12)] }, agent, pipeline, () => {}).then((out) => {
  const labels = Object.keys(prompts)
  labels.includes('preflight:api:#12') && labels.includes('preflight:web:#12') || fail('pre-flight must batch per repo: ' + labels)
  labels.includes('build:api#12') && fail('api#12 was held and must not build')
  labels.includes('build:web#12') || fail('web#12 proceeded and must build: ' + labels)
  const by = (k) => out.cards.find((c) => c.key === k)
  by('api#12').lastLane === 'preflight' || fail('api#12 result: ' + JSON.stringify(by('api#12')))
  by('web#12').finalStatus === 'advanced' && by('web#12').repoSlug === 'acme/web' || fail('web#12 result: ' + JSON.stringify(by('web#12')))
  for (const [label, p] of Object.entries(prompts)) {
    const repo = label.includes('api') ? 'api' : 'web'
    p.includes(`cd "/ws/${repo}"`) || fail(`${label} must cd to its checkout`)
    p.includes(cfg) && fail(`${label} still names the workspace config`)
    ;/(^|[^/\w])\.claude\/bin\/super/.test(p.split('\n').slice(3).join('\n')) && fail(`${label} has a relative pack path`)
    p.includes('--root "/ws"') || fail(`${label} must check skills at the workspace root`)
  }
}).catch((e) => fail(e.stack))
JS

echo "test-workspace: all passed"
