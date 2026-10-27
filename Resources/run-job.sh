#!/bin/zsh
# Runs one Schedulai job: <job dir>/prompt.md given to its agent's headless
# mode (`agent:` claude, codex or gemini; claude when absent).
# Called by the job's LaunchAgent, or by the app's "Lancer maintenant".
# The app copies this file to ~/.claude/scheduled/.bin/run-job.sh at launch.
#
# Writes <job dir>/logs/<stamp>.log (the 30 latest are kept), <job dir>/status.json
# (read by the app), <job dir>/history.jsonl (one line per run) and <job dir>/.running (the runner's pid, while it runs).
#
# `run-job.sh --which claude codex …` prints each command's path as a run would
# find it (an empty path: not found); the app reads it to show what is installed.
set -u
# launchd starts us with a bare PATH: add the usual install places, then the
# PATH a fresh login shell sets up (Homebrew, npm… from ~/.zprofile), from a
# clean environment so the app and launchd resolve the same commands.
login_path="$(/usr/bin/env -i HOME="$HOME" USER="${USER:-}" /bin/zsh -lc 'print -r -- $PATH' 2>/dev/null < /dev/null)"
export PATH="$HOME/.local/bin:$HOME/.claude/local:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin${login_path:+:$login_path}"

if [[ ${1:-} == --which ]]; then
  shift
  for cmd in "$@"; do printf '%s\t%s\n' "$cmd" "$(whence -p "$cmd")"; done
  exit 0
fi

JOB_DIR="${1:?usage: run-job.sh <job dir>}"
PROMPT_FILE="$JOB_DIR/prompt.md"

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
AGENT="$(meta agent)"; AGENT="${${AGENT:-claude}:l}"
TOOLS="$(meta allowedTools)"
MODEL="$(meta model)"
LOG="$JOB_DIR/logs/$(date +%Y-%m-%d_%H%M%S).log"
STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

write_status() {
  printf '{"startedAt":"%s","endedAt":%s,"exitCode":%s,"log":"%s"}\n' \
    "$STARTED" "$1" "$2" "${LOG:t}" > "$JOB_DIR/status.json"
}
write_status null null

# The agent's headless command line. The log is the agent's final answer,
# whichever agent ran: that is what the app shows and the notification quotes.
PROMPT="$(body)"
REPORT=""
case $AGENT in
  claude)
    cmd=(claude -p "$PROMPT")
    [[ -n $TOOLS ]] && cmd+=(--allowedTools "$TOOLS")
    # `bypassPermissions` approves every call (claude --dangerously-skip-permissions).
    PERMISSION_MODE="$(meta permissionMode)"
    [[ -n $PERMISSION_MODE ]] && cmd+=(--permission-mode "$PERMISSION_MODE")
    [[ -n $MODEL ]] && cmd+=(--model "$MODEL")
    ;;
  codex)
    # Permissions are a sandbox, not a tool list: read-only unless the job
    # says otherwise. `network: true` opens the network to workspace-write.
    SANDBOX="$(meta sandbox)"
    REPORT="$LOG.answer"
    cmd=(codex exec --skip-git-repo-check -s "${SANDBOX:-read-only}" -o "$REPORT")
    [[ $(meta network) == true ]] && cmd+=(-c sandbox_workspace_write.network_access=true)
    [[ -n $MODEL ]] && cmd+=(-m "$MODEL")
    cmd+=("$PROMPT")
    ;;
  gemini)
    # Headless, a call needing approval is refused: `approval: default` lets
    # only `allowedTools` through. --allowed-tools is deprecated upstream in
    # favour of policy files, and still honoured.
    APPROVAL="$(meta approval)"
    cmd=(gemini -p "$PROMPT" --approval-mode "${APPROVAL:-default}")
    [[ -n $TOOLS ]] && cmd+=(--allowed-tools "$TOOLS")
    [[ -n $MODEL ]] && cmd+=(-m "$MODEL")
    ;;
  *)
    cmd=()
    ;;
esac

if (( ${#cmd} == 0 )); then
  print -r -- "SchedulAI: unknown agent \"$AGENT\" in prompt.md — write claude, codex or gemini." > "$LOG"
  rc=2
elif ! whence -p "${cmd[1]}" > /dev/null; then
  print -r -- "SchedulAI: \`${cmd[1]}\` is not installed. Install it, or set another \`agent:\` in prompt.md." > "$LOG"
  rc=127
else
  { cd "$WORKDIR" && "${cmd[@]}" } > "$LOG" 2>&1 < /dev/null
  rc=$?
  # Codex prints its whole session; its last message is the report. The
  # session stays the log when there is no answer (a failed run).
  if [[ -n $REPORT ]]; then
    if [[ -s $REPORT ]]; then mv -f "$REPORT" "$LOG"; else rm -f "$REPORT"; fi
  fi
fi
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
