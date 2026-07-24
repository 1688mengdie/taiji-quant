# R-005 设计方案：上游同步策略重构 — robocopy → git merge

> 派生自：R-005 需求矩阵
> 设计原则：用 git merge 替代 robocopy 文件拷贝，打通 git 历史血缘，冲突可见可追溯。

---

## 架构决策

| ID | 决策 | 理由 | 备选方案 |
|----|------|------|----------|
| AD1 | **git merge 替代 robocopy** | robocopy 不理解 git 冲突，盲覆盖共享 crate 中的 taiji 定制，且丢失上游历史血缘。git merge 利用 3-way merge 自动处理无冲突变更，冲突时显式标注 `<<<<<<<` / `>>>>>>>`，可逐文件裁决 | 继续用 robocopy + 手动 diff 对比（现状，不可持续）；rsync + patch（无历史血缘，无冲突标注） |
| AD2 | **单分支策略：直接在 `master` 上 merge** | `upstream-snapshot` 分支增加维护复杂度且 merge commit 本身即完整记录。直接在 master 上 `git merge upstream/main`，merge commit 自身可追溯。 | 两分支（多一个 staging 分支增加维护复杂度）；三分支（过度设计） |
| AD3 | **`.gitattributes` 定义 merge 策略：taiji 独有文件 `ours`，`Cargo.toml`/`package.json` 也 `ours`** | `merge=ours` 确保 taiji 独有文件（`src/crates/taiji/**`、品牌资源、项目文档）和元数据文件（`Cargo.toml`、`package.json`）在上游变更时保留我方版本。代价：上游对 `Cargo.toml`/`package.json` 的依赖更新不会自动合入，需在 merge 后手动 `cargo update` / `pnpm update` 跟进。trade-off 文档化在不变式中 | 自定义 merge driver（复杂且维护成本高）；全手动裁决（每次同步重复，不可靠）|
| AD4 | **首次 merge 用 `--allow-unrelated-histories`，后续正常 merge** | taiji-quant 仓库由 robocopy 构建，与 upstream 无共同祖先 commit。`--allow-unrelated-histories` 让 git 接受两个根 commit 合并。仅首次需要，后续 merge 有共同祖先，走标准 3-way merge | `git read-tree` + `git commit`（手动构造 merge commit，复杂且易错） |
| AD5 | **闭源 crate 路径（`src/crates/taiji/taiji-{dvmi,magnet,thrust,risk}/**`）用 `merge=ours` 占位** | 闭源代码在 taiji-quant 仓库中不存在（目录为空或仅有 `.gitkeep`），但上游仓库包含完整闭源代码。merge 时上游会引入这些文件，需阻止提交。`merge=ours` 对已存在文件有效；对新增文件，需 post-merge 清理脚本 `git rm -rf` 移除 | 用 `.gitignore` 排除（仅阻止 untracked 显示，不阻止 merge 添加）；sparse checkout（影响整个工作区，副作用大） |
| AD6 | **sync-upstream.ps1 全量重写：`fetch → merge → resolve → verify → push`** | 旧脚本 7 步（rebase → calc diff → robocopy → regex 替换 → cargo check → commit → push），新脚本 6 步（fetch → merge → conflict resolve → closed-source cleanup → verify → push）。元数据文件（Cargo.toml / package.json）通过 `.gitattributes merge=ours` 自动保留 taiji 侧 | 保留旧脚本作为 fallback 路径（增加维护负担；旧脚本的 robocopy 盲覆盖缺陷未解决） |
| AD7 | **验证流水线不变：`cargo check --workspace` + `cargo test --workspace` + `pnpm type-check:web`** | 复用现有验证步骤，确保 merge 后编译通过。添加 `cargo test` 全量测试（旧脚本仅测两个 crate 子集），因为 merge 可能引入跨 crate 的 trait/macro 冲突 | 仅 cargo check（无法发现运行时/测试编译错误） |

---

## 数据流

