---
name: grok
description: Delegate execution to Grok 4.7 as a sub-agent while Claude stays the planner and reviewer. Use when the user types /grok, or asks to have Grok do/execute/implement something, or to use Grok as the executor.
---

# Grok executor — Claude plans, Grok executes, Claude reviews

Grok 4.7 runs headless through `$HOME\.claude\skills\grok\grok-exec.ps1` (Grok Build CLI,
must be installed and logged in — if `grok` is missing or auth fails, tell the user to run
`grok login`; see README.md). Claude owns the plan, the verdict, and anything irreversible (commit, push,
deploy, deletes); deny rules plus a gatekeeper hook (`grok-guard.ps1`) block Grok from those.

## Delegate or not
Small, well-understood edits (roughly under ~30 lines, 1–2 files) — do them yourself; a spec plus
review costs more than the edit. Delegate bigger mechanical work, multi-file changes, or parallel tasks.

## Loop

1. **Plan (Claude).** Read the relevant code yourself first. Write a task spec to a UTF-8 file
   in the scratch dir (`$CLAUDE_JOB_DIR/tmp` or the project's `qa/`), never the repo root:
   goal in one sentence · exact files/symbols to touch · constraints (style, no new deps,
   out-of-scope areas) · acceptance checks (build/test commands and expected result).
   Specific spec in, reviewable diff out — vague specs are the main failure mode.

2. **Gate by risk.**
   - Low risk (local, reversible, small): dispatch `-Mode exec` directly.
   - Higher risk (many files, migrations, deletes, config, anything outside the repo):
     dispatch `-Mode plan` first (read-only: no edits, only read-only shell commands), judge
     Grok's plan against yours, then approve by resuming:
     `-Resume <sessionId> -Mode exec -Task "Approved. Execute. <corrections>"`.

3. **Dispatch.**
   ```powershell
   & "$HOME\.claude\skills\grok\grok-exec.ps1" -Cwd <project dir> -TaskFile <spec.md> -Mode exec
   ```
   Optional: `-Effort low|medium|high|xhigh`, `-MaxTurns N` (default 40), `-Model grok-4.7-build-fast`
   for trivial edits, `-StallMinutes N` (default 15; raise it for very long test suites).
   Progress lines print as Grok works; runs longer than ~8 min → PowerShell tool's `run_in_background`.
   - **Parallel runs:** add `-Worktree` to every run. Each gets its own grok worktree (copy of HEAD +
     uncommitted changes) and a baseline commit; the output prints how to review, apply and clean it up.
     Apply only after review, then `grok worktree rm -f <id>`.

4. **Review (Claude) — never trust Grok's report alone.** The script prints the files that
   actually changed on disk (A/M/D). For each: read the diff (`git diff`, or the worktree diff
   command it prints), check it against the spec as a hostile reviewer — scope creep, unrelated
   edits, deleted code, `any`/`as` casts, swallowed errors, missed edge cases. Then run the
   acceptance checks yourself and look at the real output. `stop` other than `end_turn`, or
   `GROK STALLED`, = incomplete.

5. **Verdict.**
   - Pass → report to the user with evidence (test output / screenshot) and the Grok cost from the
     summary line. Commit only if asked.
   - Fixable → `-Resume <sessionId> -Task "Review failed: <file, line, what's wrong>"` (`-Cwd` is
     remembered). Re-review. Max 2 correction rounds. A session past `-MaxResumeTokens` (400k) is
     automatically replaced by a fresh one that finishes the partial work on disk.
   - Wrong direction or 2 rounds exhausted → revert Grok's changes (`git checkout -- <files>`
     for tracked files you have reviewed; ask the user before deleting anything untracked; with
     `-Worktree` just remove the worktree) and do the task yourself.

Something odd (cancelled run, hang, guard false positive, disk full)? Read `GOTCHAS.md` in this skill.
