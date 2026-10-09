<#
Runs Grok (grok-4.7 via the Grok Build CLI) as a headless execution agent.
Claude plans and reviews; Grok executes. Streams progress while Grok works, kills a run
that goes silent, and prints an independent list of files that actually changed, so the
review never relies on Grok's own claims.

  plan : read-only. Grok only gets read/search tools plus a shell that grok-guard.ps1 limits to
         read-only commands. Nothing ever waits for approval (that cancels a headless run);
         a blocked command is denied with a reason and Grok carries on. No subagents (they
         would not inherit the read-only gate).
  exec : Grok edits and runs commands (auto-approved) under the deny list + grok-guard.ps1.
  MCP tools are denied in both modes unless -AllowMcp (they can deploy/publish).

  -Worktree       run in a fresh grok-managed git worktree (use for parallel runs). Changes are
                  then a plain `git diff` against a baseline commit; nothing touches -Cwd.
  -Resume <id>    continue a session (approve a plan, or send fixes). -Cwd defaults to where
                  that session ran. A session whose context grew past -MaxResumeTokens is
                  replaced by a fresh one told to finish the partial work already on disk.
#>
param(
    [string]$Cwd,
    [string]$Task,
    [string]$TaskFile,
    [ValidateSet('plan', 'exec')][string]$Mode = 'exec',
    [string]$Resume,
    [switch]$Worktree,
    [string]$Model = 'grok-4.7',
    [string]$Effort,
    [int]$MaxTurns = 40,
    [int]$StallMinutes = 15,
    [int]$MaxResumeTokens = 400000,
    [switch]$NoClaudeHooks,
    [switch]$AllowMcp
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new()
$utf8 = [Text.UTF8Encoding]::new($false)

if ([bool]$Task -eq [bool]$TaskFile) { throw 'Pass exactly one of -Task or -TaskFile.' }
$grokExe = (Get-Command grok -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if (-not $grokExe) { throw 'grok not found on PATH. Install it and run `grok login` (see README.md).' }

# Native calls without PS 5.1 turning stderr lines (git CRLF warnings etc.) into terminating errors.
function Invoke-Native([string]$exe, [string[]]$argv) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = @(& $exe @argv 2>&1 | ForEach-Object { "$_" }) } finally { $ErrorActionPreference = $prev }
    [pscustomobject]@{ Code = $LASTEXITCODE; Lines = $out }
}
function Invoke-Git([string]$dir, [string[]]$argv) { Invoke-Native git (@('-C', $dir, '-c', 'core.safecrlf=false', '-c', 'core.quotepath=false') + $argv) }

# Logs and session state live outside the skill dir so they never end up in its git repo.
$runsDir = Join-Path $HOME '.claude\grok\runs'
$stateDir = Join-Path $runsDir 'sessions'
New-Item -ItemType Directory -Force $stateDir | Out-Null
# Unique per run: parallel launches in the same second must not share task/log files.
$stamp = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)

# Inline tasks go through a UTF-8 file: PS 5.1 mangles embedded quotes in native args.
if ($Task) {
    $TaskFile = Join-Path $runsDir "$stamp-task.md"
    [IO.File]::WriteAllText($TaskFile, $Task, $utf8)
}
if (-not (Test-Path -LiteralPath $TaskFile -PathType Leaf)) { throw "TaskFile not found: $TaskFile" }
$TaskFile = (Resolve-Path -LiteralPath $TaskFile).Path

# --- Session state: where a session ran, its spec, and how big its context got. ---
$state = $null
if ($Resume) {
    $statePath = Join-Path $stateDir "$Resume.json"
    if (Test-Path -LiteralPath $statePath) { $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json }
    if (-not $Cwd) {
        if (-not $state) { throw "No saved state for session $Resume; pass -Cwd." }
        $Cwd = $state.cwd
    }
}
if (-not $Cwd) { throw 'Pass -Cwd (the project directory).' }
if (-not (Test-Path -LiteralPath $Cwd -PathType Container)) { throw "Cwd not found: $Cwd" }
$Cwd = (Resolve-Path -LiteralPath $Cwd).Path

$wtRoot = $null; $wtId = $null; $baseline = $null; $specFile = $TaskFile
if ($state) {
    if ($state.worktree -and $state.cwd -eq $Cwd) { $wtRoot = $state.worktree; $wtId = $state.worktreeId; $baseline = $state.baseline }
    if ($state.specFile) { $specFile = $state.specFile }
}

