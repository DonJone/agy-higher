# AgyHigher

原生 macOS（SwiftUI + Rust Core）Antigravity Desktop 实时遥测、多账户额度监控与 STE-STC 中文拓展控制面板。

## 核心特性

- **实时上下文遥测**：只读解析 Antigravity Desktop（兼容 v2.35.0 无限本地历史、归档/星标/标签标注与 `gen_metadata` 原生 Protobuf），WAL 感知持久化缓存 + macOS kqueue 零轮询监听。
- **零混用多账户额度面板**：精准隔离并归档多 Google 账户的周剩余与 5h 窗口额度，支持状态栏 `周%-5h%` 常驻显示。
- **STE-STC 中文拓展与直接补丁**：内置 2,557 条 STE-STC 规范词库、自定义词条覆盖与可无损还原的 `app.asar` 主进程热加载补丁。
- **内置自动更新**：基于 GitHub Releases（支持正式版 / 预览版通道、静态 `latest.json` 降级、SHA-256 校验与无重影原位替换重启）。

## 构建与发布

```bash
# 本地构建 AgyHigher.app（带 AppIcon.icns 与 Ad-hoc 签名）
./scripts/build.sh

# 打包 DMG + .app.zip + latest.json + SHA256SUMS.txt
./scripts/package_dmg.sh

# 本地构建并一键发布 GitHub Release（默认 Pre-release，加 --stable 发布正式版）
./scripts/release_local.sh --stable
```

## 首次打开提示处理

开源版本采用本地 Ad-hoc 签名，首次打开如提示“无法验证开发者”或“已损坏”，执行一次：

```bash
sudo xattr -rd com.apple.quarantine /Applications/AgyHigher.app
```
