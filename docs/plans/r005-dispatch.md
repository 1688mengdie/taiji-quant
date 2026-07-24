# R-005 派发指令

> 设计文档：[r005-design.md](r005-design.md) | 需求文档：[r005-requirements.md](r005-requirements.md)
>
> 执行者：姬码锋 | 审批者：姬梦情

---

## 任务总览

| R-ID | 简述 | Wave | 依赖 |
|------|------|------|------|
| R5.1 | 重写 sync-upstream.ps1（robocopy → git merge） | Wave 1 | - |
| R5.2 | 创建 .gitattributes（元数据 merge=ours） | Wave 1 | - |
| R5.3 | 首次 git merge upstream/main | Wave 2 | R5.1, R5.2 |
| R5.4 | 冲突裁决（手动处理 merge conflicts） | Wave 2 | R5.3 |
| R5.5 | cargo check + test 全编译验证 | Wave 2 | R5.4 |
| R5.6 | git commit + push origin/master | Wave 2 | R5.5 |

**执行顺序**：Wave 1（并行）→ Wave 2（串行）

---

## Wave 1（全并行执行）

### R5.1：重写 sync-upstream.ps1（robocopy → git merge）

**姬码锋执行任务**

#### 背景

当前 sync-upstream.ps1 使用 taiji 工作空间（`E:\finance-trading\lvpa\software\taiji`）作为中转：先 rebase taiji 到最新 upstream，再 robocopy 文件到 taiji-quant。此方案存在以下问题：

1. **多余中转**：taiji-quant 已有 `upstream` remote 直连 `GCWing/BitFun`，无需通过 taiji 空间中转。
2. **文件级拷贝丢失 Git 历史**：robocopy 只复制文件，不保留 commit 历史。
3. **robocopy 不可靠**：排除目录拼写错误、路径过长截断等问题已多次导致同步失败。

**新策略**：直接 `git merge upstream/main --no-commit`，让 Git 处理文件变更，然后在提交前恢复 taiji-quant 元数据。

#### 文件列表

| 文件 | 操作 |
|------|------|
| `E:\finance-trading\lvpa\software\taiji-quant\scripts\sync-upstream.ps1` | **完整重写**（199行 → 新版本） |

#### 先读取

```
已读取 sync-upstream.ps1 全文（L1-L199），见对话上下文。
确认关键信息：
  - taiji-quant upstream remote: https://github.com/GCWing/BitFun.git
  - 闭源 crate: taiji-dvmi, taiji-magnet, taiji-thrust, taiji-risk
  - 元数据恢复规则: Cargo.toml (version→0.1.0, authors→Taiji Quant Team), package.json (name→taiji-quant, version→0.1.0)
  - 当前分支: master
```

#### 改动步骤

**完整重写**：用 Write 工具覆盖 `scripts/sync-upstream.ps1`，内容如下：

