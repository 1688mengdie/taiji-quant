# R-005: 上游同步策略重构 — robocopy → git merge

## 需求来源

1. 当前 `scripts/sync-upstream.ps1` 使用 `robocopy /E /XO` 盲覆盖文件，不感知 git 冲突。每次同步将上游 234+ Rust 文件直接覆写到 taiji-quant 工作区，然后 `git add -A` 全量提交。
2. taiji 在共享 crate（adapters/assembly/contracts/execution/interfaces/services）中的定制被上游同步静默覆盖。例如上次同步（a441517）删除了 `AgentType::Other`、`MAX_FISSION_DEPTH`、session tree 逻辑。
3. 改用 `git merge` 建立血缘关系：冲突可见、可追溯、可裁决。taiji 定制与上游改进通过标准 git 三方合并流程共存。

## R-ID 矩阵

| R-ID | 描述 | 优先级 | 依赖 |
|------|------|--------|------|
| R5.1 | 重写 `sync-upstream.ps1`：robocopy 替换为 `git merge` | P0 | - |
| R5.2 | 创建 `.gitattributes`：定义 merge 策略（ours/union） | P0 | - |
| R5.3 | 首次 `--allow-unrelated-histories` 合并 | P0 | R5.1, R5.2 |
| R5.4 | 冲突裁决规则与 SOP | P0 | R5.3 |
| R5.5 | `cargo check` + `cargo test` 全量验证 | P0 | R5.4 |
| R5.6 | commit + push（conventional commits） | P0 | R5.5 |

## 验收标准（逐 R-ID）

### R5.1: 重写 `sync-upstream.ps1`

1. 移除 `robocopy` 调用及 `$ExcludeDirs` 的文件排除逻辑。
2. 新脚本通过 `git fetch upstream` 拉取 `GCWing/BitFun` 最新 main 后，执行 `git merge upstream/main`（或指定 commit）。
3. 合并前检查工作区状态（`git status --porcelain`），若不干净则拒绝执行并 exit 1，提示用户先 commit 或 stash。
4. 保留元数据恢复逻辑（Cargo.toml version/authors, package.json name/version），但改为在 merge 完成后通过 `git checkout --ours` 或 sed 就地修复。
5. 保留 `-SkipBuild`、`-DryRun`、`-TaijiQuantWorkspace` 参数；新增 `-UpstreamRemote`（默认 `upstream`）、`-UpstreamBranch`（默认 `main`）、`-ContinueMerge`、`-SyncStateFile` 参数。
6. `-DryRun` 模式下输出将执行的操作清单（fetch ref、merge base、预期冲突文件列表），不实际修改工作区。
7. 脚本在 `$ErrorActionPreference = "Stop"` 下运行；任何 git 操作失败时输出明确错误信息并退出非零。

### R5.2: 创建 `.gitattributes` merge 策略

1. 仓库根目录新建 `.gitattributes`，定义以下 merge 策略：

   | 路径 | 策略 | 理由 |
   |------|------|------|
   | `Cargo.toml` | `merge=ours` | taiji 版本号/作者不随上游变 |
   | `package.json` | `merge=ours` | taiji 包名/版本不随上游变 |
   | `src/crates/taiji*/**` | `merge=ours` | taiji 独有 crate，上游不存在，永不冲突 |
   | `BitFun-Installer/**` | `merge=ours` | taiji 安装器独立维护 |
   | `skills/**` | `merge=ours` | taiji 本地技能不随上游变 |
   | `scripts/sync-upstream.ps1` | `merge=ours` | 同步脚本本身不随上游变 |
   | `Cargo.lock` | `merge=ours` | 保留 taiji-quant 本地依赖树，merge 后 `cargo generate-lockfile` 重新生成 |
   | `pnpm-lock.yaml` | `merge=ours` | 保留 taiji-quant 本地依赖树，merge 后 `pnpm install --no-frozen-lockfile` 重新生成 |