# Long resumed sessions get slow and can hang: start fresh on the partial work instead.
if ($Resume -and $state -and [long]$state.contextTokens -gt $MaxResumeTokens) {
    Write-Output ("== session {0} context is ~{1:N0} tokens (> {2:N0}): starting a FRESH session on the partial work instead of resuming." -f $Resume, [long]$state.contextTokens, $MaxResumeTokens)
    $spec = if (Test-Path -LiteralPath $specFile) { [IO.File]::ReadAllText($specFile) } else { '(original spec file missing)' }
    $handoff = "CONTINUATION. A previous executor session worked on the spec below, but its conversation grew too long. " +
        "Its partial work is already on disk in this directory. First inspect it (git status, git diff, read the touched files), " +
        "then finish what is missing. Do not start over and do not revert the existing work unless the reviewer notes say so.`n`n" +
        "## Original spec`n`n$spec`n`n## Latest reviewer notes`n`n" + [IO.File]::ReadAllText($TaskFile)
    $TaskFile = Join-Path $runsDir "$stamp-handoff.md"
    [IO.File]::WriteAllText($TaskFile, $handoff, $utf8)
    $Resume = $null
}

# --- Optional isolated worktree (grok creates it from HEAD + uncommitted changes). ---
if ($Worktree -and -not $wtRoot) {
    if ($Resume) { throw '-Worktree cannot be combined with -Resume of a session that did not use one.' }
    $top = Invoke-Git $Cwd @('rev-parse', '--show-toplevel', '--show-prefix')
    if ($top.Code -ne 0) { throw "-Worktree needs a git repo: $Cwd" }
    $prefix = if ($top.Lines.Count -ge 2) { $top.Lines[1].Trim() } else { '' }
    Push-Location -LiteralPath $Cwd
    try { $created = Invoke-Native $grokExe @('worktree', 'create', "grok-$stamp") } finally { Pop-Location }
    $wtRoot = $created.Lines | Where-Object { $_.Trim() -match '^[A-Za-z]:\\[^<>|?*"]*$' -and (Test-Path -LiteralPath $_.Trim() -PathType Container) } | Select-Object -Last 1
    if ($created.Code -ne 0 -or -not $wtRoot) { throw "grok worktree create failed:`n$($created.Lines -join "`n")" }
    $wtRoot = $wtRoot.Trim()
    # Baseline commit (detached HEAD, worktree only) so the user's own uncommitted changes that were
    # copied in don't show up as Grok's.
    Invoke-Git $wtRoot @('add', '-A') | Out-Null
    $c = Invoke-Git $wtRoot @('-c', 'user.name=grok-exec', '-c', 'user.email=grok-exec@localhost', 'commit', '-q', '--no-verify', '--allow-empty', '-m', 'grok-exec baseline')
    if ($c.Code -ne 0) { throw "baseline commit failed:`n$($c.Lines -join "`n")" }
    $baseline = (Invoke-Git $wtRoot @('rev-parse', 'HEAD')).Lines[0].Trim()
    $list = Invoke-Native $grokExe @('worktree', 'list', '--json')
    try { $wtId = (($list.Lines -join "`n") | ConvertFrom-Json | Where-Object { $_.path -eq $wtRoot } | Select-Object -First 1).id } catch { }
    $Cwd = if ($prefix) { Join-Path $wtRoot $prefix } else { $wtRoot }
}

# --- Gatekeeper hook: full-command check that prefix --deny rules can't do. ---
$hookDir = Join-Path $HOME '.grok\hooks'
$hookFile = Join-Path $hookDir 'claude-grok-skill.json'
$guardPath = (Join-Path $PSScriptRoot 'grok-guard.ps1') -replace '\\', '/'
$hookJson = @"
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash|monitor|Edit|Write",
        "hooks": [
          { "type": "command", "command": "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"$guardPath\"", "timeout": 20 }
        ]
      }
    ]
  }
}
"@
if (-not (Test-Path -LiteralPath $hookFile) -or [IO.File]::ReadAllText($hookFile) -ne $hookJson) {
    New-Item -ItemType Directory -Force $hookDir | Out-Null
    [IO.File]::WriteAllText($hookFile, $hookJson, $utf8)
}

# Hard guardrails (prefix rules; grok-guard.ps1 catches the variants these miss).
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
    'commit, push, deploy, or delete directories; a guard blocks those, so do not try workarounds. ' +
    'If the spec is ambiguous or a step is impossible, stop and say so instead of guessing. End with a ' +
    'report: 1) files changed, 2) commands run and their real result, 3) anything not done or uncertain.'