```powershell
# sync-upstream.ps1 — 从 GCWing/BitFun upstream 同步到 taiji-quant 开源基座（git merge 策略）
#
# 新版策略：直接 git merge upstream/main（不再通过 taiji 工作空间中转 robocopy）
#
# 工作流:
#   1. 检查工作区状态（必须干净）
#   2. Fetch upstream/main
#   3. 计算增量 commit
#   4. git merge upstream/main --no-commit（冲突时退出，手工裁决后重跑）
#   5. 恢复 taiji-quant 元数据（Cargo.toml: version/authors, package.json: name/version）
#   6. 排除闭源 crate（taiji-dvmi, taiji-magnet, taiji-thrust, taiji-risk）
#   7. cargo check + test 验证
#   8. git commit + push origin/master
#
# 用法:
#   .\scripts\sync-upstream.ps1
#   .\scripts\sync-upstream.ps1 -SkipBuild      # 跳过编译验证
#   .\scripts\sync-upstream.ps1 -DryRun         # 演示模式，不实际执行
#   .\scripts\sync-upstream.ps1 -ContinueMerge  # 冲突解决后继续（跳过 merge 步骤）
#
param(
    [string]$TaijiQuantWorkspace = "E:\finance-trading\lvpa\software\taiji-quant",
    [string]$SyncStateFile = "E:\finance-trading\lvpa\software\taiji-quant\.sync-upstream-state.json",
    [string]$UpstreamRemote = "upstream",
    [string]$UpstreamBranch = "main",
    [switch]$SkipBuild,
    [switch]$DryRun,
    [switch]$ContinueMerge
)

$ErrorActionPreference = "Stop"

# ── 常量 ────────────────────────────────────────────────────────────
$ClosedCrates = @("taiji-dvmi", "taiji-magnet", "taiji-thrust", "taiji-risk")
$ClosedCrateBase = "src\crates\taiji"

function Write-Step { param([string]$Msg) Write-Host "`n=== $Msg ===" -ForegroundColor Cyan }
function Write-Info { param([string]$Msg) Write-Host "  $Msg" }
function Write-Warn { param([string]$Msg) Write-Host "  WARNING: $Msg" -ForegroundColor Yellow }
function Write-Err  { param([string]$Msg) Write-Host "  ERROR: $Msg" -ForegroundColor Red }

# ══════════════════════════════════════════════════════════════════════
# Step 0: 读取同步状态
# ══════════════════════════════════════════════════════════════════════
Write-Step "Step 0: 读取同步状态"
$lastSyncCommit = $null
if (Test-Path $SyncStateFile) {
    $state = Get-Content $SyncStateFile -Raw | ConvertFrom-Json
    $lastSyncCommit = $state.last_synced_commit
    Write-Info "上次同步点: $lastSyncCommit (策略: $($state.strategy))"
} else {
    Write-Info "首次同步，无历史记录"
}

# ══════════════════════════════════════════════════════════════════════
# Step 1: Check workspace + upstream remote
# ══════════════════════════════════════════════════════════════════════
Write-Step "Step 1: 环境检查"
Push-Location $TaijiQuantWorkspace
try {
    # 1a. 工作区干净？
    $dirty = git status --porcelain
    if ($dirty) {
        Write-Err "工作区不干净，无法执行同步。请先提交或 stash 变更。"
        Write-Info "变更文件:"
        Write-Host $dirty
        exit 1
    }
    Write-Info "工作区干净"

    # 1b. 在 master 分支？
    $branch = git branch --show-current
    if ($branch -ne "master") {
        Write-Warn "当前分支 '$branch' 非 master。同步应在 master 上执行。"
    }

    # 1c. upstream remote 正确？
    $upstreamUrl = git remote get-url $UpstreamRemote 2>$null
    if (-not $upstreamUrl -or $upstreamUrl -notmatch "GCWing/BitFun") {
        Write-Err "upstream remote 未正确配置。期望: GCWing/BitFun, 实际: $upstreamUrl"
        exit 1
    }
    Write-Info "upstream: $upstreamUrl"
} finally {
    Pop-Location
}

# ══════════════════════════════════════════════════════════════════════
# Step 2: Fetch upstream
# ══════════════════════════════════════════════════════════════════════
Write-Step "Step 2: Fetch upstream"
Push-Location $TaijiQuantWorkspace
try {
    git fetch $UpstreamRemote $UpstreamBranch 2>&1 | Out-Null
    $upstreamHead = git rev-parse "$UpstreamRemote/$UpstreamBranch"
    Write-Info "upstream/$UpstreamBranch HEAD: $upstreamHead"
    Write-Info "本地 HEAD: $(git rev-parse HEAD)"

    $mergeBase = git merge-base HEAD "$UpstreamRemote/$UpstreamBranch"
    if ($mergeBase -eq $upstreamHead) {
        Write-Info "taiji-quant 已是最新，无需同步"
        exit 0
    }
} finally {
    Pop-Location
}

