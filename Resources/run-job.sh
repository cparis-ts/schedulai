#!/bin/zsh
# Runs one Schedulai job: <job dir>/prompt.md given to its agent's headless
# mode (`agent:` claude, codex or gemini; claude when absent).
# Called by the job's LaunchAgent, or by the app's "Lancer maintenant".
# The app copies this file to ~/.claude/scheduled/.bin/run-job.sh at launch.
#
# Writes <job dir>/logs/<stamp>.log (the 30 latest are kept), <job dir>/status.json
# (read by the app), <job dir>/history.jsonl (one line per run, the 500 latest)
# and <job dir>/.running (the runner's pid, while it runs). Each run commits the
# prompt.md it ran into ~/.claude/scheduled/.git, so a run names its prompt version.
#
# Beyond the agent's own keys, the frontmatter may set:
#   timeout: 45m       stop the run after that long (s, m or h; minutes when bare)
#   budget: 5          skip the run once Claude runs cost $5 over the last 24 hours
#   notify: changes    always (default) · failure · changes · never
#   webhook: <url>     POSTs {"text": …} (Slack's format) whenever a notification goes out
#   after: <id>        also run when that job succeeds (the runner starts it)
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

JOB_DIR="${${1:?usage: run-job.sh <job dir>}:A}"
RUNNER="${0:A}"
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
  # A start from `after:` while it runs is dropped, its marker with it.
  rm -f "$JOB_DIR/.trigger"
  exit 0
fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK"' EXIT

ROOT="${JOB_DIR:A:h}"
ID="${JOB_DIR:t}"
NAME="$(meta name)"; NAME="${NAME:-$ID}"
WORKDIR="$(meta workdir)"; WORKDIR="${WORKDIR/#\~/$HOME}"; WORKDIR="${WORKDIR:-$HOME}"
AGENT="$(meta agent)"; AGENT="${${AGENT:-claude}:l}"
TOOLS="$(meta allowedTools)"
MODEL="$(meta model)"
NOTIFY="$(meta notify)"; NOTIFY="${NOTIFY:-always}"
WEBHOOK="$(meta webhook)"
LOG="$JOB_DIR/logs/$(date +%Y-%m-%d_%H%M%S).log"
STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# The jobs that led here, when another job's success started this one (`after:`).
CHAIN=""
if [[ -f $JOB_DIR/.trigger ]]; then CHAIN="$(cat "$JOB_DIR/.trigger")"; rm -f "$JOB_DIR/.trigger"; fi

