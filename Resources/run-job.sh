#!/bin/zsh
# Runs one Schedulai job: `claude -p` on <job dir>/prompt.md.
# Called by the job's LaunchAgent, or by the app's "Lancer maintenant".
# The app copies this file to ~/.claude/scheduled/.bin/run-job.sh at launch.
#
# Writes <job dir>/logs/<stamp>.log (the 30 latest are kept), <job dir>/status.json
# (read by the app), <job dir>/history.jsonl (one line per run) and <job dir>/.running (the runner's pid, while it runs).
set -u
JOB_DIR="${1:?usage: run-job.sh <job dir>}"
PROMPT_FILE="$JOB_DIR/prompt.md"
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

# One frontmatter value (`key: value` between the two leading `---` lines).
meta() {
  awk -v key="$1" '
    NR == 1 { if ($0 == "---") { inside = 1; next } else exit }
    inside && $0 == "---" { exit }
    inside {
      i = index($0, ":"); k = substr($0, 1, i - 1); gsub(/^[ \t]+|[ \t]+$/, "", k)
      if (k == key) {
        v = substr($0, i + 1); gsub(/^[ \t]+|[ \t]+$/, "", v)
        if (v ~ /^".*"$/) v = substr(v, 2, length(v) - 2)
        print v; exit
      }
    }' "$PROMPT_FILE"
}
# The prompt: everything after the frontmatter.
body() {
  awk 'NR == 1 && $0 == "---" { state = 1; next }
       state == 1 && $0 == "---" { state = 2; next }
       state != 1 { print }' "$PROMPT_FILE"
}

mkdir -p "$JOB_DIR/logs"
LOCK="$JOB_DIR/.running"
if [[ -f $LOCK ]] && kill -0 "$(cat "$LOCK")" 2>/dev/null; then
  echo "already running (pid $(cat "$LOCK"))" >&2
  exit 0
fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK"' EXIT

NAME="$(meta name)"; NAME="${NAME:-${JOB_DIR:t}}"
WORKDIR="$(meta workdir)"; WORKDIR="${WORKDIR/#\~/$HOME}"; WORKDIR="${WORKDIR:-$HOME}"
TOOLS="$(meta allowedTools)"
MODEL="$(meta model)"
LOG="$JOB_DIR/logs/$(date +%Y-%m-%d_%H%M%S).log"
STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

write_status() {
  printf '{"startedAt":"%s","endedAt":%s,"exitCode":%s,"log":"%s"}\n' \
    "$STARTED" "$1" "$2" "${LOG:t}" > "$JOB_DIR/status.json"
}
write_status null null

args=(-p "$(body)")
[[ -n $TOOLS ]] && args+=(--allowedTools "$TOOLS")
[[ -n $MODEL ]] && args+=(--model "$MODEL")
{ cd "$WORKDIR" && claude "${args[@]}" } > "$LOG" 2>&1 < /dev/null
rc=$?
write_status "\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"" $rc
# One line per run, the 50 latest kept: the app's run history.
cat "$JOB_DIR/status.json" >> "$JOB_DIR/history.jsonl"
tail -n 50 "$JOB_DIR/history.jsonl" > "$JOB_DIR/history.tmp" && mv "$JOB_DIR/history.tmp" "$JOB_DIR/history.jsonl"

old_logs=("$JOB_DIR"/logs/*.log(Nom))
(( ${#old_logs} > 30 )) && rm -f "${(@)old_logs[31,-1]}"

summary="$(tail -c 180 "$LOG" | tr '\n"\\' '   ')"
# The app's language (Schedulai › Language), else macOS's first language.
lang="$(defaults read com.charlesparis.schedulai appLanguage 2>/dev/null)"
if [[ -z $lang || $lang == system ]]; then
  lang="$(defaults read -g AppleLanguages 2>/dev/null | sed -n 2p | tr -dc 'a-z' | cut -c1-2)"
fi
result="OK"
if (( rc != 0 )); then
  [[ $lang == fr ]] && result="échec ($rc)" || result="failed ($rc)"
fi
osascript -e "display notification \"$summary\" with title \"${NAME//\"/} — $result\"" >/dev/null 2>&1
exit $rc