# ══════════════════════════════════════════════════════════════════════
# Step 3: 计算增量
# ══════════════════════════════════════════════════════════════════════
Write-Step "Step 3: 计算增量 commit"
$newCommits = git -C $TaijiQuantWorkspace log "$mergeBase..$upstreamHead" --oneline
if (-not $newCommits -or $newCommits.Count -eq 0) {
    Write-Info "无新增 commit，taiji-quant 已是最新"
    exit 0
}
$commitCount = if ($newCommits -is [array]) { $newCommits.Count } else { 1 }
Write-Info "新增 $commitCount 个 commit（$mergeBase → $upstreamHead）:"
$newCommits | ForEach-Object { Write-Host "    $_" }

# ══════════════════════════════════════════════════════════════════════
# Step 4: git merge（--no-commit，冲突时需手工裁决）
# ══════════════════════════════════════════════════════════════════════
if (-not $ContinueMerge) {
    Write-Step "Step 4: git merge upstream/$UpstreamBranch --no-commit"
    Push-Location $TaijiQuantWorkspace
    try {
        if ($DryRun) {
            Write-Info "[DRY RUN] 冲突预测模式 — 模拟 merge 评估冲突量，不实际修改工作区"
            $dryRunResult = git merge "$UpstreamRemote/$UpstreamBranch" --no-commit --no-edit 2>&1
            if ($LASTEXITCODE -ne 0) {
                $conflictFiles = git diff --name-only --diff-filter=U
                $conflictCount = ($conflictFiles | Where-Object { $_ -ne "" } | Measure-Object).Count
                Write-Warn "预测冲突文件数: $conflictCount"
                if ($conflictCount -gt 0) {
                    Write-Info "冲突文件列表:"
                    $conflictFiles | ForEach-Object { if ($_) { Write-Host "    $_" } }
                }
                Write-Info "已执行 git merge --abort 回滚"
                git merge --abort 2>$null
            } else {
                Write-Info "预测结果: 无冲突，可安全执行正式 merge"
                git merge --abort 2>$null
            }
        } else {
            $mergeOutput = git merge "$UpstreamRemote/$UpstreamBranch" --no-commit --no-edit 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Err "Merge 冲突！"
                Write-Info ""
                Write-Info "══════════════════════════════════════════════"
                Write-Info "  冲突裁决流程（见 R5.4）:"
                Write-Info "  1. git diff --name-only --diff-filter=U  查看冲突文件"
                Write-Info "  2. 逐个文件解决冲突"
                Write-Info "  3. git add <resolved-files>"
                Write-Info "  4. 重新运行: .\scripts\sync-upstream.ps1 -ContinueMerge"
                Write-Info "══════════════════════════════════════════════"
                Write-Info ""
                Write-Info "冲突文件列表:"
                git diff --name-only --diff-filter=U
                exit 1
            }
            Write-Info "Merge 成功（未提交）"
        }
    } finally {
        Pop-Location
    }
} else {
    Write-Step "Step 4: 跳过 merge（-ContinueMerge 模式，冲突已手工解决）"
    Write-Info "请确认所有冲突已解决（git diff --check 无输出）"
}

