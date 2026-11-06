#!/bin/bash
# Checks `schedulai digest` and `schedulai hooks` end to end, on copies only:
# the jobs are copied into a temp dir (SCHEDULAI_DEMO), settings.json into a
# temp CLAUDE_CONFIG_DIR. Nothing under ~/.claude is written.
# Usage: scripts/verify-digest.sh [path/to/Schedulai]   (default: a debug build)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -n "${1:-}" ]]; then
  BIN="$1"
else
  (cd "$ROOT" && /usr/bin/swift build >/dev/null)
  BIN="$(cd "$ROOT" && /usr/bin/swift build --show-bin-path)/Schedulai"
fi
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
step() { echo; echo "\$ $*"; }

# Jobs: a copy of the real ones when there are some, plus one fake job.
export SCHEDULAI_DEMO="$TMP/jobs"
mkdir -p "$SCHEDULAI_DEMO"
for dir in "$HOME/.claude/scheduled"/*/; do
  [[ -d $dir ]] && cp -R "${dir%/}" "$SCHEDULAI_DEMO/"
done
mkdir -p "$SCHEDULAI_DEMO/zz-fake/logs"
echo '{"startedAt":"2000-01-01T00:00:00Z","endedAt":"2000-01-01T00:01:00Z","exitCode":0,"log":"old.log"}' \
  > "$SCHEDULAI_DEMO/zz-fake/history.jsonl"

step "schedulai digest"
"$BIN" digest

step "echo '{\"session_id\":\"t1\",\"hook_event_name\":\"SessionStart\"}' | schedulai digest --hook"
echo '{"session_id":"t1","hook_event_name":"SessionStart"}' | "$BIN" digest --hook
[[ -f $SCHEDULAI_DEMO/.digest/t1 ]] || fail "SessionStart wrote no mark"
echo "(mark: $(cat "$SCHEDULAI_DEMO/.digest/t1"))"

step "UserPromptSubmit t1, nothing new (expect no output)"
out="$(echo '{"session_id":"t1","hook_event_name":"UserPromptSubmit"}' | "$BIN" digest --hook)"
[[ -z $out ]] || fail "expected nothing, got: $out"
echo "(nothing)"

sleep 1
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '**FAKE RUN : 2 appels refusés**\nsuite\n' > "$SCHEDULAI_DEMO/zz-fake/logs/fake.log"
echo "{\"startedAt\":\"$now\",\"endedAt\":\"$now\",\"exitCode\":1,\"log\":\"fake.log\",\"denied\":2}" \
  >> "$SCHEDULAI_DEMO/zz-fake/history.jsonl"

step "UserPromptSubmit t1 after a fake failed run (expect it, once)"
out="$(echo '{"session_id":"t1","hook_event_name":"UserPromptSubmit"}' | "$BIN" digest --hook)"
echo "$out"
[[ $out == *"Nouveaux passages depuis ton dernier message"* ]] || fail "no header"
[[ $out == *"- zz-fake ("*") : FAKE RUN : 2 appels refusés"* ]] || fail "no verdict line"
[[ $out == *"! zz-fake "*": exit 1, 2 appel(s) refusé(s), log "*"/zz-fake/logs/fake.log"* ]] || fail "no failure line"
(( $(grep -c . <<< "$out") == 3 )) || fail "expected 3 lines (only the new run)"

step "UserPromptSubmit t1 again (expect no output)"
out="$(echo '{"session_id":"t1","hook_event_name":"UserPromptSubmit"}' | "$BIN" digest --hook)"
[[ -z $out ]] || fail "shown twice: $out"
echo "(nothing)"

step "UserPromptSubmit t2, a session with no mark (expect no output, a mark)"
out="$(echo '{"session_id":"t2","hook_event_name":"UserPromptSubmit"}' | "$BIN" digest --hook)"
[[ -z $out ]] || fail "expected nothing, got: $out"
[[ -f $SCHEDULAI_DEMO/.digest/t2 ]] || fail "no mark for t2"
echo "(nothing; mark $(cat "$SCHEDULAI_DEMO/.digest/t2"))"

step "a mark untouched for 15 days is pruned"
touch -t "$(date -v-15d +%Y%m%d%H%M)" "$SCHEDULAI_DEMO/.digest/t2"
echo '{"session_id":"t1","hook_event_name":"UserPromptSubmit"}' | "$BIN" digest --hook
[[ ! -e $SCHEDULAI_DEMO/.digest/t2 && -f $SCHEDULAI_DEMO/.digest/t1 ]] || fail "t2 not pruned (or t1 pruned)"
echo "(t2 gone, t1 kept)"

step "bad stdin, a session id with a slash: exit 0, nothing on stdout"
out="$(echo 'not json' | "$BIN" digest --hook 2>/dev/null)" || fail "non-zero exit on bad stdin"
[[ -z $out ]] || fail "printed on bad stdin"
out="$(echo '{"session_id":"../x","hook_event_name":"UserPromptSubmit"}' | "$BIN" digest --hook)" || fail "non-zero exit"
[[ -z $out && ! -e $SCHEDULAI_DEMO/x ]] || fail "unsafe session id used as a path"
echo "(ok)"

# Hooks, on a copy of the real settings.json (or a small sample).
export CLAUDE_CONFIG_DIR="$TMP/claude"
mkdir -p "$CLAUDE_CONFIG_DIR"
if [[ -f $HOME/.claude/settings.json ]]; then
  cp "$HOME/.claude/settings.json" "$CLAUDE_CONFIG_DIR/settings.json"
else
  printf '{\n  "model": "sonnet",\n  "hooks": {\n    "Stop": [\n      {\n        "hooks": [\n          {\n            "type": "command",\n            "command": "echo bye"\n          }\n        ]\n      }\n    ]\n  }\n}\n' \
    > "$CLAUDE_CONFIG_DIR/settings.json"
fi
cp "$CLAUDE_CONFIG_DIR/settings.json" "$TMP/settings.orig.json"
count() {
  python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
print(sum(1 for e in ("SessionStart","UserPromptSubmit") for g in d.get("hooks",{}).get(e,[]) for h in g.get("hooks",[])
          if h.get("command","").endswith(" digest --hook") and h.get("timeout")==5))' "$CLAUDE_CONFIG_DIR/settings.json"
}

step "schedulai hooks install"
"$BIN" hooks install
(( $(count) == 2 )) || fail "expected the 2 hook entries"
python3 - "$TMP/settings.orig.json" "$CLAUDE_CONFIG_DIR/settings.json" <<'EOF' || fail "something else changed"
import json, sys
a, b = (json.load(open(p)) for p in sys.argv[1:])
for d in (a, b):
    for e, groups in list(d.get("hooks", {}).items()):
        d["hooks"][e] = [g for g in groups if not any(h.get("command", "").endswith(" digest --hook") for h in g.get("hooks", []))]
        if not d["hooks"][e]: del d["hooks"][e]
assert a == b
EOF
cmp -s "$TMP/settings.orig.json" "$CLAUDE_CONFIG_DIR/settings.json.schedulai-backup" || fail "backup differs from the original"

step "schedulai hooks install (again: nothing changes)"
cp "$CLAUDE_CONFIG_DIR/settings.json" "$TMP/after-install.json"
"$BIN" hooks install
cmp -s "$TMP/after-install.json" "$CLAUDE_CONFIG_DIR/settings.json" || fail "second install changed the file"
(( $(count) == 2 )) || fail "duplicated entries"

step "schedulai hooks uninstall"
"$BIN" hooks uninstall
(( $(count) == 0 )) || fail "entries left"
python3 -c 'import json,sys; assert json.load(open(sys.argv[1])) == json.load(open(sys.argv[2]))' \
  "$TMP/settings.orig.json" "$CLAUDE_CONFIG_DIR/settings.json" || fail "uninstall did not restore the original content"
if cmp -s "$TMP/settings.orig.json" "$CLAUDE_CONFIG_DIR/settings.json"; then
  echo "(settings.json byte-identical to the original)"
else
  echo "(settings.json same content as the original; formatting differs:)"
  diff "$TMP/settings.orig.json" "$CLAUDE_CONFIG_DIR/settings.json" | head -20 || true
fi

echo
echo "verify-digest: all checks passed"
