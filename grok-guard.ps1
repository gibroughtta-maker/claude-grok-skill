<#
PreToolUse gatekeeper for grok-exec.ps1.

grok-exec.ps1 registers this in ~/.grok/hooks/claude-grok-skill.json. It only acts when
CLAUDE_GROK_GUARD is set, which grok-exec.ps1 does for the Grok process it launches, so your own
interactive grok sessions are not affected.
  CLAUDE_GROK_GUARD=exec : block commit/push/deploy/recursive delete and similar.
  CLAUDE_GROK_GUARD=plan : read-only; only commands like ls/cat/grep/git log|diff|status pass.

The --deny rules in grok-exec.ps1 are prefix matches: they catch `git commit ...` but not
`git -C x commit`, `cd x && git commit`, `bash -c "git commit"` or `& git commit`. This
guard splits the whole command into segments, peels wrappers (env vars, sudo, timeout, nested
shells, `&`), skips git's global options, then checks what actually runs.
It fails closed: an error inside the guard denies the call. (If the guard cannot start at all,
Grok fails open, which is why grok-exec.ps1 keeps its --deny list as a second layer.)

Test without Grok:  .\grok-guard.ps1 -Command 'git -C x commit -m y' [-Level plan]   -> prints DENY/ALLOW
#>
param([string]$Command, [ValidateSet('exec', 'plan')][string]$Level = 'exec')
$ErrorActionPreference = 'Stop'

$guardHint = ' This action is reserved for the reviewer (Claude). Skip it and list it under "not done" in your report.'
$planHint = ' Plan mode is read-only: use read_file/grep/list_dir or a read-only command, and put anything else you would run into the plan.'

# Plan mode: programs that only read. git/find/sort are checked separately below.
$readOnlyCmds = 'ls', 'dir', 'cat', 'type', 'head', 'tail', 'less', 'more', 'grep', 'egrep', 'fgrep', 'rg', 'findstr', 'wc', 'tree',
'pwd', 'cd', 'echo', 'printf', 'which', 'where', 'file', 'stat', 'du', 'uniq', 'cut', 'jq', 'diff', 'basename', 'dirname', 'realpath', 'true',
'select-string', 'sls', 'get-childitem', 'gci', 'get-content', 'gc', 'get-item', 'gi', 'test-path', 'resolve-path', 'get-location', 'gl',
'set-location', 'sl', 'get-command', 'gcm', 'write-output', 'write-host', 'measure-object', 'measure', 'select-object', 'select',
'sort-object', 'where-object', 'foreach-object', '%', '?', 'format-table', 'ft', 'format-list', 'fl', 'out-string', 'convertfrom-json'
$readOnlyGit = 'status', 'log', 'diff', 'show', 'blame', 'ls-files', 'ls-tree', 'grep', 'rev-parse', 'describe', 'shortlog', 'cat-file', 'reflog', 'help'

# Grok's own config, hooks and trust files, and this skill. Touching them could switch the guard off.
$protectedPath = '\.grok[\\/]+(hooks|hooks-paths|disabled-hooks|config\.toml|trusted_folders|requirements\.toml|managed_config|sandbox\.toml)|\.claude[\\/]+skills[\\/]+grok|grok-guard\.ps1|claude-grok-skill\.json|CLAUDE_GROK_GUARD|GROK_CLAUDE_HOOKS_ENABLED'

$wrappers = 'sudo', 'doas', 'env', 'command', 'builtin', 'exec', 'nohup', 'time', 'nice', 'ionice', 'stdbuf', 'chrt', 'xargs', 'call', 'start', 'timeout', 'start-process', 'invoke-expression', 'iex'
$shells = 'bash', 'sh', 'zsh', 'dash', 'ksh', 'fish', 'cmd', 'powershell', 'pwsh', 'wsl'
# Shell options that consume the next token.
$shellArgOpts = '-executionpolicy', '-ep', '-ex', '-windowstyle', '-w', '-inputformat', '-outputformat', '-workingdirectory', '-wd', '-configurationname', '-version', '-d', '--distribution', '-u', '--user', '--cd'
$gitArgOpts = '-c', '--git-dir', '--work-tree', '--namespace', '--super-prefix', '--config-env', '--exec-path'