# ══════════════════════════════════════════════════════════════════════
# Step 5: 恢复 taiji-quant 元数据
# ══════════════════════════════════════════════════════════════════════
Write-Step "Step 5: 恢复 taiji-quant 元数据"
if (-not $DryRun) {
    Push-Location $TaijiQuantWorkspace

    # 优先使用 git checkout --ours 恢复元数据文件（利用 .gitattributes merge=ours）
    # 若 merge 冲突已解决，"--ours" 无效，则用内容替换兜底
    git checkout --ours Cargo.toml 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Info "Cargo.toml 已从 ours 恢复（merge 驱动）"
    }

    git checkout --ours package.json 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Info "package.json 已从 ours 恢复（merge 驱动）"
    }

    # 兜底：确保值正确（正则替换）
    $cargoPath = Join-Path $TaijiQuantWorkspace "Cargo.toml"
    $cargo = Get-Content $cargoPath -Raw
    $cargo = $cargo -replace '(?m)^version\s*=\s*".*"', 'version = "0.1.0"'
    $cargo = $cargo -replace '(?m)^authors\s*=\s*\[.*\]', 'authors = ["Taiji Quant Team"]'
    [System.IO.File]::WriteAllText($cargoPath, $cargo, [System.Text.UTF8Encoding]::new($false))

    $pkgPath = Join-Path $TaijiQuantWorkspace "package.json"
    $pkg = Get-Content $pkgPath -Raw
    $pkg = $pkg -replace '"name"\s*:\s*".*"', '"name": "taiji-quant"'
    $pkg = $pkg -replace '"version"\s*:\s*".*"', '"version": "0.1.0"'
    [System.IO.File]::WriteAllText($pkgPath, $pkg, [System.Text.UTF8Encoding]::new($false))

    Write-Info "Cargo.toml + package.json 元数据已恢复（taiji-quant 身份）"
    Pop-Location
} else {
    Write-Info "[DRY RUN] 跳过元数据恢复"
}

# ══════════════════════════════════════════════════════════════════════
# Step 6: 排除闭源 crate
# ══════════════════════════════════════════════════════════════════════
Write-Step "Step 6: 排除闭源 crate"
if (-not $DryRun) {
    foreach ($crate in $ClosedCrates) {
        $cratePath = Join-Path $TaijiQuantWorkspace "$ClosedCrateBase\$crate"
        if (Test-Path $cratePath) {
            Remove-Item -Recurse -Force $cratePath
            Write-Info "已删除闭源目录: src/crates/taiji/$crate"
        }
    }

    # 确保 Cargo.toml workspace.members 中闭源项保持注释
    $cargoPath = Join-Path $TaijiQuantWorkspace "Cargo.toml"
    $cargo = Get-Content $cargoPath -Raw
    foreach ($crate in $ClosedCrates) {
        # 如果 upstream 新增了未注释的闭源 member 行，注释掉
        $escaped = [regex]::Escape("""src/crates/taiji/$crate""")
        $cargo = $cargo -replace "(?m)^(\s*)($escaped)(,?\s*)$", '${1}# ${2}  # 闭源：同步排除'
    }
    [System.IO.File]::WriteAllText($cargoPath, $cargo, [System.Text.UTF8Encoding]::new($false))
    Write-Info "Cargo.toml workspace.members 闭源项已确保注释"
} else {
    Write-Info "[DRY RUN] 跳过闭源排除"
}

# ══════════════════════════════════════════════════════════════════════
# Step 7: pnpm-lock.yaml + Cargo.lock 恢复（ours）
# ══════════════════════════════════════════════════════════════════════
Write-Step "Step 7: 恢复锁文件（ours）"
if (-not $DryRun) {
    Push-Location $TaijiQuantWorkspace
    git checkout --ours pnpm-lock.yaml 2>$null
    git checkout --ours Cargo.lock 2>$null
    Write-Info "pnpm-lock.yaml + Cargo.lock 已保持本地版本"
    Pop-Location
} else {
    Write-Info "[DRY RUN] 跳过锁文件恢复"
}

# ══════════════════════════════════════════════════════════════════════
# Step 8: 保存同步状态
# ══════════════════════════════════════════════════════════════════════
Write-Step "Step 8: 保存同步状态"
if (-not $DryRun) {
    $state = @{
        last_synced_commit = $upstreamHead
        synced_at          = (Get-Date -Format "yyyy-MM-ddTHH:mm:sszzz")
        commit_count       = $commitCount
        strategy           = "git-merge"
    }
    $state | ConvertTo-Json -Compress | Set-Content $SyncStateFile -Encoding UTF8
    Write-Info "已保存: last_synced_commit = $upstreamHead"
} else {
    Write-Info "[DRY RUN] 跳过状态保存"
}

