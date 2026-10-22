# Schedulai

A macOS app that runs your Claude Code prompts on a schedule.

![Schedulai: the jobs, a report rendered from Markdown, the prompt editor](docs/demo.gif)

Each job is a Markdown file — a prompt plus a few lines saying when to run it and which tools
it may use. Schedulai hands it to `claude -p` through launchd, keeps every report, and shows
the state of each job in the Dock, the menu bar and its window. It also ships a Claude Code
skill, so you can ask a session to build the job for you: *"every Monday at 9, list my PRs
still waiting on a review"*.

Built with SwiftUI and AppKit for macOS 26 (Liquid Glass): a Swift package,
`scripts/build-app.sh`, an ad-hoc-signed bundle.

## A job is a folder

`~/.claude/scheduled/<id>/prompt.md`:

```markdown
---
name: Morning PR digest
description: Lists my open PRs waiting on a review
schedule: weekdays 08:00
workdir: ~/projects/my-app
allowedTools: "Bash(gh pr list:*),Bash(gh pr view:*)"
model: sonnet            # optional
---
The prompt given to `claude -p`. End it with the report you want to read.
```

- `schedule`: `08:00`, `daily 08:00`, `weekdays 08:00`, `mon,thu 09:30`, `08:00, 14:00`,
  `every 30m`, `every 2h` (French day names work too).
- `allowedTools` is the job's whole permission set: nobody is there to approve a prompt.

Each run writes `logs/<stamp>.log` (the report), `status.json`, a line of `history.jsonl`, and
posts a notification.

## The app

- **Window** — every job with its state, next run, success rate and last runs; the report
  rendered from Markdown (or raw); the prompt editable in place, name and description included.
- **Menu bar** — a clock with a sparkle (a dot when a run failed); its menu lists the jobs,
  runs or pauses them, and holds *Open at login*, *Language* and *Check for Updates…*.
- **Dock** — a badge counts the failed jobs; right-click for the same job menu.
- **Languages** — English and French; follows macOS until you pick one.
- **Updates** — the app checks this repository's latest release after launch and twice a
  day, verifies the download against its SHA-256 and installs it, waiting for any running job.

## From Claude Code

The `schedulai` skill (installed by the app into `~/.claude/skills/`) turns a description into
a job: it does the task once in the session, writes a self-contained prompt with exactly the
tools it used, test-runs it and switches it on. It drives the `schedulai` command, which goes
through the app's own code:

```
schedulai list | check <id> | run <id> | enable <id> | disable <id> | dir | version
```

## Install

From a release: download `Schedulai.zip` from
[Releases](https://github.com/cparis-ts/schedulai/releases), unzip into `/Applications`, open.
The app installs the skill, the `schedulai` command (`~/.local/bin`) and the job runner itself.

From source (Xcode 26):

```bash
scripts/install.sh   # build, copy to /Applications, open
```

## The animation above

It shows sample jobs, never your own: `SCHEDULAI_DEMO=<dir>` makes the app read its jobs from
`<dir>` and leave launchd alone, and `SCHEDULAI_TOUR=1` makes it walk through them on its own
while its window is captured frame by frame (`screencapture -l <window>`).

## Release

Push a tag: `git tag v0.3.0 && git push origin v0.3.0`. The *Release* workflow builds the app
stamped with that version and publishes `Schedulai.zip` and `Schedulai.zip.sha256`; installed
copies pick it up on their next check.

## License

MIT — see [LICENSE](LICENSE). Issues and pull requests are welcome.
