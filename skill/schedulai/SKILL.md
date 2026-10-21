---
name: schedulai
description: Set up a recurring Claude task (a "cron") in the Schedulai app — from a plain-language description, write the job's prompt.md, its allowed tools and schedule, test-run it, and activate it. Use when the user asks to do something "every morning", "each Monday", "tous les jours à 8h", to "automate", "schedule", "mettre un cron", or to change, test, pause or remove an existing cron.
---

# schedulai — turn a described task into a scheduled Claude job

The user describes a task and when it should happen; you build the job and switch
it on. The job then runs **headless** (`claude -p`, nobody at the keyboard, no
memory of this conversation) under launchd, and shows up in the Schedulai app
(Dock + menu bar).

## The pieces

- A job = `~/.claude/scheduled/<id>/prompt.md` (`schedulai dir` prints the root):

  ```markdown
  ---
  name: Morning PR digest
  description: Lists my open PRs waiting on a review
  schedule: weekdays 08:00
  workdir: ~/projects/my-app
  allowedTools: "Bash(gh pr list:*),Bash(gh pr view:*)"
  model: sonnet
  ---
  The prompt.
  ```

  `name` and `description` are what the app shows (write the description as one
sentence the user will recognise in a list). `schedule`: `08:00`, `daily 08:00`, `weekdays 08:00`, `mon,thu 09:30` (French day
  names work too), `08:00, 14:00`, `every 30m`, `every 2h`. `model` is optional.
- The `schedulai` command (in `~/.local/bin`) — always use it rather than writing
  a plist yourself; it runs the app's own code:
  `list` · `check <id>` · `run <id>` (foreground, prints the log, exits with its
  code) · `enable <id>` · `disable <id>` · `dir`.
- Each run writes `<id>/logs/<stamp>.log` (the final answer of `claude -p`),
  `status.json`, and posts a macOS notification with the end of that answer.

## Workflow

### 1. Pin down the task — ask only what you cannot infer

You need: **what** to do, **when**, **on what scope** (whose cards, which repos),
**what it may change** (read-only report vs. moving cards, commenting, opening
PRs…), and **what the report should say**. Infer what the conversation and the
user's memory already answer; ask the rest in ONE AskUserQuestion. Writes are
the question worth asking: a job that mutates shared state needs an explicit yes.

### 2. Do it once, here, before writing anything

The best specification is a run that worked. Perform the task (or its read-only
half) in this session and note **the exact tool names you called**, the IDs,
URLs and commands that worked, and the traps you hit. A tool that needs
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

### 4. Allow exactly the tools of step 2

`allowedTools` is the job's whole permission set — nothing else is approved, and
a denied call is skipped, not asked.

- MCP tools by full name: `mcp__<server>__<tool>`; plugin servers look like
  `mcp__plugin_<plugin>_<server>__<tool>`.
- Bash by command prefix: `Bash(gh pr list:*)`, `Bash(git fetch:*)`. Never bare
  `Bash` or `Bash(*)`.
- `Edit`/`Write` only if the job's purpose is to write files.
- Check the MCP servers it needs are reachable from `workdir`:
  `cd <workdir> && claude mcp list`.

### 5. Create, check, test

```bash
id=<kebab-case-id>                       # never overwrite an existing job without asking
mkdir -p "$(schedulai dir)/$id"        # then write prompt.md with the Write tool
schedulai check "$id"                  # exit 1 = fix what it prints
schedulai run "$id"                    # real run: run it in the background, it takes minutes
```

**The test run is real.** If the job writes, tell the user what it is about to
do and get their go first — or test a copy whose prompt says "report what you
would do, change nothing", then switch the real one on.

Read the log. A tool missing from `allowedTools` shows up as Claude saying it was
not allowed or lacked permission: add it, run again. A wrong report means a wrong
prompt: fix the prompt, not the log.

### 6. Switch it on and say so

```bash
schedulai enable "$id"                 # prints the next run
```

Tell the user, in French: the job's name, when it runs (and the next run), what
it may change, where the logs are, and that the app (Dock / menu bar) shows its
state and lets them pause it.

## Changing an existing job

`schedulai list`, edit its `prompt.md`, `schedulai check <id>`, then
`schedulai enable <id>` again so a new `schedule:` reaches launchd (the app
also picks it up within seconds while it is open). Pause with `disable`; delete
by `disable` then removing the folder — after asking.