### 总体同步数据流：taiji-quant 直接 merge upstream/main → master

```
┌──────────────────────┐
│ GCWing/BitFun (upstream) │  ← 上游源头
└────────┬─────────────┘
         │ git fetch upstream main
         ▼
┌──────────────────────┐
│ taiji-quant/master    │
│ git merge upstream/   │  ← 直接在 master 上 merge
│ main                  │
│ [--allow-unrelated-   │
│  histories]           │
└────────┬─────────────┘
         │ (3-way merge，.gitattributes 控制策略)
         ▼
┌──────────────────────┐
│ 冲突裁决              │
│  ├─ ours 文件: 自动保留│
│  ├─ Cargo.toml:       │
│  │   merge=ours       │
│  ├─ package.json:      │
│  │   merge=ours       │
│  └─ 共享 crate:        │
│      手动 3-way 裁决   │
└────────┬─────────────┘
         │ 闭源 crate 清理
         │ (git rm -rf src/crates/taiji/taiji-{dvmi,magnet,thrust,risk}/)
         ▼
┌──────────────────────┐
│ 验证流水线             │
│  1. cargo check       │
│  2. cargo test         │
│  3. pnpm type-check    │
└────────┬─────────────┘
         │ git commit (merge commit)
         ▼
┌──────────────────────┐
│ git push origin       │
│ master                │
└──────────────────────┘
```

### `.gitattributes` merge 策略路由

```
merge 请求
  │
  ├─ 文件路径匹配 src/crates/taiji/taiji-{dvmi,magnet,thrust,risk}/**
  │     └─ merge=ours （若我方无此文件则 post-merge rm）
  │
  ├─ 文件路径匹配 src/crates/taiji/**（非闭源）
  │     └─ merge=ours （保留 taiji 独有代码）
  │
  ├─ 文件路径匹配 resources/taiji-icon*, png/taiji-icon*, BitFun-Installer/src/taiji-icon*
  │     └─ merge=ours （保留 taiji 品牌资源）
  │
  ├─ 文件路径 == Cargo.toml (root)
  │     └─ merge=ours （保留 taiji workspace.members + 元数据）
  │
  ├─ 文件路径 == package.json (root)
  │     └─ merge=ours （保留 taiji name/version）
  │
  ├─ 文件路径匹配 README*.md, AGENTS*.md, CONTRIBUTING*.md
  │     └─ merge=ours （保留 taiji 项目文档，上游版本在 upstream 侧可查）
  │
  └─ 其他所有文件
        └─ merge=text （标准 3-way merge）
```

### Cargo.toml / package.json 合并策略（merge=ours）

Cargo.toml 和 package.json 通过 `.gitattributes merge=ours` 始终保留 taiji-quant 侧版本。代价：上游对依赖的更新（版本号、新增 shared crate）不会自动合入。merge 后需手动执行 `cargo update` / `pnpm update` 跟进上游依赖变更。此 trade-off 已文档化在不变式中。

---

## 文件架构

| 文件 | R-ID | 操作 | 变更说明 |
|------|------|------|----------|
| `scripts/sync-upstream.ps1` | R5.1 | **重写** | 删除 robocopy 全部分支 + regex 元数据替换；替换为 `git fetch upstream` → `git merge` → 冲突裁决 → 闭源清理 → 验证 → push |
| `.gitattributes` | R5.2 | **新建** | 定义 merge 策略：`src/crates/taiji/** merge=ours`、`Cargo.toml merge=ours`、`package.json merge=ours`、`pnpm-lock.yaml merge=ours`、`Cargo.lock merge=ours`、品牌/文档文件 `merge=ours` |
| `scripts/post-merge-cleanup.ps1` | R5.2 | **新建** | post-merge hook：删除 `src/crates/taiji/taiji-{dvmi,magnet,thrust,risk}/` 下的上游文件 |
| `.sync-upstream-state.json` | R5.3 | **修改 schema** | 新增字段 `merge_base_commit`（merge 的 base）、`strategy: "git-merge"`；保留 `last_synced_commit` 语义不变 |
| `Cargo.toml` | R5.5 | **不改（merge 产出）** | merge 时由 `.gitattributes merge=ours` 保留 taiji 侧；无需手动编辑 |