function Get-Name([string]$tok) {
    (($tok -split '[\\/]')[-1] -replace '\.(exe|cmd|bat|ps1)$', '').ToLowerInvariant()
}

function Test-ReadOnly([string]$name, [string[]]$a, [string[]]$al) {
    if ($readOnlyCmds -contains $name) { return $null }
    if ($name -eq 'sort') { if ($al -match '^(-o|--output)') { return 'sort -o writes a file' }; return $null }
    if ($name -eq 'find') { if ($al -match '^-(delete|exec|execdir|ok|fprint)') { return 'find with -delete/-exec' }; return $null }
    if ($name -eq 'git') {
        $j = 0
        while ($j -lt $a.Count -and $a[$j] -match '^-') { if ($gitArgOpts -contains $al[$j] -or $a[$j] -ceq '-C') { $j++ }; $j++ }
        if ($j -ge $a.Count) { return $null }
        $sub = $al[$j]
        $rest = @(if ($j + 1 -lt $a.Count) { $al[($j + 1)..($al.Count - 1)] })
        if ($readOnlyGit -contains $sub -and -not ($rest -match '^--output')) { return $null }
        if ($sub -eq 'branch' -and -not ($rest | Where-Object { $_ -notmatch '^(-a|-r|-v|-vv|--list|--all|--remotes|--show-current|--contains|--merged|--no-merged)$' })) { return $null }
        if ($sub -eq 'remote' -and -not ($rest | Where-Object { $_ -notmatch '^(-v|--verbose|show|get-url)$' })) { return $null }
        if ($sub -eq 'config' -and ($rest -match '^(--get|--get-all|--list|-l)$')) { return $null }
        return "git $sub"
    }
    return $name
}

