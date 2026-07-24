# R-005 侦察报告 #3：taiji 定制文件清单

## taiji 独有 crate（23个，上游不存在）
taiji, taiji-abnormal, taiji-agents, taiji-alert, taiji-backtest, taiji-bar, taiji-blog-gen, taiji-cli, taiji-content, taiji-engine, taiji-engine-py, taiji-example, taiji-executor, taiji-growth, taiji-knowledge-graph, taiji-llm, taiji-orderflow, taiji-pattern, taiji-publisher, taiji-realtime, taiji-sentiment, taiji-strategen, taiji-strategy-template

## 闭源 crate（4个，不存在于仓库）
taiji-dvmi, taiji-magnet, taiji-thrust, taiji-risk

## 共享 crate（6组，会被上游同步覆盖）
adapters, assembly, contracts, execution, interfaces, services

## 共享 crate 中的 taiji 定制
- assembly/core：session tree、AgentType::Other、DelegationPolicy spawn_child 深度裂变（R001-R004）
- contracts/runtime-ports：AgentType 枚举（含 Other 变体）、MAX_FISSION_DEPTH
- contracts/core-types：session_tree 模块
- services/services-core：session/tree.rs
- 上次上游同步（a441517）覆盖了 234 个 Rust 文件

## 品牌文件
- png/taiji-icon.png, png/taiji-icon-128.png
- BitFun-Installer/src/taiji-icon.png
- skills/master-framework/SKILL.md

## 计划文档
- docs/plans/r003-*, docs/plans/r004-*
