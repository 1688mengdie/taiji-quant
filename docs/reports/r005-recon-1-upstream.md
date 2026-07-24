# R-005 侦察报告 #1：上游仓库结构

## 上游源头
- GCWing/BitFun：https://github.com/GCWing/BitFun.git

## taiji 工作区（E:\finance-trading\lvpa\software\taiji）
- 当前分支：taiji-v1
- 工作区状态：干净
- Remote：origin→GCWing/BitFun, upstream→GCWing/BitFun, mengdie→1688mengdie/BitFun, taiji-quant→本地路径

## taiji-quant 工作区
- 当前分支：master
- HEAD：bb8fc91
- 工作区状态：干净
- Remote：origin→1688mengdie/taiji-quant, upstream→GCWing/BitFun（已配置，可直接fetch）, mengdie→1688mengdie/BitFun

## 同步状态文件
- 路径：.sync-upstream-state.json
- 内容：{"commit_count":4,"synced_at":"2026-07-23T09:40:42+08:00","last_synced_commit":"dae57514256db88161eb6c6dbdcb1990417e0e0c"}

## 关键结论
- taiji-quant 已有 upstream remote 直连 GCWing/BitFun，不需要经过 taiji 工作区中转
- 当前 sync 脚本却通过 taiji 工作区中转 robocopy——多余的跳板