# What the app reads of a run; empty values are left out.
COST="" SESSION_ID="" TOKENS_IN="" TOKENS_OUT="" DENIED="" SKIPPED="" TIMED_OUT="" PROMPT_REV=""
write_status() {
  jq -nc --arg startedAt "$STARTED" --arg endedAt "$1" --arg exitCode "$2" --arg log "${LOG:t}" \
    --arg promptRev "$PROMPT_REV" --arg sessionId "$SESSION_ID" --arg costUSD "$COST" \
    --arg inputTokens "$TOKENS_IN" --arg outputTokens "$TOKENS_OUT" --arg denied "$DENIED" \
    --arg skipped "$SKIPPED" --arg timedOut "$TIMED_OUT" --arg after "${CHAIN##*>}" '
    {startedAt: $startedAt, endedAt: $endedAt, exitCode: ($exitCode | tonumber? // null), log: $log,
     promptRev: $promptRev, sessionId: $sessionId, costUSD: ($costUSD | tonumber? // null),
     inputTokens: ($inputTokens | tonumber? // null), outputTokens: ($outputTokens | tonumber? // null),
     denied: ($denied | tonumber? // null), skipped: $skipped, timedOut: ($timedOut == "1"), after: $after}
    | with_entries(select(.value != null and .value != "" and .value != false))' > "$JOB_DIR/status.json"
}

# The prompt's versions: ~/.claude/scheduled is a git repository of the
# prompt.md files alone (the app commits its own edits there too). Needs the
# Command Line Tools; without them, /usr/bin/git would open an install dialog.
version_prompt() {
  /usr/bin/xcode-select -p > /dev/null 2>&1 || return 0
  local git=(git -C "$ROOT" -c user.name=SchedulAI -c user.email=schedulai@localhost -c commit.gpgsign=false)
  if [[ ! -d $ROOT/.git ]]; then
    "${git[@]}" init -q || return 0
    printf '%s\n' '*' '!*/' '!*/prompt.md' '!.gitignore' > "$ROOT/.gitignore"
    "${git[@]}" add .gitignore
  fi
  local message="edited outside SchedulAI"
  [[ -n $("${git[@]}" ls-files -- "$ID/prompt.md" 2> /dev/null) ]] || message="first version"
  "${git[@]}" add -A -- "$ID/prompt.md" 2> /dev/null
  "${git[@]}" diff --cached --quiet -- "$ID/prompt.md" 2> /dev/null ||
    "${git[@]}" commit -q -m "$ID: $message" -- "$ID/prompt.md" .gitignore > /dev/null 2>&1
  PROMPT_REV="$("${git[@]}" log -1 --format=%h -- "$ID/prompt.md" 2> /dev/null)"
}
version_prompt

# Seconds, from `timeout:` — 90s, 45m, 2h, or bare minutes.
TIMEOUT="$(meta timeout)"
TIMEOUT_S=""
case $TIMEOUT in
  <->s) TIMEOUT_S=${TIMEOUT%s} ;;
  <->m) TIMEOUT_S=$(( ${TIMEOUT%m} * 60 )) ;;
  <->h) TIMEOUT_S=$(( ${TIMEOUT%h} * 3600 )) ;;
  <->) TIMEOUT_S=$(( TIMEOUT * 60 )) ;;
esac

# `budget:` — dollars over the last 24 hours, from the costs Claude reported.
BUDGET="$(meta budget)"; BUDGET="${BUDGET//[^0-9.]/}"
SPENT=0
if [[ -n $BUDGET && -f $JOB_DIR/history.jsonl ]]; then
  since="$(date -u -v-24H +%Y-%m-%dT%H:%M:%SZ)"
  SPENT="$(jq -rs --arg since "$since" '[.[] | select(.startedAt >= $since) | .costUSD // 0] | add // 0' "$JOB_DIR/history.jsonl" 2> /dev/null)"
fi

write_status "" ""

# The agent's headless command line. The log is the agent's final answer,
# whichever agent ran: that is what the app shows and the notification quotes.
PROMPT="$(body)"
REPORT=""
JSON=""
# `args:` — options of the job's own, appended to the agent's command line as
# written (shell words, quotes honoured): e.g. --dangerously-skip-permissions.
ARGS="$(meta args)"
extra=()
[[ -n $ARGS ]] && extra=("${(Q@)${(z)ARGS}}")
extra=("${extra[@]/#\~/$HOME}")
case $AGENT in
  claude)
    # JSON: the answer plus what the run cost, its session (to resume it) and
    # the calls its permissions refused.
    JSON="$LOG.json"
    cmd=(claude -p "$PROMPT" --output-format json)
    [[ -n $TOOLS ]] && cmd+=(--allowedTools "$TOOLS")
    # `bypassPermissions` approves every call (claude --dangerously-skip-permissions).
    PERMISSION_MODE="$(meta permissionMode)"
    [[ -n $PERMISSION_MODE ]] && cmd+=(--permission-mode "$PERMISSION_MODE")
    [[ -n $MODEL ]] && cmd+=(--model "$MODEL")
    cmd+=("${extra[@]}")
    ;;
  codex)
    # Permissions are a sandbox, not a tool list: read-only unless the job
    # says otherwise. `network: true` opens the network to workspace-write.
    SANDBOX="$(meta sandbox)"
    REPORT="$LOG.answer"
    cmd=(codex exec --skip-git-repo-check -s "${SANDBOX:-read-only}" -o "$REPORT")
    [[ $(meta network) == true ]] && cmd+=(-c sandbox_workspace_write.network_access=true)
    [[ -n $MODEL ]] && cmd+=(-m "$MODEL")
    cmd+=("${extra[@]}" "$PROMPT")
    ;;
  gemini)
    # Headless, a call needing approval is refused: `approval: default` lets
    # only `allowedTools` through. --allowed-tools is deprecated upstream in
    # favour of policy files, and still honoured.
    APPROVAL="$(meta approval)"
    cmd=(gemini -p "$PROMPT" --approval-mode "${APPROVAL:-default}")
    [[ -n $TOOLS ]] && cmd+=(--allowed-tools "$TOOLS")
    [[ -n $MODEL ]] && cmd+=(-m "$MODEL")
    cmd+=("${extra[@]}")
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
elif [[ -n $BUDGET ]] && (( SPENT >= BUDGET )); then
  SKIPPED=budget
  printf 'SchedulAI: skipped — this job spent $%.2f over the last 24 hours, its budget is $%s.\n' "$SPENT" "$BUDGET" > "$LOG"
  rc=0
elif ! cd "$WORKDIR" 2> /dev/null; then
  print -r -- "SchedulAI: workdir \`$WORKDIR\` is not a directory." > "$LOG"
  rc=1