if ($Mode -eq 'plan') {
    $rules += ' PLAN ONLY: do not edit files; only read-only shell commands are allowed and others are denied. ' +
        'Reply with a concrete step-by-step plan: files/symbols to change, the change in each, risks, and how to verify.'
}

$grokArgs = @('--prompt-file', $TaskFile, '--cwd', $Cwd, '-m', $Model, '--output-format', 'streaming-json',
    '--max-turns', $MaxTurns, '--no-plan', '--rules', $rules)
if ($Resume) { $grokArgs += @('-r', $Resume) }
if ($Effort) { $grokArgs += @('--reasoning-effort', $Effort) }
# Always-approve in both modes: a headless run that hits an approval prompt is cancelled
# (--permission-mode plan/dontAsk both still did that). Limits come from the toolset, the deny
# rules and grok-guard.ps1 instead, which deny with a reason so Grok keeps going.
$grokArgs += '--always-approve'
if ($Mode -eq 'plan') {
    $grokArgs += @('--tools', 'read_file,list_dir,grep,run_terminal_command,todo_write', '--no-subagents',
        '--disable-web-search', '--deny', 'Edit', '--deny', 'Write')
}
if (-not $AllowMcp) { $grokArgs += @('--deny', 'MCPTool') }
foreach ($r in $deny) { $grokArgs += @('--deny', $r) }

# Without -Worktree: snapshot file state so the change list comes from disk, not from Grok's report.
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
$before = if (-not $baseline) { Get-Snapshot $Cwd }

