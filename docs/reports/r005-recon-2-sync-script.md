# R-005 侦察报告 #2：sync 脚本全量审计

## sync-upstream.ps1 步骤拆解

| 步骤 | 操作 | 风险 |
|------|------|------|
| 1 | taiji 工作区 git fetch + rebase taiji-v1 → push mengdie --force | force push 到公共分支 |
| 2 | git log 计算增量 commit | 安全 |
| 3 | robocopy /E /XO taiji→taiji-quant | **盲覆盖，不感知git冲突** |
| 4 | 正则替换恢复元数据 | 上游改格式则匹配失败 |
| 5 | 保存 sync state | 安全 |
| 6 | cargo check 验证 | 仅编译检查，不跑测试 |
| 7 | git add -A + commit + push master | **全量stage无审查** |

## 致命缺陷
1. robocopy /E /XO 基于文件时间戳盲覆盖——不理解git冲突
2. taiji 工作区是多此一举的中转——taiji-quant 已有 upstream remote
3. 元数据恢复依赖正则替换——上游改格式则匹配失败，上游元数据泄漏
4. 闭源 crate 排除仅靠 robocopy /XD

## 相关文件
- scripts/migrate-taiji.ps1：taiji 特性迁移工具，与 sync 独立
- .gitignore 排除：.bitfun/, target/, node_modules, Cargo.lock, data/pipeline/, taiji-website/
- 闭源 crate：taiji-dvmi, taiji-magnet, taiji-thrust, taiji-risk

## Cargo.toml 元数据
- version: "0.1.0"
- authors: ["Taiji Quant Team"]

## package.json 元数据
- name: "taiji-quant"
- version: "0.1.0"