# ══════════════════════════════════════════════════════════════════════
# Step 9: 编译验证
# ══════════════════════════════════════════════════════════════════════
if (-not $SkipBuild -and -not $DryRun) {
    Write-Step "Step 9: 编译验证"
    Push-Location $TaijiQuantWorkspace

    $failed = $false
    $env:OPENSSL_DIR = "C:\Program Files\PostgreSQL\17"

    # 9a. Rust
    Write-Info "[1/3] cargo check --workspace..."
    cargo check --workspace 2>&1 | Select-Object -Last 8
    if ($LASTEXITCODE -ne 0) {
        Write-Err "cargo check 失败！"
        $failed = $true
    }

    # 9b. Rust 测试
    Write-Info "[2/3] cargo test --workspace..."
    cargo test --workspace 2>&1 | Select-Object -Last 12
    if ($LASTEXITCODE -ne 0) {
        Write-Err "cargo test 失败！"
        $failed = $true
    }

    # 9c. 前端
    Write-Info "[3/3] pnpm run type-check:web..."
    pnpm run type-check:web 2>&1 | Select-Object -Last 5
    if ($LASTEXITCODE -ne 0) {
        Write-Err "前端类型检查失败！"
        $failed = $true
    }

    if ($failed) {
        Write-Err "编译验证不通过！请排查上游变更兼容性后重新同步。"
        exit 1
    }
    Write-Info "全编译验证通过"

    Pop-Location
} elseif ($DryRun) {
    Write-Info "[DRY RUN] 跳过编译验证"
} else {
    Write-Info "跳过编译验证（-SkipBuild）"
}

# ══════════════════════════════════════════════════════════════════════
# Step 10: git commit + push
# ══════════════════════════════════════════════════════════════════════
if (-not $DryRun) {
    Write-Step "Step 10: 提交并推送"
    Push-Location $TaijiQuantWorkspace
    try {
        $dateStr = Get-Date -Format 'yyyy-MM-dd'
        $commitMsg = "sync: upstream $dateStr — $commitCount commits from GCWing/BitFun main"
        git add -A
        git commit -m $commitMsg 2>&1 | Out-Null
        Write-Info "已提交: $commitMsg"

        git push origin master 2>&1 | Out-Null
        Write-Info "已推送到 origin/master"
    } finally {
        Pop-Location
    }
} elseif ($DryRun) {
    Write-Info "[DRY RUN] git commit + push origin master"
}

Write-Host "`n=== 同步完成 ===" -ForegroundColor Green
```

#### 改动摘要（与旧版对比）

| 旧版逻辑 | 新版逻辑 |
|---------|---------|
| Step 1: 进入 taiji 工作空间 rebase | **删除**。不再通过 taiji 空间中转 |
| Step 2: 计算增量 commit | 保留，逻辑不变 |
| Step 3: robocopy 文件 | **替换**为 `git merge upstream/main --no-commit` |
| Step 4: 恢复元数据 | 保留，增强为 `git checkout --ours` + 正则兜底 |
| Step 5: 保存状态 | 保留，新增 `strategy` 字段 |
| Step 6: cargo check + test | 保留，扩展为全 workspace test |
| Step 7: commit + push | 保留 |
| — taiji 工作空间参数 | **删除**。不再需要 |
| — push mengdie | **删除**。不再需要 |
| — robocopy /XD 排除 | **删除**。用 Step 6 文件系统删除替代 |
| **新增** Step 1: 环境检查 | 工作区干净 / 分支 / upstream remote 验证 |
| **新增** Step 7: 锁文件恢复 | pnpm-lock.yaml + Cargo.lock 保持 ours |
| **新增** -ContinueMerge | 冲突解决后从 Step 5 继续 |

#### 验证命令

```powershell
# 语法检查
Get-Command E:\finance-trading\lvpa\software\taiji-quant\scripts\sync-upstream.ps1

