# AGENTS.md — taiji-quant

太极量化交易 + 自媒体工厂开源基座。MIT License。独立于 BitFun 的完整产品。

## 仓库

- GitHub: `1688mengdie/taiji-quant` (PUBLIC)
- 本地: `E:\finance-trading\lvpa\software\taiji-quant`
- 上游来源: `GCWing/BitFun` main 分支

## GitHub 开源治理

### 铁律

1. **master 分支不直接 push 代码改动。** 唯一例外：`scripts/sync-upstream.ps1` 的上游同步。
2. **所有功能 / bugfix 走完整 Issue → PR 流程。**
3. **PR 标题遵循 conventional commits：** `feat:` / `fix:` / `chore:` / `docs:` / `refactor:`
4. **合并方式：Squash Merge。** 保持 master 历史干净。
5. **闭源代码绝不入库。** taiji-dvmi / taiji-magnet / taiji-thrust / taiji-risk 在同步时自动排除。

### 标准工作流

```powershell
# 1. 创建 Issue
gh issue create --title "feat: 功能描述" --body "## 需求描述`n`n## 验收标准`n`n- [ ] ..."

# 2. 从 master 切分支
git checkout master
git pull origin master
git checkout -b feat/功能名

# 3. 开发 + 提交
git add -A
git commit -m "feat: 功能描述"

# 4. 推送 + 创建 PR
git push origin feat/功能名
gh pr create --base master --head feat/功能名 --title "feat: 功能描述" --body "Closes #N"

# 5. 自查通过后合并
cargo check --workspace
gh pr merge feat/功能名 --squash --delete-branch

# 6. 回到 master
git checkout master
git pull origin master
```

### 上游同步（唯一允许直接写 master 的场景）

```powershell
.\scripts\sync-upstream.ps1
```

### 分支命名

- `feat/xxx` — 新功能
- `fix/xxx` — Bug 修复
- `chore/xxx` — 工程化
- `docs/xxx` — 文档
- `refactor/xxx` — 重构

## 编译验证

| 变更类型 | 最小验证 |
|---------|---------|
| Rust crate | `cargo check --workspace` |
| 前端 (web-ui) | `pnpm run type-check:web` |
| 前端 (mobile-web) | `pnpm --dir src/mobile-web run type-check` |
| 全栈 | `cargo check --workspace` + `pnpm run build:web` |

## 闭源代码隔离

以下 crate 为闭源，**不存在于本仓库**：
- `taiji-dvmi` — 拐点 + 双线三态
- `taiji-magnet` — 磁体定位
- `taiji-thrust` — 三推检测
- `taiji-risk` — 风控规则 + 参数

开源 trait 在 `taiji-engine` 中定义，闭源策略通过 trait 实现注入。