else
  # In the background so `timeout:` can stop it; the agent stays the
  # runner's own child, which the app's Stop button signals.
  "${cmd[@]}" > "${JSON:-$LOG}" 2> "$LOG.err" < /dev/null &
  agent_pid=$!
  watchdog=""
  if [[ -n $TIMEOUT_S ]]; then
    ( sleep $TIMEOUT_S && touch "$LOG.timeout" && pkill -TERM -P $agent_pid; kill -TERM $agent_pid ) 2> /dev/null &
    watchdog=$!
  fi
  wait $agent_pid
  rc=$?
  [[ -n $watchdog ]] && kill $watchdog 2> /dev/null

  if [[ -n $JSON ]]; then
    if jq -e 'has("result") or has("subtype")' "$JSON" > /dev/null 2>&1; then
      jq -r '.result // ""' "$JSON" > "$LOG"
      COST="$(jq -r '.total_cost_usd // empty' "$JSON")"
      SESSION_ID="$(jq -r '.session_id // empty' "$JSON")"
      TOKENS_IN="$(jq -r '.usage | ((.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0))' "$JSON")"
      TOKENS_OUT="$(jq -r '.usage.output_tokens // empty' "$JSON")"
      DENIED="$(jq -r '.permission_denials // [] | length' "$JSON")"
      if (( ${DENIED:-0} > 0 )); then
        {
          print -r -- ""
          print -r -- "---"
          print -r -- "SchedulAI: $DENIED call(s) refused by this job's permissions:"
          jq -r '.permission_denials[] | "- \(.tool_name): \(.tool_input | tostring | .[0:200])"' "$JSON"
        } >> "$LOG"
      fi
      if [[ $(jq -r '.is_error // false' "$JSON") == true ]] && (( rc == 0 )); then rc=1; fi
      rm -f "$JSON"
    else
      # No JSON (a crash, a kill): whatever it printed is the log.
      mv -f "$JSON" "$LOG"
    fi
  fi
  # Codex prints its whole session; its last message is the report. The
  # session stays the log when there is no answer (a failed run).
  if [[ -n $REPORT ]]; then
    if [[ -s $REPORT ]]; then mv -f "$REPORT" "$LOG"; else rm -f "$REPORT"; fi
  fi
  # stderr joins the log when the run failed, or when it was all there was.
  if [[ -s $LOG.err ]] && (( rc != 0 )) || [[ ! -s $LOG ]]; then cat "$LOG.err" >> "$LOG"; fi
  rm -f "$LOG.err"
  if [[ -f $LOG.timeout ]]; then
    rm -f "$LOG.timeout"
    TIMED_OUT=1
    rc=124
    print -r -- $'\n'"SchedulAI: stopped after $TIMEOUT (timeout:)." >> "$LOG"
  fi
fi
write_status "$(date -u +%Y-%m-%dT%H:%M:%SZ)" $rc
# One line per run, the 500 latest kept: the app's run history and costs.
cat "$JOB_DIR/status.json" >> "$JOB_DIR/history.jsonl"
tail -n 500 "$JOB_DIR/history.jsonl" > "$JOB_DIR/history.tmp" && mv "$JOB_DIR/history.tmp" "$JOB_DIR/history.jsonl"

old_logs=("$JOB_DIR"/logs/*.log(Nom))
previous="${old_logs[2]:-}"
(( ${#old_logs} > 30 )) && rm -f "${(@)old_logs[31,-1]}"

# `after:` — a success starts the jobs that wait for this one, through launchd
# when they are active. CHAIN keeps the path here, so a loop stops at its start.
if (( rc == 0 )) && [[ -z $SKIPPED ]]; then
  for next in "$ROOT"/*/prompt.md(N); do
    next_dir="${next:h}"
    [[ $next_dir == ${JOB_DIR:A} ]] && continue
    after="$(PROMPT_FILE="$next" meta after)"
    [[ ",${after// /}," == *",$ID,"* ]] || continue
    [[ ">$CHAIN>$ID>" == *">${next_dir:t}>"* ]] && continue
    label="com.charlesparis.schedulai.${next_dir:t}"
    if [[ -f $HOME/Library/LaunchAgents/$label.plist ]]; then
      print -r -- "${CHAIN:+$CHAIN>}$ID" > "$next_dir/.trigger"
      launchctl kickstart "gui/$(id -u)/$label" > /dev/null 2>&1
    elif [[ -f $ROOT/.agents/$label.plist ]]; then
      # Demo mode (SCHEDULAI_DEMO): no launchd.
      print -r -- "${CHAIN:+$CHAIN>}$ID" > "$next_dir/.trigger"
      /bin/zsh "$RUNNER" "$next_dir" > /dev/null 2>&1 &!
    fi
  done
fi

# `notify:` — always, failure, changes (a failure, or a report that differs
# from the previous one and does not start with NOTHING), never.
wanted=1
case $NOTIFY in
  never) wanted=0 ;;
  failure) (( rc != 0 )) || wanted=0 ;;
  changes)
    if (( rc == 0 )); then
      first="$(grep -m1 -v '^[[:space:]]*$' "$LOG" | tr -d '*#_ ')"
      if [[ $first == NOTHING* ]] || { [[ -n $previous ]] && cmp -s "$LOG" "$previous"; }; then wanted=0; fi
    fi
    ;;
esac
(( wanted )) || exit $rc

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
[[ -n $SKIPPED ]] && { [[ $lang == fr ]] && result="sauté (budget)" || result="skipped (budget)"; }
osascript -e "display notification \"$summary\" with title \"${NAME//\"/} — $result\"" >/dev/null 2>&1
if [[ $WEBHOOK == https://* || $WEBHOOK == http://* ]]; then
  jq -n --arg text "*$NAME — $result*"$'\n'"$(head -c 3000 "$LOG")" '{text: $text}' |
    curl -s -m 15 -H 'Content-Type: application/json' -d @- "$WEBHOOK" > /dev/null 2>&1
fi
exit $rc