# DryRun 模式（不执行实际操作）
.\scripts\sync-upstream.ps1 -DryRun
```

---

### R5.2：创建 .gitattributes（元数据 merge=ours）

**姬码锋执行任务**

#### 背景

`git merge upstream/main` 时，上游的 Cargo.toml（`version = "0.2.x"`, `authors = ["BitFun Team"]`）和 package.json（`"name": "BitFun"`, `"version": "0.2.x"`）会与 taiji-quant 本地版本冲突。

解决方案：配置 `.gitattributes` 让这些文件在 merge 时始终保留本地（ours）版本，避免反复出现冲突。

#### 文件列表

| 文件 | 操作 |
|------|------|
| `E:\finance-trading\lvpa\software\taiji-quant\.gitattributes` | **新建** |
| `E:\finance-trading\lvpa\software\taiji-quant\.git\config` | 1 处 `git config` 命令 |

#### 改动步骤

**编辑1**：新建 `.gitattributes`（当前文件不存在，用 Write 创建）。

内容：

```
# taiji-quant 元数据保护：merge 时始终保留本地（taiji-quant）版本
Cargo.toml merge=ours
package.json merge=ours

# lock 文件保留本地版本（merge=ours），合并后需重新生成
#   - Cargo.lock: merge 后执行 `cargo generate-lockfile`
#   - pnpm-lock.yaml: merge 后执行 `pnpm install --no-frozen-lockfile`
pnpm-lock.yaml merge=ours
Cargo.lock merge=ours
```

**编辑2**：配置 git merge driver（一次性设置）。

```powershell
git -C "E:\finance-trading\lvpa\software\taiji-quant" config merge.ours.driver true
```

> **原理**：`merge.ours.driver true` 告诉 Git：当匹配 `merge=ours` 的文件发生冲突时，执行 `true` 命令（exit 0，不修改文件内容），即**保留工作树中的当前版本不变**。

#### 验证命令

```powershell
# 确认 .gitattributes 存在
Test-Path "E:\finance-trading\lvpa\software\taiji-quant\.gitattributes"

# 确认 merge driver 已配置
git -C "E:\finance-trading\lvpa\software\taiji-quant" config merge.ours.driver

# 应输出: true
```

---

## Wave 2（串行执行，依赖 Wave 1 全部完成）

⚠️ **必须 R5.1（脚本重写）+ R5.2（.gitattributes）全部完成后才能开始此阶段。**

### R5.3：首次 git merge upstream/main

**姬码锋执行任务**

#### 背景

R5.1 和 R5.2 已完成的前置条件下，执行首次 `sync-upstream.ps1`。脚本直接在 master 分支上执行 `git merge upstream/main`（单分支策略），merge commit 自身即可追溯上游来源。

#### 执行命令

```powershell
cd E:\finance-trading\lvpa\software\taiji-quant

# 0. DryRun 冲突预测（先评估冲突量再决定是否执行）
.\scripts\sync-upstream.ps1 -DryRun

