<div align="center">
  <img src="ClaudeIsland/Assets.xcassets/AppIcon.appiconset/icon_128x128.png" alt="Logo" width="100" height="100">
  <h3 align="center">Breadcrumb</h3>
  <p align="center">
    macOS 灵动岛风格的 AI 协作历史追踪工具
    <br />
    跨 session 回溯 Claude Code 交互记录，沉淀协作 SOP
  </p>
</div>

## 核心功能

- **灵动岛 UI** — 从 MacBook 刘海区域展开的浮层交互
- **实时 Session 监控** — 同时追踪多个 Claude Code 会话状态
- **权限审批** — 直接在灵动岛上 Approve/Deny AI 的操作请求
- **历史检索** — 按项目(project-based)和时间(time-based)两种维度回溯对话记录
- **双击 ⌘ 唤起** — 全局快捷键随时展开/收起

## 使用场景

- 回顾 AI 的决策轨迹，找到关键转折点
- 跨 session 搜索特定对话内容
- 复盘项目中的 AI 协作模式，优化工作流
- 不切换窗口直接审批 Claude 的工具调用

## 安装

macOS 15.6+ / Claude Code CLI

```bash
# 从源码构建
xcodebuild -scheme ClaudeIsland -configuration Release build
```

构建后将 `.app` 拖到 `/Applications`，在菜单中开启 "Launch at Login" 即可开机自启。

## 触发方式

| 方式 | 行为 |
|------|------|
| 鼠标悬停刘海 1 秒 | 自动展开 |
| 双击 ⌘ (Command) | 切换展开/收起 |

首次使用需在「系统设置 → 隐私与安全性 → 辅助功能」中授权。

## 工作原理

Breadcrumb 在 `~/.claude/hooks/` 安装钩子，通过 Unix socket 接收 Claude Code 的会话状态事件，在灵动岛浮层中实时展示。

## License

Apache 2.0

## 致谢

基于 [claude-island](https://github.com/farouqaldori/claude-island) 开发。
