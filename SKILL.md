---
name: grok
description: Delegate execution to Grok 4.7 as a sub-agent while Claude stays the planner and reviewer. Use when the user types /grok, or asks to have Grok do/execute/implement something, or to use Grok as the executor.
---

# Grok executor — Claude plans, Grok executes, Claude reviews

Grok 4.7 runs headless through `$HOME\.claude\skills\grok\grok-exec.ps1` (Grok Build CLI,
must be installed and logged in — if `grok` is missing or auth fails, tell the user to run
`grok login`; see README.md). Claude owns the plan, the verdict, and anything irreversible (commit, push,
deploy, deletes); the script's deny list blocks Grok from those.

## Loop

1. **Plan (Claude).** Read the relevant code yourself first. Write a task spec to a UTF-8 file
   in the scratch dir (`$CLAUDE_JOB_DIR/tmp` or the project's `qa/`), never the repo root:
   goal in one sentence · exact files/symbols to touch · constraints (style, no new deps,
   out-of-scope areas) · acceptance checks (build/test commands and expected result).
   Specific spec in, reviewable diff out — vague specs are the main failure mode.

2. **Gate by risk.**
   - Low risk (local, reversible, small): dispatch `-Mode exec` directly.
   - Higher risk (many files, migrations, deletes, config, anything outside the repo):
     dispatch `-Mode plan` first, judge Grok's plan against yours, then approve by resuming
     the same session: `-Resume <sessionId> -Mode exec -Task "Approved. Execute. <corrections>"`.

3. **Dispatch.**
   ```powershell
   & "$HOME\.claude\skills\grok\grok-exec.ps1" -Cwd <project dir> -TaskFile <spec.md> -Mode exec
   ```
   Optional: `-Effort low|medium|high|xhigh`, `-MaxTurns N` (default 40), `-Model grok-4.7-build-fast`
   for trivial edits. Runs longer than ~8 min → use the PowerShell tool's `run_in_background`.

4. **Review (Claude) — never trust Grok's report alone.** The script prints the files that
   actually changed on disk (A/M/D). For each: read the diff (`git diff` or read the file),
   check it against the spec as a hostile reviewer — scope creep, unrelated edits, deleted
   code, `any`/`as` casts, swallowed errors, missed edge cases. Then run the acceptance
   checks yourself and look at the real output. `stop` other than `end_turn` = incomplete.

5. **Verdict.**
   - Pass → report to the user with evidence (test output / screenshot). Commit only if asked.
   - Fixable → resume the same session with concrete corrections (file, line, what's wrong):
     `-Resume <sessionId> -Task "Review failed: ..."`. Re-review. Max 2 correction rounds.
   - Wrong direction or 2 rounds exhausted → revert Grok's changes (`git checkout -- <files>`
     for tracked files you have reviewed; ask the user before deleting anything untracked)
     and do the task yourself.

## Notes
- Every run's raw JSON is saved under `$HOME\.claude\grok\runs\` (outside this repo).
- Grok can't commit, push, deploy, `git reset --hard`/`clean`/`restore`, or recursively delete —
  those are denied in `exec` mode; do them yourself after review if the user wants them.
- Tell the user the Grok cost from the summary line when reporting.
- Gotcha: if the user env sets a global `NODE_OPTIONS=--import <pkg>` (e.g. `claude-code-cache-fix`),
  `node` fails (ERR_MODULE_NOT_FOUND) in projects that don't have that package locally. Grok works around it
  by clearing `NODE_OPTIONS`; do the same (`$env:NODE_OPTIONS=$null`) when re-running checks.
- Gotcha: in `-Mode plan`, any tool that needs approval — web search/fetch AND `run_terminal_command` —
  ends the run with `stopReason=cancelled` (headless can't answer). The script now passes
  `--disable-web-search --disallowed-tools run_terminal_command` in plan mode. If a plan run still
  cancels, read the tail of `~/.grok/sessions/<cwd>/*/chat_history.jsonl` for the blocked tool.
- Parallel runs: give each Grok run its own git worktree as `-Cwd`; the changed-file list is a
  snapshot of `-Cwd`, so two runs in one directory report each other's edits.
- Gotcha (fixed 2026-09-28): inline `-Task` files used to be named by second-resolution timestamp,
  so runs launched in the same second read each other's prompt. Names now carry a random suffix.
  After a parallel launch, check each session's title in `~/.grok/sessions/<cwd>/*/summary.json`.
- Gotcha: resuming (`-Resume`) a session whose context is already huge (millions of input tokens)
  can hang with no session writes. If `~/.grok/sessions/<cwd>/<id>/` has no file newer than the
  run's start after ~10 min, stop that grok process and start a FRESH session that is told to read
  the partial work already on disk (`git status`) and finish it rather than start over.
- Gotcha: disk full on C: (Grok sessions, uv cache, temp) kills runs mid-way and can wedge Docker
  Desktop/WSL. Keep throwaway clones off C:; if Docker hangs, `wsl --shutdown` + restart Docker Desktop.
- Deny rules are prefix globs: they catch `git commit ...` but not variants like `git -C x commit`.
  Still review `git log`/`git status` after each run.