# Windows command-line quoting for ProcessStartInfo.Arguments.
function ConvertTo-ArgString([object[]]$argv) {
    ($argv | ForEach-Object {
            $s = [string]$_
            if ($s -eq '') { '""' }
            elseif ($s -notmatch '[\s"]') { $s }
            else { '"' + (($s -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"' }
        }) -join ' '
}
function Format-ToolInput($ri) {
    if (-not $ri) { return '' }
    $s = if ($ri.command) { $ri.command } elseif ($ri.path) { $ri.path } elseif ($ri.file_path) { $ri.file_path } elseif ($ri.target_file) { $ri.target_file } else { $ri | ConvertTo-Json -Compress -Depth 3 }
    $s = ([string]$s) -replace '\s+', ' '
    if ($s.Length -gt 140) { $s.Substring(0, 140) + '...' } else { $s }
}

$psi = [Diagnostics.ProcessStartInfo]::new($grokExe, (ConvertTo-ArgString $grokArgs))
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.StandardOutputEncoding = $utf8
$psi.WorkingDirectory = $Cwd
$psi.EnvironmentVariables['CLAUDE_GROK_GUARD'] = $Mode      # activates grok-guard.ps1 for this run only
$psi.EnvironmentVariables['GROK_DISABLE_AUTOUPDATER'] = '1' # no update check on every launch
if ($NoClaudeHooks) { $psi.EnvironmentVariables['GROK_CLAUDE_HOOKS_ENABLED'] = '0' }

$logFile = Join-Path $runsDir "$stamp-$Mode.jsonl"
$log = [IO.StreamWriter]::new($logFile, $false, $utf8)
$text = [Text.StringBuilder]::new()
$end = $null; $errMsg = $null; $ctxTokens = 0; $stalled = $false
Write-Output ("== grok {0} started {1:HH:mm:ss} | cwd {2} | log {3}" -f $Mode, (Get-Date), $Cwd, $logFile)

$proc = [Diagnostics.Process]::Start($psi)
$lastActivity = Get-Date
$pending = $proc.StandardOutput.ReadLineAsync()
try {
    while ($true) {
        if (-not $pending.Wait(2000)) {
            if (((Get-Date) - $lastActivity).TotalMinutes -ge $StallMinutes) { $stalled = $true; break }
            continue
        }
        $line = $pending.Result
        if ($null -eq $line) { break }
        $pending = $proc.StandardOutput.ReadLineAsync()
        $lastActivity = Get-Date
        $log.WriteLine($line)
        $log.Flush()
        try { $ev = $line | ConvertFrom-Json } catch { continue }
        switch ($ev.type) {
            'text' { [void]$text.Append($ev.data) }
            'tool_call' { Write-Output ("[{0:HH:mm:ss}] {1}: {2}" -f (Get-Date), $ev.toolName, (Format-ToolInput $ev.rawInput)) }
            'usage' {
                # One per model response: keep separate replies from running together.
                if ($text.Length -and $text[$text.Length - 1] -ne "`n") { [void]$text.Append("`n`n") }
                $u = $ev.usage
                $n = [long]$u.input_tokens + [long]$u.cache_read_input_tokens + [long]$u.cache_creation_input_tokens
                if ($n -gt 0) { $ctxTokens = $n }
            }
            'end' { $end = $ev }
            'error' { $errMsg = $ev.message }
        }
    }
} finally {
    # Stdout closing comes slightly before exit; only a stalled (or interrupted) run gets killed.
    if (-not $stalled) { $proc.WaitForExit(30000) | Out-Null }
    if (-not $proc.HasExited) {
        Invoke-Native taskkill @('/PID', "$($proc.Id)", '/T', '/F') | Out-Null
        $proc.WaitForExit(10000) | Out-Null
    }
    $log.Close()
}
$grokExit = if ($proc.HasExited) { $proc.ExitCode } else { -1 }

# --- Independent change list. ---
$changes = @()
if ($baseline) {
    Invoke-Git $wtRoot @('add', '-A', '-N') | Out-Null
    $changes = @((Invoke-Git $wtRoot @('diff', '--name-status', '--no-renames', $baseline)).Lines |
            Where-Object { $_ -match '^[A-Z]\t' } | ForEach-Object { ($_ -replace '^([A-Z])\t', '$1  ') })
} else {
    $after = Get-Snapshot $Cwd
    foreach ($k in $after.Keys) {
        if (-not $before.ContainsKey($k)) { $changes += "A  $k" }
        elseif ($before[$k] -ne $after[$k]) { $changes += "M  $k" }
    }
    foreach ($k in $before.Keys) { if (-not $after.ContainsKey($k)) { $changes += "D  $k" } }
}

# --- Save session state for -Resume. ---
$sessionId = if ($end) { $end.sessionId } elseif ($Resume) { $Resume } else { $null }
if ($sessionId) {
    $prevCtx = if ($state -and $Resume -eq $sessionId) { [long]$state.contextTokens } else { 0 }
    [ordered]@{
        sessionId     = $sessionId
        cwd           = $Cwd
        worktree      = $wtRoot
        worktreeId    = $wtId
        baseline      = $baseline
        specFile      = $specFile
        contextTokens = [math]::Max($ctxTokens, $prevCtx)
        updated       = (Get-Date).ToString('s')
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stateDir "$sessionId.json") -Encoding UTF8
}

function Write-Changes {
    Write-Output "== files changed on disk ($($changes.Count)):"
    if ($changes) { $changes | Sort-Object | Write-Output } else { Write-Output '(none)' }
    if ($wtRoot) {
        Write-Output "== worktree: $wtRoot  (baseline $baseline)"
        Write-Output "   review : git -C `"$wtRoot`" diff $baseline"
        Write-Output "   apply  : git -C `"$wtRoot`" diff --binary $baseline | git -C <your repo> apply"
        $wtRef = if ($wtId) { $wtId } else { "`"$wtRoot`"" }
        Write-Output "   cleanup: grok worktree rm -f $wtRef"
    } elseif (Test-Path -LiteralPath (Join-Path $Cwd '.git')) {
        Write-Output '== git diff --stat:'
        (Invoke-Git $Cwd @('diff', '--stat')).Lines | Write-Output
    }
}

if ($stalled) {
    Write-Output "== GROK STALLED: no output for $StallMinutes min; killed. Session $sessionId. Partial work may be on disk."
    Write-Changes
    exit 1
}
if ($grokExit -ne 0 -or -not $end) {
    Write-Output "== GROK FAILED (exit $grokExit). $(if ($errMsg) { $errMsg }) Raw log: $logFile"
    if ($text.Length) { Write-Output $text.ToString() }
    Write-Changes
    exit 1
}

$cost = if ($null -ne $end.total_cost_usd) { '${0:N4}' -f [double]$end.total_cost_usd } else { 'cost n/a' }
Write-Output ("== grok {0} | session {1} | stop {2} | turns {3} | {4} | context ~{5:N0} tok" -f $Mode, $sessionId, $end.stopReason, $end.num_turns, $cost, $ctxTokens)
if ($end.stopReason -ne 'end_turn') { Write-Output "== WARNING: run did not finish normally (stopReason=$($end.stopReason))." }
Write-Changes
Write-Output '== grok report:'
Write-Output $text.ToString()
Write-Output "== log: $logFile"
