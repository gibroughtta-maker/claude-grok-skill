# claude-grok-skill

A Claude Code skill (`/grok`): **Claude plans and reviews, Grok 4.7 executes.**

Claude writes the task spec → Grok edits code and runs commands headless via the Grok Build CLI →
Claude reviews the files that actually changed on disk and re-runs the checks itself. Grok is
denied commit / push / deploy / recursive delete; those stay with Claude after review.

## 安装（Windows）

**1. 安装并登录 Grok Build CLI**（在 Git Bash 里执行）

```bash
curl -fsSL https://x.ai/cli/install.sh | bash
grok login          # 浏览器登录 grok.com；或者设置环境变量 XAI_API_KEY
grok --version      # 能输出版本号就说明装好了
```

如果 PowerShell 里找不到 `grok`，把 `%USERPROFILE%\.grok\bin` 加到用户 PATH。

**2. 允许运行本地 PowerShell 脚本**（新装的 Windows 默认是 Restricted，只需执行一次）

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

**3. 把仓库克隆到 Claude Code 的 skills 目录**（PowerShell）

```powershell
git clone https://github.com/gibroughtta-maker/claude-grok-skill.git "$HOME\.claude\skills\grok"
```

目标目录必须叫 `grok`，`SKILL.md` 里写死的就是这个路径。

**4. 重启 Claude Code**，输入 `/grok <任务>`，或者直接说"让 Grok 去做 …"。

## 更新

```powershell
git -C "$HOME\.claude\skills\grok" pull
```

## 用法

- `/grok 给 xxx 加上分页，验收：npm test 通过`
- 风险高的任务，Claude 会先让 Grok 用 `plan` 模式出方案，审核通过后再执行。
- 每次运行的原始 JSON 日志保存在 `$HOME\.claude\grok\runs\`（不在这个仓库里）。
- 也可以绕过 Claude 直接调用脚本：

  ```powershell
  & "$HOME\.claude\skills\grok\grok-exec.ps1" -Cwd <项目目录> -Task "..." -Mode exec
  # 可选参数：-TaskFile spec.md  -Mode plan  -Resume <sessionId>  -Effort high  -MaxTurns 60  -Model grok-4.7-build-fast
  ```

## 文件

| 文件 | 作用 |
|---|---|
| `SKILL.md` | 给 Claude 看的流程：写规格 → 风险分级 → 派活 → 挑刺审查 → 结论 |
| `grok-exec.ps1` | 无界面调用 Grok 的包装脚本：禁止危险操作、独立统计磁盘上的文件改动、保存日志 |

依赖：Windows PowerShell 5.1+、Grok Build CLI（`grok` 在 PATH 里）、git（用于 diff 审查，可选）。
