# Offline checks for grok-guard.ps1: no Grok needed.  Run: powershell -File tests\test-guard.ps1
$guard = Join-Path $PSScriptRoot '..\grok-guard.ps1'

$deny = @(
    'git commit -m x'
    'git -C sub/dir commit -m x'
    'git -c user.name=a -C . commit --amend'
    'git --git-dir=.git --work-tree=. push origin main'
    'cd app && git commit -am wip'
    'npm test; git push'
    'bash -c "git status && git commit -m x"'
    'powershell -NoProfile -ExecutionPolicy Bypass -Command "git push"'
    '& "C:\Program Files\Git\bin\git.exe" commit -m x'
    'Start-Process -FilePath git -ArgumentList commit'
    'FOO=1 timeout 30 git push'
    'git -c alias.x=commit x'
    'git reset --hard HEAD~1'
    'git checkout -- src/app.ts'
    'git checkout .'
    'git clean -fdx'
    'git stash'
    'git branch -D feature'
    'git rebase -i main'
    'rm -rf node_modules'
    'rm -r -f build'
    'rm --recursive dist'
    'Remove-Item -Recurse -Force build'
    'Remove-Item build -r'
    'ri -Recurse x'
    'rd /s /q build'
    'cmd /c "rmdir /S /Q build"'
    'find . -name "*.log" -delete'
    'find . -type d -exec rm -rf {} +'
    'ls | xargs rm -rf'
    'npm publish'
    'pnpm publish --access public'
    'vercel --prod'
    'supabase db push'
    'railway up'
    'gh pr create --fill'
    'gh api -X DELETE repos/a/b'
    'grok worktree rm -f x'
    'Set-Content ~/.grok/hooks/claude-grok-skill.json "{}"'
    'echo x > C:\Users\me\.grok\config.toml'
    '$env:CLAUDE_GROK_GUARD="0"; git commit'
    'shutdown /s /t 0'
)
$allow = @(
    'git status'
    'git -C sub diff --stat'
    'git log --oneline --grep commit'
    'git add -A'
    'git checkout -b feature'
    'git branch -d merged-branch'
    'git diff HEAD -- src'
    'npm test'
    'npm run build && npm test'
    'rm -f out.txt'
    'Remove-Item out.txt -Force'
    'rm -Force out.txt'
    'rmdir emptydir'
    'grep -rn "git push" docs'
    'echo "rm -rf is dangerous"'
    'find . -name "*.ts"'
    'gh pr view 12'
    'gh run list'
    'gh api repos/a/b/pulls'
    'dotnet test'
    'python -m pytest -q'
    'cat ~/.grok/sessions/x/summary.json'
)

$fail = 0
foreach ($c in $deny) { $r = & $guard -Command $c; if ($r -notlike 'DENY*') { $fail++; Write-Output "FAIL (should deny): $c -> $r" } }
foreach ($c in $allow) { $r = & $guard -Command $c; if ($r -ne 'ALLOW') { $fail++; Write-Output "FAIL (should allow): $c -> $r" } }

# Plan level: read-only commands only.
$planAllow = @(
    'ls -la src'
    'cat app.js | head -20'
    'git log --oneline -5'
    'git -C sub diff HEAD~1 -- src'
    'git branch -a'
    'git status 2>&1'
    'Get-ChildItem -Recurse src | Select-String foo'
    'rg -n "foo" src'
    'find . -name "*.ts"'
)
$planDeny = @(
    'node -e "console.log(1)"'
    'npm test'
    'git checkout -b x'
    'git branch new-branch'
    'echo hi > out.txt'
    'Set-Content out.txt hi'
    'find . -name "*.log" -delete'
    'python script.py'
    'git add -A'
)
foreach ($c in $planAllow) { $r = & $guard -Command $c -Level plan; if ($r -ne 'ALLOW') { $fail++; Write-Output "FAIL (plan should allow): $c -> $r" } }
foreach ($c in $planDeny) { $r = & $guard -Command $c -Level plan; if ($r -notlike 'DENY*') { $fail++; Write-Output "FAIL (plan should deny): $c -> $r" } }

Write-Output ("{0} cases, {1} failed" -f ($deny.Count + $allow.Count + $planAllow.Count + $planDeny.Count), $fail)
exit [int]($fail -gt 0)
