# Gotchas (read when a run misbehaves)

Moved out of SKILL.md so Claude doesn't re-read them on every dispatch.

## Safety layers and their limits
- Three layers in `exec`: `--deny` prefix rules, the `grok-guard.ps1` PreToolUse hook (whole-command
  check: catches `git -C x commit`, `cd x && git push`, `bash -c "..."`, `& git.exe commit`), and
  your review. The hook file is `~/.grok/hooks/claude-grok-skill.json`; `grok-exec.ps1` (re)writes it
  on every run and the guard only acts when `CLAUDE_GROK_GUARD` is set, so interactive grok is untouched
  (apart from ~0.3 s PowerShell startup per shell/edit call).
- Grok hooks **fail open**: if the guard can't start or times out, the call is allowed. That's why
  the prefix `--deny` list stays. The guard itself fails closed on internal errors.
- Not covered: user-defined git aliases (`git ci` → commit), scripts Grok writes and then runs
  (`python x.py` that deletes things), `python -c "shutil.rmtree(...)"`. Still check `git log` /
  `git status` after each run.
- Guard false positive (e.g. `echo "a; rm -rf b"` is split at `;`)? Grok gets a reason and moves on.
  Test a command offline: `.\grok-guard.ps1 -Command '<cmd>' [-Level plan]`; run `tests\test-guard.ps1`
  after changing the guard.
- MCP tools are denied unless `-AllowMcp` (Railway/Vercel/Supabase MCP servers can deploy).
- Real OS sandboxing (`grok --sandbox`) only works on macOS/Linux. On Windows it would mean running
  Grok inside WSL; not set up here.

## Claude Code hooks also run inside Grok
Grok reads Claude Code hooks: `~/.claude/settings.json` always, and a project's
`.claude/settings.json` once that folder is trusted in grok. So a Claude hook (formatter,
notifier, "on Stop" script) fires for Grok's tool calls too. If that causes surprises, pass
`-NoClaudeHooks` (sets `GROK_CLAUDE_HOOKS_ENABLED=0` for that run only).

## Approval prompts cancel headless runs
Any tool call that waits for approval ends a headless run with `stopReason=cancelled`. Both
`--permission-mode plan` and `--permission-mode dontAsk` still did this (tested 2026-10-09 on grok
1.0.50). So both modes run `--always-approve`, and limits come from the toolset, deny rules and the
guard, which deny with a reason instead of prompting. If a run still cancels, read the tail of
`~/.grok/sessions/<cwd>/*/chat_history.jsonl` or the run's `.jsonl` log for the blocked tool.

## Hangs and long sessions
- The wrapper kills a run with no output for `-StallMinutes` (default 15) and prints `GROK STALLED`
  plus whatever changed on disk. A legitimately silent long command (big test suite) needs a higher value.
- Resuming a session whose context is already huge can hang. The wrapper records each session's
  context size in `~/.claude/grok/runs/sessions/<id>.json`; past `-MaxResumeTokens` (default 400k) a
  `-Resume` starts a fresh session with the original spec + your notes, told to finish the work on disk.

## Worktrees and disk
- `-Worktree` worktrees live in `~/.grok/worktrees/` (on C:). They copy HEAD plus uncommitted
  changes; a baseline commit inside the worktree keeps your own uncommitted edits out of Grok's diff.
- Clean up after applying: `grok worktree rm -f <id>`; list with `grok worktree list`; sweep old
  ones with `grok worktree gc --max-age 7d`. `grok du` shows what `~/.grok` uses.
- Without `-Worktree`, the change list is a snapshot of `-Cwd`, so two runs in one directory report
  each other's edits — that's what `-Worktree` is for.
- Disk full on C: (Grok sessions, worktrees, uv cache, temp) kills runs mid-way and can wedge Docker
  Desktop/WSL. Keep throwaway clones off C:; if Docker hangs, `wsl --shutdown` + restart Docker Desktop.

## Misc
- `NODE_OPTIONS=--import <pkg>` set globally (e.g. `claude-code-cache-fix`) makes `node` fail
  (ERR_MODULE_NOT_FOUND) in projects without that package. Grok works around it by clearing
  `NODE_OPTIONS`; do the same (`$env:NODE_OPTIONS=$null`) when re-running checks.
- Task/log files carry a random suffix, so parallel launches in the same second never share a prompt
  (fixed 2026-09-28). After a parallel launch, each session's title is in
  `~/.grok/sessions/<cwd>/*/summary.json`.
- Update checks are skipped per run (`GROK_DISABLE_AUTOUPDATER=1`); update grok yourself with `grok update`.
- Raw stream of every run: `~/.claude/grok/runs/<stamp>-<mode>.jsonl` (outside this repo).