2. 共享 crate 路径（`src/crates/adapters/**`、`src/crates/assembly/**`、`src/crates/contracts/**`、`src/crates/execution/**`、`src/crates/interfaces/**`、`src/crates/services/**`）不设特殊策略，使用默认 `merge=text`，让 git 标准三方合并检测冲突。
3. `.gitattributes` 自身不设 merge 策略（默认 text），可随上游更新。
4. 所有 `merge=ours` 条目需在文件中注释说明原因。
5. 验证：在 taiji-quant 仓库中执行 `git check-attr -a Cargo.toml` 输出包含 `merge: ours`。

### R5.3: 首次 `--allow-unrelated-histories` 合并

1. 确认 taiji-quant 当前 master 与 upstream/main 无共同祖先（`git merge-base master upstream/main` 返回空）。
2. 执行 `git merge upstream/main --allow-unrelated-histories --no-commit --no-ff`。
3. 合并后，对 `merge=ours` 标记的文件执行 `git checkout --ours <file>` 确保 taiji 侧内容保留。
4. 对 lock 文件（`Cargo.lock`、`pnpm-lock.yaml`），`.gitattributes merge=ours` 保留 taiji-quant 本地版本；merge 后分别执行 `cargo generate-lockfile` 和 `pnpm install --no-frozen-lockfile` 重新生成正确的 lock 文件。
5. 共享 crate 中的冲突由 `.gitattributes` 默认策略产生标准 git conflict marker，留待 R5.4 裁决。
6. 元数据恢复：合并后确认 `Cargo.toml` 中 `version = "0.1.0"`、`authors = ["Taiji Quant Team"]`，`package.json` 中 `"name": "taiji-quant"`、`"version": "0.1.0"` 未被覆盖。

### R5.4: 冲突裁决规则与 SOP

1. 制定裁决优先级表：

   | 冲突场景 | 裁决原则 | 操作 |
   |---------|---------|------|
   | taiji 定制 vs 上游重构（同一段逻辑） | **保留 taiji 定制**，手动 review 上游重构是否可吸收 | `git checkout --ours` 然后逐块评估 |
   | taiji 新增文件 vs 上游同名文件 | **保留 taiji 文件**（上游不可能有 taiji crate 的合法覆盖） | `git checkout --ours` |
   | 上游新增功能 vs taiji 空白（未改动区域） | **接受上游** | `git checkout --theirs` |
   | taiji 删除 vs 上游修改（同一区域） | **接受上游修改**（taiji 删除的东西被上游改了，说明仍需要） | `git checkout --theirs` |
   | 两边都是格式/导入变更 | **接受上游**（减少无意义差异） | `git checkout --theirs` |
   | 闭源 trait 实现文件（共享 crate 中 `impl Xxx for Yyy`） | **保留 taiji**（这些是实现闭源逻辑的关键） | `git checkout --ours` |

2. 冲突裁决 SOP 写入 `docs/plans/r005-merge-conflict-sop.md`，包含：
   - 识别冲突文件：`git diff --name-only --diff-filter=U`
   - 逐文件分类（ours/theirs/manual）
   - 裁决检查清单（3 问：此文件 taiji 是否定制过？上游变更是修复还是新功能？两边的意图是否兼容？）
   - 裁决后验证：`cargo check -p <affected_crate>`
3. 每次上游同步后，冲突裁决记录追加到 `docs/reports/merge-conflict-log.md`（日期、冲突文件数、裁决分布、耗时）。

### R5.5: `cargo check` + `cargo test` 全量验证

1. `cargo check --workspace` 零错误（设置 `$env:OPENSSL_DIR` 指向 PostgreSQL OpenSSL 路径）。
2. `cargo test -p bitfun-services-core --lib` 通过。
3. `cargo test -p bitfun-core --lib` 通过。
4. `pnpm run type-check:web` 通过。
5. 任何验证失败时，脚本输出明确失败阶段和最后 20 行日志，退出非零；不继续后续 commit/push。

### R5.6: commit + push