function Test-Segment([string[]]$t, [bool]$readOnly) {
    # Peel wrappers and nested shells until the real program is first.
    $i = 0
    while ($i -lt $t.Count) {
        $name = Get-Name $t[$i]
        if ($t[$i] -match '^[A-Za-z_][A-Za-z0-9_]*=') { $i++; continue }        # FOO=bar cmd
        if ($t[$i] -match '^\$env:[A-Za-z_]') { $i++; continue }                 # $env:X=1
        if ($wrappers -contains $name -or $shells -contains $name) {
            $i++
            while ($i -lt $t.Count -and ($t[$i] -match '^-' -or (($shells -contains $name -or $name -eq 'start') -and $t[$i] -match '^/[a-zA-Z]$') -or ($name -eq 'timeout' -and $t[$i] -match '^\d'))) {
                if ($shellArgOpts -contains $t[$i].ToLowerInvariant()) { $i++ }
                $i++
            }
            continue
        }
        break
    }
    if ($i -ge $t.Count) { return $null }
    $name = Get-Name $t[$i]
    $a = @(if ($i + 1 -lt $t.Count) { $t[($i + 1)..($t.Count - 1)] })
    $al = @($a | ForEach-Object { $_.ToLowerInvariant() })
    if ($readOnly) { return Test-ReadOnly $name $a $al }

    switch -Regex ($name) {
        '^git$' {
            $j = 0
            while ($j -lt $a.Count -and $a[$j] -match '^-') {
                if ($a[$j] -ceq '-c' -and $j + 1 -lt $a.Count -and $a[$j + 1] -match '^alias\.') { return 'git -c alias.* (could hide a commit/push)' }
                if ($gitArgOpts -contains $a[$j].ToLowerInvariant() -or $a[$j] -ceq '-C') { $j++ }
                $j++
            }
            if ($j -ge $a.Count) { return $null }
            $sub = $al[$j]
            $rest = @(if ($j + 1 -lt $a.Count) { $a[($j + 1)..($a.Count - 1)] })
            if ($sub -in 'commit', 'push', 'clean', 'restore', 'rebase', 'merge', 'cherry-pick', 'revert', 'am', 'stash', 'filter-branch', 'filter-repo', 'update-ref', 'replace') { return "git $sub" }
            if ($sub -eq 'reset' -and ($rest -match '^--(hard|keep|merge)$')) { return 'git reset --hard/--keep/--merge' }
            if ($sub -eq 'checkout' -and ($rest -contains '--' -or $rest -contains '.' -or $rest -match '^(-f|--force)$')) { return 'git checkout that discards changes' }
            if ($sub -eq 'switch' -and ($rest -match '^(-f|--force|--discard-changes)$')) { return 'git switch --force' }
            if ($sub -eq 'branch' -and ($rest -cmatch '^-[a-zA-Z]*[DM]' -or (($rest -match '^(-d|--delete)$') -and ($rest -match '^(-f|--force)$')))) { return 'git branch -D / force' }
            if ($sub -eq 'worktree' -and ($rest -match '^(remove|prune)$')) { return 'git worktree remove/prune' }
            if ($sub -eq 'reflog' -and ($rest -match '^(expire|delete)$')) { return 'git reflog expire/delete' }
            if ($sub -eq 'config' -and ($rest -match '^alias\.')) { return 'git config alias.*' }
            return $null
        }
        '^(rm|remove-item|ri|del|erase|rd|rmdir)$' {
            if ($name -eq 'rm' -and ($a -cmatch '^-[dfivIR]*[rR][dfivIR]*$' -or $al -contains '--recursive')) { return 'recursive delete (rm -r)' }
            if ($al -match '^-r(e(c(u(r(s(e)?)?)?)?)?)?$' -or $al -contains '/s') { return 'recursive delete' }
            return $null
        }
        '^find$' {
            if ($al -contains '-delete') { return 'find -delete' }
            for ($k = 0; $k -lt $al.Count - 1; $k++) {
                if ($al[$k] -in '-exec', '-execdir', '-ok' -and (Get-Name $al[$k + 1]) -in 'rm', 'shred', 'del') { return 'find -exec rm' }
            }
            return $null
        }
        '^(shred|format|diskpart|format-volume|clear-disk|remove-partition|shutdown|stop-computer|restart-computer|logoff|grok|railway)$' { return $name }
        '^mkfs' { return $name }
        '^dd$' { if ($al -match '^of=') { return 'dd of=' }; return $null }
        '^(npm|pnpm|yarn|bun)$' { if ($al -match '^(publish|unpublish|deprecate)$') { return "$name publish" }; return $null }
        '^cargo$' { if ($al -contains 'publish') { return 'cargo publish' }; return $null }
        '^twine$' { if ($al -contains 'upload') { return 'twine upload' }; return $null }
        '^docker$' { if ($al -contains 'push') { return 'docker push' }; return $null }
        '^vercel$' { if ($al -match '^(--prod|promote|rollback|remove|rm|alias)$') { return 'vercel production/alias change' }; return $null }
        '^supabase$' { if ($al -match '^(push|deploy|reset|delete)$') { return 'supabase push/deploy/reset' }; return $null }
        '^(fly|flyctl|firebase)$' { if ($al -contains 'deploy') { return "$name deploy" }; return $null }
        '^netlify$' { if ($al -contains 'deploy' -and $al -contains '--prod') { return 'netlify deploy --prod' }; return $null }
        '^terraform$' { if ($al -match '^(apply|destroy|import)$') { return 'terraform apply/destroy' }; return $null }
        '^kubectl$' { if ($al -match '^(apply|delete|create|replace|patch|scale|rollout|edit)$') { return 'kubectl write' }; return $null }
        '^gh$' {
            if ($al.Count -eq 0) { return $null }
            if ($al[0] -eq 'api') {
                if ($al -match '^(-x|--method|-f|--field|--raw-field|--input)$') { return 'gh api write' }
                return $null
            }
            if ($al[0] -in 'search', 'status', 'help', 'version', '--version') { return $null }
            if ($al.Count -ge 2 -and $al[1] -in 'view', 'list', 'ls', 'status', 'diff', 'checks', 'watch', 'download') { return $null }
            return "gh $($al[0]) $(if ($al.Count -ge 2) { $al[1] })"
        }
    }
    return $null
}

