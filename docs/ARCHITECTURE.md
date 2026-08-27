# Transnap 架构

Transnap 是一个不启动本地服务器的原生 macOS 菜单栏应用。核心流程由 AppKit（macOS 原生界面框架）和系统辅助功能接口组成。

## 模块

### App

- `TransnapMain.swift`：SwiftUI（苹果声明式界面框架）应用入口和命令行自测入口。
- `AppDelegate.swift`：菜单栏、窗口控制器、快捷键和翻译任务的生命周期协调。

### Core

- `AppSettings.swift`：非敏感偏好设置及默认值。
- `CredentialStore.swift`：本机接口密钥保存与旧版本迁移。
- `SelectionReader.swift`：辅助功能选区、鼠标文字范围和临时复制回退。
- `TranslationClient.swift`：OpenAI 兼容请求、流式解析和错误映射。
- `TranslationHistoryStore.swift`：本地 JSON 历史记录和去重。
- `TranslationShortcutMonitor.swift`：全局快捷键监听。

### UI

- `TranslationPanelController.swift`：紧凑/展开浮层、双栏翻译和历史列表。
- `SettingsWindowController.swift`：通用、翻译和模型三类设置。
- `ShortcutRecorderButton.swift`：快捷键录制控件。
- `LoadingDotsView.swift`：加载状态动画。

## 数据流

1. 全局快捷键提供当前鼠标位置。
2. `SelectionReader` 读取选中文本并确定锚点。
3. `TranslationPanelController` 在锚点所在显示器展示加载状态。
4. `TranslationClient` 将文本发送到用户配置的接口。
5. 流式增量回到主线程并更新译文。
6. 完成后按设置复制译文并写入本地历史。

## 本地存储

| 数据 | 位置 | 说明 |
| --- | --- | --- |
| 非敏感设置 | `~/Library/Preferences/com.codex.Transnap.plist` | 快捷键、模型名称、界面行为等 |
| 接口密钥 | `~/Library/Application Support/Transnap/api-key` | 权限 `0600`，排除系统备份 |
| 翻译历史 | `~/Library/Application Support/Transnap/translation-history.json` | 最多 200 条，可在设置中停止新增 |

## 网络边界

应用只向用户配置的基础地址发起 `POST /chat/completions` 请求。请求包含模型名称、翻译提示词和当前选中的原文。历史记录不会作为上下文发送。