1. 合并提交使用 conventional commits 格式：`sync: upstream <YYYY-MM-DD> — merge GCWing/BitFun main (<N> commits)`。
2. commit message body 包含：
   - 上游 commit 范围（`<merge-base>..<upstream-head>`）。
   - 冲突文件清单（若有）。
   - 裁决摘要（ours/theirs/manual 各计数）。
3. `git push origin master` 推送至 `1688mengdie/taiji-quant`。
4. 推送成功后更新 `.sync-upstream-state.json`（与现有格式一致：`last_synced_commit`、`synced_at`、`commit_count`）。

## 边界与约束

- **工作区**：`E:\finance-trading\lvpa\software\taiji-quant`（主操作区）和 `E:\finance-trading\lvpa\software\taiji`（上游 fetch 参考源）
- **不新增 crate**：所有变更限于 `.gitattributes`（新增）、`scripts/sync-upstream.ps1`（重写）、`docs/`（SOP 文档）
- **不破坏已有 taiji 定制**：`merge=ours` 策略确保 taiji 独有 crate 和元数据文件不受上游合并影响
- **不改变闭源隔离策略**：`taiji-dvmi`、`taiji-magnet`、`taiji-thrust`、`taiji-risk` 仍不存在于 taiji-quant 仓库
- **远程关系不变**：`upstream` → `GCWing/BitFun`、`origin` → `1688mengdie/taiji-quant`、`mengdie` → `1688mengdie/BitFun`
- **master 分支直接 push 例外**：上游同步是 AGENTS.md 中唯一允许直接 push master 的场景，本次重构保留此例外
- **taiji workspace 仍为上游 fetch 参考源**：taiji-quant 的 `upstream` remote 指向 `GCWing/BitFun`，直接 fetch，不依赖 taiji workspace 中转

## 技术上下文

### 关键远程关系

```
GCWing/BitFun (upstream)
    ↑ fetch
taiji-quant ── origin → 1688mengdie/taiji-quant
    └── mengdie → 1688mengdie/BitFun

taiji ── origin → GCWing/BitFun
    ├── upstream → GCWing/BitFun
    ├── mengdie → 1688mengdie/BitFun
    └── taiji-quant → E:\finance-trading\lvpa\software\taiji-quant (local)
```

### taiji 仓库结构

| 类别 | crate | 数量 |
|------|-------|------|
| 共享（BitFun 上游存在） | adapters, assembly, contracts, execution, interfaces, services | 6 |
| taiji 独有 | taiji, taiji-abnormal, taiji-agents, taiji-alert, taiji-backtest, taiji-bar, taiji-blog-gen, taiji-cli, taiji-content, taiji-engine, taiji-engine-py, taiji-example, taiji-executor, taiji-growth, taiji-knowledge-graph, taiji-llm, taiji-orderflow, taiji-pattern, taiji-publisher, taiji-realtime, taiji-sentiment, taiji-strategen, taiji-strategy-template | 23 |
| 闭源（不存在于 taiji-quant） | taiji-dvmi, taiji-magnet, taiji-thrust, taiji-risk | 4 |

### 修改文件清单

| 文件 | R-ID | 变更类型 |
|------|------|------|
| `.gitattributes` | R5.2 | **新增** — merge 策略定义 |
| `scripts/sync-upstream.ps1` | R5.1 | **重写** — robocopy → git merge |
| `docs/plans/r005-merge-conflict-sop.md` | R5.4 | **新增** — 冲突裁决 SOP |
| `docs/reports/merge-conflict-log.md` | R5.4 | **新增** — 冲突裁决记录模板 |
| `.sync-upstream-state.json` | R5.3, R5.6 | **更新** — merge 后更新状态 |

> 注：`docs/reports/` 目录需确认是否存在，若不存在则在 R5.4 执行时创建。

## 依赖关系图

```
R5.1 ──┬── R5.3 ──┬── R5.4 ── R5.5 ── R5.6
       │          │
R5.2 ──┘          │
                  └── (R5.3 产生冲突后，R5.4 逐文件裁决)
```