# 1. 确认 DryRun 输出中冲突文件数可控后，正式执行
.\scripts\sync-upstream.ps1
```

#### 预期结果

- **无冲突**：脚本顺利完成 merge + 元数据恢复 + 编译验证，直接进入 R5.5。
- **有冲突**：脚本在 Step 4 退出并打印冲突文件列表，进入 R5.4 冲突裁决。

#### 验证命令

```powershell
# 查看 merge 状态（若脚本在 Step 4 退出）
git -C "E:\finance-trading\lvpa\software\taiji-quant" status
git -C "E:\finance-trading\lvpa\software\taiji-quant" diff --name-only --diff-filter=U
```

---

### R5.4：冲突裁决（仅在 R5.3 merge 冲突时执行）

**姬码锋执行任务**（可请求人工辅助判断）

#### 裁决原则

| 冲突场景 | 裁决原则 | 操作 |
|---------|---------|------|
| taiji 定制 vs 上游重构（同一段逻辑） | **保留 taiji 定制**，手动 review 上游重构是否可吸收 | `git checkout --ours` 然后逐块评估 |
| taiji 新增文件 vs 上游同名文件 | **保留 taiji 文件**（上游不可能有 taiji crate 的合法覆盖） | `git checkout --ours` |
| 上游新增功能 vs taiji 空白（未改动区域） | **接受上游** | `git checkout --theirs` |
| taiji 删除 vs 上游修改（同一区域） | **接受上游修改**（taiji 删除的东西被上游改了，说明仍需要） | `git checkout --theirs` |
| 两边都是格式/导入变更 | **接受上游**（减少无意义差异） | `git checkout --theirs` |
| 闭源 trait 实现文件（共享 crate 中 `impl Xxx for Yyy`） | **保留 taiji**（这些是实现闭源逻辑的关键） | `git checkout --ours` |

| 文件类别 | 裁决策略 | 说明 |
|---------|---------|------|
| `Cargo.toml` | **ours** | taiji-quant 版本号/作者/workspace.members 保留 |
| `package.json` | **ours** | taiji-quant name/version/scripts 保留 |
| `pnpm-lock.yaml` | **ours** | 本地依赖树，merge 后 `pnpm install --no-frozen-lockfile` 重新生成 |
| `Cargo.lock` | **ours** | 本地依赖树，merge 后 `cargo generate-lockfile` 重新生成 |
| `AGENTS.md` | **ours** | taiji-quant 治理规则保留 |
| `README.md` | **ours** | taiji-quant 品牌保留 |
| `LICENSE` | **ours** | MIT 不变 |
| `src/crates/taiji/*` | **ours** | taiji 独有 crate，上游变更不可接受 theirs |
| 其余文件 | **theirs** | 接收上游变更 |

#### 执行步骤

```powershell
# 1. 查看冲突文件列表
git -C "E:\finance-trading\lvpa\software\taiji-quant" diff --name-only --diff-filter=U

# 2. 对于 "ours" 策略的文件：直接 checkout 本地版本
git -C "E:\finance-trading\lvpa\software\taiji-quant" checkout --ours Cargo.toml
git -C "E:\finance-trading\lvpa\software\taiji-quant" checkout --ours package.json
git -C "E:\finance-trading\lvpa\software\taiji-quant" checkout --ours pnpm-lock.yaml
git -C "E:\finance-trading\lvpa\software\taiji-quant" checkout --ours Cargo.lock
git -C "E:\finance-trading\lvpa\software\taiji-quant" checkout --ours AGENTS.md
git -C "E:\finance-trading\lvpa\software\taiji-quant" checkout --ours README.md
git -C "E:\finance-trading\lvpa\software\taiji-quant" checkout --ours LICENSE

# 3. 对于 "theirs" 策略的文件：checkout 上游版本
#    逐文件执行 git checkout --theirs <file>

# 4. 标记已解决
git -C "E:\finance-trading\lvpa\software\taiji-quant" add <resolved-file>

# 5. 产出冲突裁决记录
# 5a. 创建冲突裁决 SOP（若不存在）
#     内容见 r005-requirements.md R5.4.2：
#       - 识别冲突文件方法
#       - 逐文件分类（ours/theirs/manual）
#       - 裁决检查清单（3 问）
#       - 裁决后验证命令
New-Item -ItemType File -Force -Path "E:\finance-trading\lvpa\software\taiji-quant\docs\plans\r005-merge-conflict-sop.md"

# 5b. 追加本次冲突裁决日志
$logEntry = @"
## $(Get-Date -Format 'yyyy-MM-dd')
- 冲突文件数: $(git diff --name-only --diff-filter=U | Measure-Object | Select-Object -ExpandProperty Count)
- 裁决分布: ours=X, theirs=Y, manual=Z
- 耗时: TBD
"@
Add-Content -Path "E:\finance-trading\lvpa\software\taiji-quant\docs\reports\merge-conflict-log.md" -Value $logEntry

# 6. 全部解决后，继续脚本（跳过 merge 步骤）
cd E:\finance-trading\lvpa\software\taiji-quant
.\scripts\sync-upstream.ps1 -ContinueMerge
```

#### 验证命令

```powershell
# 确认无未解决冲突
git -C "E:\finance-trading\lvpa\software\taiji-quant" diff --check

# 确认冲突文件列表为空
git -C "E:\finance-trading\lvpa\software\taiji-quant" diff --name-only --diff-filter=U
```

---

### R5.5：cargo check + test 全编译验证

**姬码锋执行任务**

> 若 R5.4 执行了 `-ContinueMerge`，脚本已自动执行编译验证（Step 9）。本步骤为**独立复查**。

#### 执行命令

```powershell
cd E:\finance-trading\lvpa\software\taiji-quant

# 1. Rust 全量编译检查
$env:OPENSSL_DIR = "C:\Program Files\PostgreSQL\17"
cargo check --workspace

# 2. Rust 全量测试
cargo test --workspace

# 3. 前端类型检查
pnpm run type-check:web
```

#### 预期结果

三项全部通过（exit code 0）。

#### 失败处理

- `cargo check` 失败：检查上游新增/修改的 crate 是否破坏了 taiji-quant 的开源 crate 兼容性。通常需要更新 `Cargo.toml` 依赖版本或适配 API 变更。
- `cargo test` 失败：同上，排查测试用例。
- `pnpm type-check:web` 失败：检查上游前端类型变更是否与 taiji-quant 前端适配。

---

### R5.6：git commit + push origin/master

**姬码锋执行任务**

> 若通过脚本执行（无 `-SkipBuild`），提交和推送已在 Step 10 自动完成。本步骤为**手动复查 + 兜底**。

#### 执行命令

```powershell
cd E:\finance-trading\lvpa\software\taiji-quant

# 1. 确认 merge 状态正常（应处于 "all conflicts fixed" 或 "nothing to commit"）
git status

# 2. 若脚本未自动提交，手动提交
$dateStr = Get-Date -Format 'yyyy-MM-dd'
$count = git log --oneline (git merge-base HEAD upstream/main)..HEAD 2>$null | Measure-Object | Select-Object -ExpandProperty Count
$commitMsg = "sync: upstream $dateStr — ~$count commits from GCWing/BitFun main"
git add -A
git commit -m $commitMsg

# 3. 推送
git push origin master
```

#### 验证命令

```powershell
# 确认已推送到 origin
git -C "E:\finance-trading\lvpa\software\taiji-quant" log origin/master --oneline -3

# 确认 .sync-upstream-state.json 已更新
Get-Content "E:\finance-trading\lvpa\software\taiji-quant\.sync-upstream-state.json" | ConvertFrom-Json | Format-List
```

---

## 全量验收标准

| R-ID | 验收标准 |
|------|----------|
| R5.1 | 新 sync-upstream.ps1 通过 `-DryRun` 模式语法检查且流程正确；不再引用 taiji 工作空间路径；不再调用 robocopy；使用 `git merge --no-commit` |
| R5.2 | `.gitattributes` 存在且配置了 `Cargo.toml`/`package.json`/`pnpm-lock.yaml`/`Cargo.lock` 的 `merge=ours`；`merge.ours.driver=true` 已配置 |
| R5.3 | `git merge upstream/main` 成功或明确列出冲突文件 |
| R5.4 | 所有冲突按裁决表正确解决（ours 文件用本地版本，theirs 文件用上游版本）；`git diff --check` 无输出 |
| R5.5 | `cargo check --workspace` + `cargo test --workspace` + `pnpm run type-check:web` 全部通过 |
| R5.6 | 合并提交已推送到 `origin/master`；`.sync-upstream-state.json` 记录最新 upstream commit |
