<#
Runs Grok (grok-4.7 via the Grok Build CLI) as a headless execution agent.
Claude plans and reviews; Grok executes. Prints Grok's report plus an independent
list of files that actually changed, so the review never relies on Grok's own claims.

  plan : Grok reads the code and proposes steps; no edits, no commands.
  exec : Grok edits and runs commands (auto-approved) under the deny list below.
  -Resume <sessionId> continues the same Grok session (approve a plan, or send fixes).
#>
param(
    [Parameter(Mandatory)][string]$Cwd,
    [string]$Task,
    [string]$TaskFile,
    [ValidateSet('plan', 'exec')][string]$Mode = 'exec',
    [string]$Resume,
    [string]$Model = 'grok-4.7',
    [string]$Effort,
    [int]$MaxTurns = 40
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new()

if (-not (Test-Path -LiteralPath $Cwd -PathType Container)) { throw "Cwd not found: $Cwd" }
$Cwd = (Resolve-Path -LiteralPath $Cwd).Path
if ([bool]$Task -eq [bool]$TaskFile) { throw 'Pass exactly one of -Task or -TaskFile.' }

# Logs live outside the skill dir so they never end up in its git repo.
$runsDir = Join-Path $HOME '.claude\grok\runs'
New-Item -ItemType Directory -Force $runsDir | Out-Null
# Unique per run: parallel launches in the same second must not share task/log files.
$stamp = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)

# Inline tasks go through a UTF-8 file: PS 5.1 mangles embedded quotes in native args.
if ($Task) {
    $TaskFile = Join-Path $runsDir "$stamp-task.md"
    [IO.File]::WriteAllText($TaskFile, $Task, [Text.UTF8Encoding]::new($false))
}
if (-not (Test-Path -LiteralPath $TaskFile -PathType Leaf)) { throw "TaskFile not found: $TaskFile" }

# Hard guardrails: irreversible or outward-facing actions stay with Claude/the user.
$deny = @(
    'Bash(git push*)', 'Bash(git commit*)', 'Bash(git reset --hard*)', 'Bash(git clean*)',
    'Bash(git checkout -- *)', 'Bash(git restore*)', 'Bash(git rebase*)', 'Bash(git branch -D*)',
    'Bash(rm -rf*)', 'Bash(rm -r *)', 'Bash(rm -fr*)', 'Bash(*Remove-Item*-Recurse*)',
    'Bash(del /s*)', 'Bash(rd /s*)', 'Bash(rmdir /s*)', 'Bash(format *)',
    'Bash(npm publish*)', 'Bash(pnpm publish*)', 'Bash(vercel*--prod*)', 'Bash(supabase db push*)',
    'Bash(railway*)', 'Bash(*railway *)',
    'Bash(shutdown*)', 'Bash(Stop-Computer*)', 'Bash(Restart-Computer*)'
)

$rules = 'You are the execution agent. A separate planner wrote this task spec and will review ' +
    'your work by diffing the files you touch and re-running checks. Do exactly the spec: no extra ' +
    'features, no refactors of unrelated code, no new dependencies unless the spec says so. Never ' +
    'commit, push, deploy, or delete directories. If the spec is ambiguous or a step is impossible, ' +
    'stop and say so instead of guessing. End with a report: 1) files changed, 2) commands run and ' +
    'their real result, 3) anything not done or uncertain.'

$grokArgs = @('--prompt-file', $TaskFile, '--cwd', $Cwd, '-m', $Model, '--output-format', 'json',
    '--max-turns', $MaxTurns, '--rules', $rules)
if ($Resume) { $grokArgs += @('-r', $Resume) }
if ($Effort) { $grokArgs += @('--reasoning-effort', $Effort) }
if ($Mode -eq 'plan') {
    # Any tool that needs approval (web, shell) cancels a headless plan run: remove them.
    $grokArgs += @('--permission-mode', 'plan', '--disable-web-search', '--disallowed-tools', 'run_terminal_command')
} else {
    $grokArgs += '--always-approve'
    foreach ($r in $deny) { $grokArgs += @('--deny', $r) }
}

# Snapshot file state so the change list comes from disk, not from Grok's report.
$skipDirs = @('.git', 'node_modules', 'dist', 'build', '.next', '.venv', 'venv', '__pycache__', '.turbo', '.cache')
function Get-Snapshot([string]$root) {
    $map = @{}
    $stack = [Collections.Generic.Stack[string]]::new()
    $stack.Push($root)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        foreach ($item in [IO.DirectoryInfo]::new($dir).EnumerateFileSystemInfos()) {
            if ($item -is [IO.DirectoryInfo]) {
                if ($skipDirs -notcontains $item.Name -and -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                    $stack.Push($item.FullName)
                }
            } else {
                $map[$item.FullName.Substring($root.Length).TrimStart('\')] = "$($item.LastWriteTimeUtc.Ticks):$($item.Length)"
            }
        }
    }
    $map
}
$before = Get-Snapshot $Cwd

$raw = & grok @grokArgs | Out-String
$grokExit = $LASTEXITCODE
$after = Get-Snapshot $Cwd

$logFile = Join-Path $runsDir "$stamp-$Mode.json"
[IO.File]::WriteAllText($logFile, $raw, [Text.UTF8Encoding]::new($false))

$changes = @()
foreach ($k in $after.Keys) {
    if (-not $before.ContainsKey($k)) { $changes += "A  $k" }
    elseif ($before[$k] -ne $after[$k]) { $changes += "M  $k" }
}
foreach ($k in $before.Keys) { if (-not $after.ContainsKey($k)) { $changes += "D  $k" } }

try { $res = $raw | ConvertFrom-Json } catch { $res = $null }
if ($grokExit -ne 0 -or -not $res) {
    Write-Output "== GROK FAILED (exit $grokExit). Raw output: $logFile"
    Write-Output $raw
    if ($changes) { Write-Output '== files changed anyway:'; $changes | Sort-Object | Write-Output }
    exit 1
}

Write-Output ("== grok {0} | session {1} | stop {2} | turns {3} | `${4:N4}" -f $Mode, $res.sessionId, $res.stopReason, $res.num_turns, $res.total_cost_usd)
if ($res.stopReason -ne 'end_turn') { Write-Output "== WARNING: run did not finish normally (stopReason=$($res.stopReason))." }
Write-Output "== files changed on disk ($($changes.Count)):"
if ($changes) { $changes | Sort-Object | Write-Output } else { Write-Output '(none)' }
if (Test-Path -LiteralPath (Join-Path $Cwd '.git')) {
    Write-Output '== git diff --stat:'
    git -C $Cwd diff --stat | Write-Output
}
Write-Output '== grok report:'
Write-Output $res.text
Write-Output "== log: $logFile"