function Get-Verdict([string]$cmd, [bool]$readOnly) {
    if ($cmd -match $protectedPath) { return 'touches grok config/hooks or this guard' }
    # Harmless redirections (2>&1, >/dev/null, >$null) go first so their `&` isn't read as a separator.
    $cmd = $cmd -replace '\d?>&\d|\d?>\s*(\$null|/dev/null|nul)(?=\s|$|;|\|)', ' '
    if ($readOnly -and $cmd -match '>') { return 'output redirection writes a file' }
    # Quotes are dropped so nested `bash -c "a; b"` / `pwsh -Command "..."` become ordinary segments.
    # A quoted path keeps its spaces joined, so `& "C:\Program Files\Git\bin\git.exe" commit` still reads as git.
    $flat = [regex]::Replace($cmd, '"([^"]*)"|''([^'']*)''', [Text.RegularExpressions.MatchEvaluator] {
            param($m)
            $s = $m.Groups[1].Value + $m.Groups[2].Value
            if ($s -match '^\s*([A-Za-z]:)?[\\/]' -and $s -notmatch '[;&|]|\s-') { ' ' + ($s.Trim() -replace '\s', '_') + ' ' } else { " $s " }
        })
    foreach ($seg in ($flat -split '\r?\n|;|&&|\|\||\||&|\(|\)|\{|\}|`|\$\(')) {
        $tokens = @($seg -split '\s+' | Where-Object { $_ })
        if ($tokens.Count -eq 0) { continue }
        $r = Test-Segment $tokens $readOnly
        if ($r) { return $r }
    }
    return $null
}

if ($PSBoundParameters.ContainsKey('Command')) {
    $r = Get-Verdict $Command ($Level -eq 'plan')
    if ($r) { "DENY: $r" } else { 'ALLOW' }
    exit 0
}

$level = $env:CLAUDE_GROK_GUARD
if ($level -notin 'exec', 'plan') { exit 0 }
$readOnly = $level -eq 'plan'

function Deny([string]$why) {
    $hint = if ($readOnly) { $planHint } else { $guardHint }
    $o = @{ decision = 'deny'; reason = "[grok-exec guard] Blocked: $why.$hint" } | ConvertTo-Json -Compress
    [Console]::Out.Write($o)
    exit 2
}

try {
    [Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
    $raw = [Console]::In.ReadToEnd()
    $evt = $raw | ConvertFrom-Json
    $tool = if ($evt.toolName) { $evt.toolName } else { $evt.tool_name }
    if ($readOnly -and $tool -notmatch '^(run_terminal_command|run_terminal_cmd|Bash)$') { Deny "$tool" }
    $ti = if ($evt.toolInput) { $evt.toolInput } else { $evt.tool_input }
    if (-not $ti) { exit 0 }
    if ($ti.command) {
        if ($evt.toolInputTruncated) { Deny 'command too long for the guard to inspect; split it into smaller commands' }
        $r = Get-Verdict ([string]$ti.command) $readOnly
        if ($r) { Deny $r }
    }
    foreach ($p in $ti.PSObject.Properties) {
        if ($p.Name -match 'path|file' -and $p.Value -is [string] -and $p.Value -match $protectedPath) {
            Deny 'edits grok config/hooks or this guard'
        }
    }
    exit 0
} catch {
    Deny "guard error ($($_.Exception.Message))"
}