### 执行顺序

1. **R5.2** — 先创建 `.gitattributes`（merge 策略必须在合并前就位），独立 commit 到 master
2. **R5.1** — 重写脚本（可并行于 R5.2），独立 commit
3. **R5.3** — 执行首次合并（依赖 R5.1 脚本就绪 + R5.2 .gitattributes 生效）
4. **R5.4** — 裁决首次合并产生的冲突（依赖 R5.3 产生冲突列表）
5. **R5.5** — 编译 + 测试验证（依赖 R5.4 冲突全部解决）
6. **R5.6** — commit + push（依赖 R5.5 全部通过）

## 已定决策

| 决策点 | 结论 | 理由 |
|--------|------|------|
| 合并策略 | `git merge`（三方合并）而非 `git rebase` | rebase 会改写 taiji-quant 提交历史，破坏 master 历史完整性；merge 保留双方历史，冲突一次裁决 |
| 首次合并 | `--allow-unrelated-histories` | taiji-quant 的 master 与 GCWing/BitFun main 无共同 git 祖先（当前通过 robocopy 同步文件，非 git 操作） |
| taiji 独有 crate 策略 | `merge=ours` | 上游不可能有这些路径的合法更新，设为 ours 消除误报冲突 |
| Cargo.toml / package.json | `merge=ours` | 版本号和包名是 taiji 身份标识，必须保留 taiji 侧 |
| Cargo.lock / pnpm-lock.yaml | `merge=ours` 后重新生成 | 保留 taiji-quant 本地依赖树，合并后由包管理器重新生成正确的 lock 文件 |
| 共享 crate 冲突 | 默认 text merge + 人工裁决 | 这是唯一需要人工判断的区域，git conflict marker 明确标记，裁决 SOP 可复用 |
| merge 前工作区检查 | 强制干净工作区，不干净则拒绝 | 避免未提交变更被 merge 污染，强制用户在合并前 commit 或 stash |

## 风险与缓解

| 风险 | 影响 | 缓解 |
|------|------|------|
| 首次 `--allow-unrelated-histories` 产生海量冲突（数千文件级别） | 人工裁决不可行 | R5.2 的 `.gitattributes` 将 taiji 独有 23 crate + 元数据文件设为 ours，大幅缩减冲突范围到 6 个共享 crate；若首次冲突仍超 50 文件，分批 merge（按 crate 粒度） |
| lock 文件（Cargo.lock / pnpm-lock.yaml）merge=ours 后依赖树过期 | 后续 `cargo check` 或 `pnpm install` 失败 | 合并后立即重新生成 lock 文件（`cargo generate-lockfile` + `pnpm install --no-frozen-lockfile`），不依赖旧 lock 文件 |
| 共享 crate 中 taiji 定制被 `git checkout --theirs` 误操作覆盖 | taiji 功能退化 | R5.4 裁决 SOP 要求逐文件确认 taiji 是否定制过该区域（第一步即检查 git log），定制文件必须有 `--ours` 倾向 |
| git merge 在 Windows PowerShell 下的编码问题（中文 commit message 乱码） | commit 信息不可读 | 脚本中使用 UTF-8 BOM 编码写 commit message；`git commit` 前设置 `$env:GIT_COMMITTER_NAME` / `$env:GIT_AUTHOR_NAME` 确保元数据正确 |
| merge 中断（冲突未解决完）后脚本退出，工作区处于 "merging" 状态 | 后续 git 操作被阻塞 | 脚本支持 `-ContinueMerge` 参数从中断点恢复；若需放弃本次 merge，手动执行 `git merge --abort` 恢复合并前状态 |
| 未来上游新增 crate 与 taiji 独有 crate 同名 | merge=ours 错误屏蔽合法更新 | taiji 独有 crate 遵循 `taiji-` 前缀命名约定，上游几乎不可能冲突；若发生则 taiji 侧改名 |