### 文件绝对路径

```
E:\finance-trading\lvpa\software\taiji-quant\
  ├── scripts\sync-upstream.ps1              ← R5.1 重写
  ├── scripts\post-merge-cleanup.ps1         ← R5.2 新建
  ├── .gitattributes                          ← R5.2 新建
  └── .sync-upstream-state.json              ← R5.3 改 schema
```

---

## 依赖图

```
                    ┌──────────────────────────────┐
                    │ R5.2 .gitattributes +         │
                    │ post-merge-cleanup.ps1        │
                    └────────────┬─────────────────┘
                                 │ 定义 merge 策略
                                 ▼
┌──────────────────────────────────────────────────────┐
│ R5.1 sync-upstream.ps1 重写                           │
│  流程: fetch → merge → resolve → cleanup → verify → push │
└────────────┬─────────────────────────────────────────┘
             │ 依赖
             ▼
┌──────────────────────────────────────────────────────┐
│ R5.3 首次 git merge upstream/main                     │
│ --allow-unrelated-histories                           │
│ 产出: merge commit（打通历史血缘）                      │
└────────────┬─────────────────────────────────────────┘
             │ 产出冲突
             ▼
┌──────────────────────────────────────────────────────┐
│ R5.4 冲突裁决                                         │
│  ├─ ours 文件: 自动（.gitattributes）                  │
│  ├─ Cargo.toml: merge=ours                             │
│  ├─ package.json: merge=ours                           │
│  └─ 共享 crate: 手动 3-way diff 裁决                  │
│ 产出: 无冲突的 working tree                            │
└────────────┬─────────────────────────────────────────┘
             │
             ▼
┌──────────────────────────────────────────────────────┐
│ R5.5 cargo check + 编译修复 + cargo test              │
│ 产出: 通过全量编译 + 测试的 working tree                │
└────────────┬─────────────────────────────────────────┘
             │
             ▼
┌──────────────────────────────────────────────────────┐
│ R5.6 commit + push                                    │
│ 产出: 推送到 origin/master                              │
└──────────────────────────────────────────────────────┘

拓扑排序: R5.1（脚本）∥ R5.2（配置）→ R5.3（首次 merge）→ R5.4（裁决）→ R5.5（验证）→ R5.6（发布）
无循环依赖。
```

---

## 风险与降级

