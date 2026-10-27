---
name: schedulai
description: Set up a recurring AI task (a "cron") in the SchedulAI app, run by Claude Code, Codex or Gemini CLI — from a plain-language description, write the job's prompt.md, its allowed tools and schedule, test-run it, and activate it. Use when the user asks to do something "every morning", "each Monday", "tous les jours à 8h", to "automate", "schedule", "mettre un cron", or to change, test, pause or remove an existing cron.
---

# schedulai — turn a described task into a scheduled AI job

The user describes a task and when it should happen; you build the job and switch
it on. The job then runs **headless** (nobody at the keyboard, no memory of this
conversation) under launchd, and shows up in the SchedulAI app (Dock + menu bar).

This skill is read by Claude Code, Codex and Gemini CLI alike. **Schedule the job
on the agent you are** — the same one that does step 2 here — unless the user
asks for another: set `agent:` accordingly (`claude` is the default when absent).

| You are | `agent:` | Headless run | Permission keys |
|---|---|---|---|
| Claude Code | `claude` (or omit) | `claude -p` | `allowedTools`, `permissionMode` |
| Codex | `codex` | `codex exec` | `sandbox`, `network` |
| Gemini CLI | `gemini` | `gemini -p` | `allowedTools`, `approval` |

## The pieces

- A job = `~/.claude/scheduled/<id>/prompt.md` (`schedulai dir` prints the root):

  ```markdown
  ---
  name: Morning PR digest
  description: Lists my open PRs waiting on a review
  schedule: weekdays 08:00
  workdir: ~/projects/my-app
  agent: claude
  allowedTools: "Bash(gh pr list:*),Bash(gh pr view:*)"
  model: sonnet
  ---
  The prompt.
  ```

  `name` and `description` are what the app shows (write the description as one
sentence the user will recognise in a list). `schedule`: `08:00`, `daily 08:00`, `weekdays 08:00`, `mon,thu 09:30` (French day
  names work too), `08:00, 14:00`, `every 30m`, `every 2h`. `model` is optional
  and is passed as is to the agent.
- The `schedulai` command (in `~/.local/bin`) — always use it rather than writing
  a plist yourself; it runs the app's own code:
  `list` · `check <id>` · `run <id>` (foreground, prints the log, exits with its
  code) · `enable <id>` · `disable <id>` · `dir`.
- Each run writes `<id>/logs/<stamp>.log` (the agent's final answer),
  `status.json`, and posts a macOS notification with the end of that answer.

## Workflow

### 1. Pin down the task — ask only what you cannot infer

You need: **what** to do, **when**, **on what scope** (whose cards, which repos),
**what it may change** (read-only report vs. moving cards, commenting, opening
PRs…), and **what the report should say**. Infer what the conversation and the
user's memory already answer; ask the rest in ONE question (AskUserQuestion in Claude Code). Writes are
the question worth asking: a job that mutates shared state needs an explicit yes.

### 2. Do it once, here, before writing anything

The best specification is a run that worked. Perform the task (or its read-only
half) in this session and note **the exact tool names you called**, the IDs,
URLs and commands that worked, and the traps you hit. In Claude Code, a tool that needs
`ToolSearch` here is still called by its full name headless.

### 3. Write the prompt for a reader with no context

The headless run knows nothing of this conversation. The prompt must carry:

- every ID, URL, board/section/repo name and command it needs, literally;
- the exact tools to use and in what order;
- the **decision rule** for each write, and the default when in doubt: *do
  nothing and say why*. A cron that guesses fails silently at 8 a.m.;
- idempotence: running twice must not do the work twice;
- what it must never touch;
- the end: **a short report in French, verdict on the first line** — that line
  is what the notification shows.

Write it in English or French, as the user prefers; keep it under a page.

### 4. Allow exactly what step 2 needed

The permission keys are the job's whole permission set — nothing else is
approved, and a refused call is skipped, not asked. Grant the least that works.

**Claude Code** — `allowedTools`, a comma-separated list:

- MCP tools by full name: `mcp__<server>__<tool>`; plugin servers look like
  `mcp__plugin_<plugin>_<server>__<tool>`.
- Bash by command prefix: `Bash(gh pr list:*)`, `Bash(git fetch:*)`. Never bare
  `Bash` or `Bash(*)`.
- `Edit`/`Write` only if the job's purpose is to write files.
- Check the MCP servers it needs are reachable from `workdir`:
  `cd <workdir> && claude mcp list`.

- `permissionMode: bypassPermissions` approves every call, `allowedTools` or
  not (what `claude --dangerously-skip-permissions` does) — only with the
  user's explicit yes, and say so when you switch the job on. `acceptEdits`
  also approves file edits.

- No guardrails for any agent, once the user said yes: `schedulai bypass <id> on`
  (`off` to go back) — the app's *No guardrails* switch does the same.
- Any agent: `args:` appends options to its command line as written
  (`args: --dangerously-skip-permissions`, `args: --add-dir ~/other-repo`) — for
  an option SchedulAI has no key for. Same rule: one that widens permissions
  needs the user's explicit yes.

**Codex** — a sandbox, not a tool list:

- `sandbox: read-only` (the default): reads files and runs read-only commands.
- `sandbox: workspace-write`: may also write inside `workdir`. Add
  `network: true` only when a command must reach the network (`gh`, `curl`…).
- `sandbox: danger-full-access`: no sandbox at all. Only with the user's explicit
  yes, and say so when you switch the job on.

**Gemini CLI** — `approval` plus `allowedTools`:

- `approval: default` (the default): headless, every call needing approval is
  refused, except the tools in `allowedTools`, e.g.
  `"run_shell_command(gh pr list),run_shell_command(gh pr view)"`.
- `auto_edit` also approves file edits; `yolo` approves everything — only with
  the user's explicit yes.

### 5. Create, check, test

```bash
id=<kebab-case-id>                       # never overwrite an existing job without asking
mkdir -p "$(schedulai dir)/$id"        # then write prompt.md
schedulai check "$id"                  # exit 1 = fix what it prints
schedulai run "$id"                    # real run: run it in the background, it takes minutes
```

**The test run is real.** If the job writes, tell the user what it is about to
do and get their go first — or test a copy whose prompt says "report what you
would do, change nothing", then switch the real one on.

Read the log. A missing permission shows up as the agent saying a call was not
allowed, was denied or was blocked by the sandbox: widen the permission keys by
the least that fixes it, run again. `schedulai check` says when the agent's
command is not installed where the scheduled run looks for it. A wrong report means a wrong
prompt: fix the prompt, not the log.

### 6. Switch it on and say so

```bash
schedulai enable "$id"                 # prints the next run
```

Tell the user, in French: the job's name, when it runs (and the next run), what
it may change, where the logs are, and that the app (Dock / menu bar) shows its
state and lets them pause it.

## Changing an existing job

When the user says a job did the wrong thing, start from what it actually did:
`schedulai brief <id>` prints its schedule, permissions, last runs, latest
reports and prompt — read it before proposing a change, then reproduce the
step that went wrong. (In the app, *Challenge with AI* opens a session with that
brief as its first message.)

`schedulai list`, edit its `prompt.md`, `schedulai check <id>`, then
`schedulai enable <id>` again so a new `schedule:` reaches launchd (the app
also picks it up within seconds while it is open). Pause with `disable`; delete
with `schedulai delete <id>` (unschedules it, folder to the Trash) — after asking.
