#!/bin/bash
# Build, install into /Applications (replacing a previous copy), link the
# `schedulai` command, install the schedulai skill, and open the app.
# Also removes what the app was called before (Claude Crons): its app, command
# and skill. Its jobs keep running: Schedulai renames their LaunchAgents.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$("$ROOT/scripts/build-app.sh" | tail -1)"

for old in "Claude Crons" "Schedulai"; do
  osascript -e "tell application \"$old\" to quit" >/dev/null 2>&1 || true
done
rm -rf "/Applications/Claude Crons.app" "$HOME/.local/bin/claude-crons" "$HOME/.claude/skills/claude-cron"

rm -rf "/Applications/Schedulai.app"
/usr/bin/ditto "$APP" "/Applications/Schedulai.app"
mkdir -p "$HOME/.local/bin" "$HOME/.claude/skills"
ln -sf "/Applications/Schedulai.app/Contents/MacOS/Schedulai" "$HOME/.local/bin/schedulai"
rm -rf "$HOME/.claude/skills/schedulai"
cp -R "$ROOT/skill/schedulai" "$HOME/.claude/skills/schedulai"

open "/Applications/Schedulai.app"
echo "Installed /Applications/Schedulai.app"
