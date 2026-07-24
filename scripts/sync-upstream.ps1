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
    cmd /c "git fetch $UpstreamRemote $UpstreamBranch 2>&1" | Out-Null
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
        $pattern = "(?m)^(\s*)($escaped)(,?\s*)" + '$'
        $cargo = $cargo -replace $pattern, '${1}# ${2}  # 闭源：同步排除'
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
