# claude-grok-skill

A Claude Code skill (`/grok`): **Claude plans and reviews, Grok 4.7 executes.**

Claude writes the task spec → Grok edits code and runs commands headless via the Grok Build CLI →
Claude reviews the files that actually changed on disk and re-runs the checks itself. Grok is
denied commit / push / deploy / recursive delete (deny rules + a gatekeeper hook that checks the
whole command); those stay with Claude after review.

## 安装（Windows）

**1. 安装并登录 Grok Build CLI**（PowerShell）

```powershell
irm https://x.ai/cli/install.ps1 | iex
grok login          # 浏览器登录 grok.com；或者设置环境变量 XAI_API_KEY
grok --version      # 能输出版本号就说明装好了
```

安装脚本会自动把 `%USERPROFILE%\.grok\bin` 加到用户 PATH；装完重开一个终端。

**2. 允许运行本地 PowerShell 脚本**（新装的 Windows 默认是 Restricted，只需执行一次）

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

**3. 把仓库克隆到 Claude Code 的 skills 目录**

```powershell
git clone https://github.com/gibroughtta-maker/claude-grok-skill.git "$HOME\.claude\skills\grok"
```

目标目录必须叫 `grok`，`SKILL.md` 里写死的就是这个路径。

**4. 重启 Claude Code**，输入 `/grok <任务>`，或者直接说"让 Grok 去做 …"。

第一次运行时脚本会自动写入 `~/.grok/hooks/claude-grok-skill.json`（门卫钩子），不用手动配置。
它只在本脚本启动的 Grok 里生效，你自己平时开的 grok 不受影响。

## 更新

```powershell
git -C "$HOME\.claude\skills\grok" pull
```

## 用法

- `/grok 给 xxx 加上分页，验收：npm test 通过`
- 改十几行的小活 Claude 会自己改，不外包。
- 风险高的任务，Claude 会先让 Grok 用 `plan` 模式出方案（只读：不能改文件，只能跑 `ls`/`git log` 这类只读命令），审核通过后再执行。
- 多个任务并行时加 `-Worktree`：每个 Grok 在自己的 git worktree 副本里干活，改了什么用一条 `git diff` 就能看清。用完记得清理：`grok worktree rm -f <id>`，或定期 `grok worktree gc --max-age 7d`，不然 C 盘容易满。
- 运行过程中会实时打印 Grok 在调用的工具；超过 15 分钟没动静会自动杀掉（`-StallMinutes` 可调）。
- 返工时对话太长（默认超过 40 万 token）会自动开新对话，让 Grok 接着磁盘上的半成品干。
- 每次运行的原始日志保存在 `$HOME\.claude\grok\runs\`（不在这个仓库里）。
- 也可以绕过 Claude 直接调用脚本：

  ```powershell
  & "$HOME\.claude\skills\grok\grok-exec.ps1" -Cwd <项目目录> -Task "..." -Mode exec
  # 可选参数：-TaskFile spec.md  -Mode plan  -Worktree  -Resume <sessionId>  -Effort high  -MaxTurns 60
  #          -Model grok-4.7-build-fast  -StallMinutes 30  -MaxResumeTokens 400000  -NoClaudeHooks  -AllowMcp
  ```

## 文件

| 文件 | 作用 |
|---|---|
| `SKILL.md` | 给 Claude 看的流程：写规格 → 风险分级 → 派活 → 挑刺审查 → 结论 |
| `grok-exec.ps1` | 无界面调用 Grok 的包装脚本：禁止危险操作、实时输出进度、卡死自动终止、可选独立 worktree、独立统计磁盘上的文件改动、保存日志 |
| `grok-guard.ps1` | 门卫钩子：每条命令执行前检查完整内容（`git -C x commit` 这类绕过写法也拦得住）；plan 模式下只放行只读命令 |
| `GOTCHAS.md` | 踩坑记录，出问题时再看 |
| `tests/test-guard.ps1` | 门卫的离线测试：`powershell -File tests\test-guard.ps1` |

依赖：Windows PowerShell 5.1+、Grok Build CLI（`grok` 在 PATH 里）、git（用于 diff 审查和 `-Worktree`）。

真正的系统级沙箱（`grok --sandbox`）只支持 macOS / Linux；Windows 上想要的话得在 WSL 里跑 Grok，这里没有配置。