| 风险 | 等级 | 缓解措施 | 降级方案 |
|------|------|---------|----------|
| 首次 `--allow-unrelated-histories` merge 冲突量大 | 高 | 先在 dry-run 模式评估冲突量：`git merge --no-commit --no-ff upstream/main` 后 `git diff --name-only --diff-filter=U` 列出冲突文件，按文件数决定是否分批 merge。预期冲突集中在 `Cargo.toml`、`package.json`、共享 crate 中 taiji 修改过的文件 | 若冲突 >50 文件，按子目录分批 merge（先 merge `src/crates/contracts/`，再 `src/crates/services/`，逐步推进） |
| Cargo.toml / package.json `merge=ours` 导致上游依赖更新不被合入 | 中 | merge 后手动 `cargo update` / `pnpm update` 跟进上游依赖变更。`cargo check` + `cargo test` 会暴露 semver 不兼容，不会被静默吞掉 | 手工编辑 `Cargo.toml` / `package.json`，手动对比上游 diff 选择性合入 |
| 共享 crate（assembly / contracts / execution / services / interfaces / adapters）中 taiji 定制与上游重构冲突 | 中 | git 3-way merge 标注冲突段 `<<<<<<<` / `>>>>>>>`，逐文件人工裁决。裁决原则：功能性定制保留（如 taiji-engine trait impl），纯重构/格式化接受上游 | 若某共享 crate 冲突过多无法裁决，临时 `git checkout --theirs <crate-path>` 接受上游后重新 apply taiji patch |
| post-merge 闭源 crate 清理遗漏新增文件 | 低 | 清理脚本用 `git ls-files src/crates/taiji/taiji-{dvmi,magnet,thrust,risk}/` 列出已被 git 追踪的闭源文件，`git rm -rf --cached` 移除追踪 + `Remove-Item` 删除物理文件。`cargo check` 会因 Cargo.toml 中 member 被注释而忽略这些 crate，不会编译失败 | 手动 `git rm -rf` |
| lock 文件（pnpm-lock.yaml / Cargo.lock）merge 冲突 | 中 | `.gitattributes merge=ours` 保留本地 lock 文件，merge 后分别执行 `pnpm install --no-frozen-lockfile` 和 `cargo generate-lockfile` 重新生成正确的 lock 文件 | 删除 lock 文件后 `pnpm install` + `cargo generate-lockfile` 全量生成 |
| 后续 merge（非首次）产生意料外冲突 | 低 | 每次 merge 后 `cargo check --workspace && cargo test --workspace` 全量验证。冲突量应随历史对齐而递减 | 退回旧 robocopy 脚本（保留为 `sync-upstream-legacy.ps1`，不做常态使用） |
| merge 中断（冲突未解决完）后脚本退出，工作区处于 "merging" 状态 | 中 | 脚本 `-ContinueMerge` 参数支持中断后恢复：冲突解决完后运行 `.\scripts\sync-upstream.ps1 -ContinueMerge` 跳过 merge 步骤从元数据恢复继续。若需放弃本次 merge，手动执行 `git merge --abort` 恢复合并前状态 | 手动 `git merge --abort` |

---

## 不变式

1. **taiji 独有代码不被上游覆盖** — `src/crates/taiji/**`、品牌资源文件通过 `.gitattributes merge=ours` 保护，上游无法反向引入同名文件覆盖 taiji 定制。
2. **闭源代码不入库** — post-merge 清理脚本强制删除 `src/crates/taiji/taiji-{dvmi,magnet,thrust,risk}/` 下所有文件，与旧 robocopy `/XD` 排除等价。
3. **taiji 元数据不可变** — `Cargo.toml` 的 `[package]`（name、version、authors）和 `[workspace].members` 中的 taiji crates 始终取 ours；`package.json` 的 name/version 始终取 ours。
4. **上游依赖更新需手动跟进** — `Cargo.toml` / `package.json` 通过 `merge=ours` 保留 taiji 侧，上游依赖更新（版本号、新增/删除 shared crate）不会自动合入。merge 后需手动 `cargo update` / `pnpm update` 跟进。此 trade-off 以简化 merge 策略换取手动依赖维护成本。
5. **共享 crate 冲突显式标注** — assembly / contracts / execution / services / interfaces / adapters 中的 taiji 定制与上游变更冲突时，git 标注 `<<<<<<<` / `>>>>>>>`，裁决结果可审计。
6. **验证门禁不可绕过** — merge 后必须通过 `cargo check --workspace` + `cargo test --workspace` + `pnpm type-check:web`，任一步失败则修复后重新验证。
7. **master 历史可追溯** — merge commit 直接在 master 上产生，merge commit 自身包含双方祖先信息（parent1 = taiji-quant master, parent2 = upstream/main），历史完整可审计。
8. **旧 robocopy 脚本保留为 legacy** — `sync-upstream.ps1` 重命名备份为 `sync-upstream-legacy.ps1`，仅作应急回退参考，不纳入主动工作流。
9. **`.gitattributes` 本身受 git 追踪** — merge 策略配置与代码同仓库版本化，clone 后自动生效，无需环境配置。
10. **sync state 文件向后兼容** — `.sync-upstream-state.json` 新增字段（`merge_base_commit`、`strategy`）不影响旧 `last_synced_commit` 语义，旧脚本可继续读取。
