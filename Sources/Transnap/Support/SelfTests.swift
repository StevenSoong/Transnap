import AppKit
import Foundation

enum SelfTestError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

enum SelfTests {
    static func run() throws {
        try expect(
            TranslationClient.endpoint(from: "https://example.com/v1/").absoluteString
                == "https://example.com/v1/chat/completions",
            "接口路径拼接错误"
        )
        try expect(
            TranslationClient.endpoint(from: "https://example.com/v1/chat/completions").absoluteString
                == "https://example.com/v1/chat/completions",
            "完整接口路径被重复拼接"
        )

        let event = #"{"choices":[{"delta":{"reasoning_content":"thinking","content":"你好"}}]}"#
        try expect(TranslationClient.contentDelta(from: event) == "你好", "流式内容解析错误")
        try expect(
            TargetLanguage.automatic.instruction(for: "这是中文内容") == "自然、地道的英语",
            "中文自动目标语言错误"
        )
        try expect(
            TargetLanguage.automatic.instruction(for: "Hello world") == "简体中文",
            "英文自动目标语言错误"
        )

        let settings = AppSettingsSnapshot(
            baseURL: "https://example.com/v1",
            model: "gpt-4o-mini",
            targetLanguage: .simplifiedChinese,
            translationPrompt: "Translate to {target_language}."
        )
        let body = TranslationClient.requestBody(text: "Hello", settings: settings)
        try expect(body["model"] as? String == "gpt-4o-mini", "请求模型名称错误")
        try expect((body["temperature"] as? NSNumber)?.doubleValue == 0, "通用模型请求温度发生变化")
        try expect(body["chat_template_kwargs"] == nil, "通用模型请求携带了 GLM 专用字段")
        try expect(body["stream"] as? Bool == true, "翻译请求未启用流式响应")
        let messages = body["messages"] as? [[String: String]]
        try expect(
            messages?.first?["content"] == "Translate to 简体中文.",
            "自定义翻译提示词或目标语言变量未生效"
        )

        let glmSettings = AppSettingsSnapshot(
            baseURL: "https://example.com/v1",
            model: "glm-5.2",
            targetLanguage: .simplifiedChinese,
            translationPrompt: AppSettings.defaultTranslationPrompt
        )
        let glmBody = TranslationClient.requestBody(text: "Hello", settings: glmSettings)
        try expect(
            (glmBody["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"] == false,
            "GLM 翻译请求未关闭模型思考"
        )

        for kimiModel in [
            " KIMI-K3 ",
            "k3",
            "k3-256k",
            "kimi-for-coding",
            "kimi-for-coding-highspeed",
            "kimi-k2.5",
            "kimi-k2.6",
            "kimi-k2.7-code",
            "kimi-k2.7-code-highspeed",
        ] {
            let kimiSettings = AppSettingsSnapshot(
                baseURL: "https://example.com/v1",
                model: kimiModel,
                targetLanguage: .simplifiedChinese,
                translationPrompt: AppSettings.defaultTranslationPrompt
            )
            let kimiBody = TranslationClient.requestBody(text: "Hello", settings: kimiSettings)
            try expect(
                kimiBody["temperature"] == nil,
                "Kimi Code 模型 \(kimiModel) 的翻译请求不应携带固定温度参数"
            )
        }
        try expect(
            TranslationClient.shouldOmitTemperature(
                model: "future-kimi-code-model",
                baseURL: "https://api.kimi.com/coding/v1"
            ),
            "Kimi Code 接口的新模型不应被强行覆盖温度参数"
        )
        try expect(
            !TranslationClient.shouldOmitTemperature(
                model: "gpt-4o-mini",
                baseURL: "https://api.openai.com/v1"
            ),
            "非 Kimi Code 模型不应丢失温度参数"
        )

        let shortcut = KeyboardShortcut(keyCode: 17, modifiers: [.control, .option], keyLabel: "T")
        try expect(shortcut.displayString == "⌃⌥T", "快捷键显示错误")
        try expect(shortcut.matches(keyCode: 17, modifiers: [.control, .option]), "正确快捷键未匹配")
        try expect(!shortcut.matches(keyCode: 17, modifiers: [.control, .option, .shift]), "额外修饰键不应匹配")
        try expect(!shortcut.matches(keyCode: 16, modifiers: [.control, .option]), "错误普通按键不应匹配")

        let draggableAppURL = URL(fileURLWithPath: "/Applications/Transnap.app")
        try expect(
            AccessibilityDragPayload.applicationBundleURL(from: draggableAppURL) == draggableAppURL,
            "辅助功能授权拖拽没有保留当前 app bundle URL"
        )
        try expect(
            AccessibilityDragPayload.pasteboardItem(for: draggableAppURL)?
                .string(forType: .fileURL) == draggableAppURL.absoluteString,
            "辅助功能授权拖拽没有写入标准文件 URL"
        )
        try expect(
            AccessibilityDragPayload.applicationBundleURL(
                from: URL(fileURLWithPath: "/tmp/Transnap")
            ) == nil,
            "非 app 路径不应成为辅助功能授权拖拽载荷"
        )
        try expect(
            AccessibilityDragPayload.applicationBundleURL(
                from: URL(string: "https://example.com/Transnap.app")!
            ) == nil,
            "远程 URL 不应成为辅助功能授权拖拽载荷"
        )

        let unauthorizedPermission = AccessibilityAuthorizationPresentation.make(
            isTrusted: false,
            canDragApplication: true,
            phase: .idle
        )
        try expect(unauthorizedPermission.statusText == "未授权", "未授权状态文案错误")
        try expect(unauthorizedPermission.showsDragSource, "未授权时未显示 app 拖拽入口")
        try expect(unauthorizedPermission.buttonTitle == "打开设置…", "未授权按钮文案错误")

        let droppedPermission = AccessibilityAuthorizationPresentation.make(
            isTrusted: false,
            canDragApplication: true,
            phase: .dropped
        )
        try expect(droppedPermission.statusText == "请确认", "拖放完成后的状态文案错误")
        try expect(
            droppedPermission.instructionText.contains("确认闪译已在列表"),
            "拖放完成后没有提示用户在系统设置中确认"
        )

        let authorizedPermission = AccessibilityAuthorizationPresentation.make(
            isTrusted: true,
            canDragApplication: true,
            phase: .dropped
        )
        try expect(authorizedPermission.statusText == "已授权", "已授权状态文案错误")
        try expect(!authorizedPermission.showsDragSource, "已授权后仍显示 app 拖拽入口")
        try expect(authorizedPermission.buttonTitle == "查看…", "已授权按钮文案错误")

        let nonBundlePermission = AccessibilityAuthorizationPresentation.make(
            isTrusted: false,
            canDragApplication: false,
            phase: .idle
        )
        try expect(!nonBundlePermission.showsDragSource, "非 app 运行时不应显示拖拽入口")
        try expect(
            nonBundlePermission.instructionText.contains("Transnap.app"),
            "非 app 运行时没有显示安装指引"
        )

        var previousTrust: Bool?
        let trustSequence = [false, false, true, true, false]
        let monitorActions = trustSequence.map { trusted -> AccessibilityShortcutMonitorAction in
            defer { previousTrust = trusted }
            return AccessibilityShortcutMonitorTransition.action(
                previous: previousTrust,
                current: trusted
            )
        }
        try expect(
            monitorActions == [.stop, .none, .restart, .none, .stop],
            "辅助功能权限变化会重复或遗漏快捷键监听更新"
        )

        let suiteName = "com.codex.Transnap.SelfTests.\(UUID().uuidString)"
        guard let shortcutDefaults = UserDefaults(suiteName: suiteName) else {
            throw SelfTestError.failed("无法创建快捷键测试设置")
        }
        defer { shortcutDefaults.removePersistentDomain(forName: suiteName) }
        let shortcutSettings = AppSettings(defaults: shortcutDefaults)
        try expect(shortcutSettings.keyboardShortcut == .defaultShortcut, "默认快捷键错误")
        let customShortcut = KeyboardShortcut(keyCode: 37, modifiers: [.command, .option], keyLabel: "L")
        shortcutSettings.keyboardShortcut = customShortcut
        try expect(shortcutSettings.keyboardShortcut == customShortcut, "自定义快捷键未持久化")
        shortcutSettings.translationPrompt = "Custom {target_language}"
        shortcutSettings.streamTranslation = false
        shortcutSettings.autoCopyTranslation = true
        shortcutSettings.saveTranslationHistory = false
        try expect(shortcutSettings.translationPrompt == "Custom {target_language}", "翻译提示词未持久化")
        try expect(!shortcutSettings.streamTranslation, "流式显示设置未持久化")
        try expect(shortcutSettings.autoCopyTranslation, "自动复制设置未持久化")
        try expect(!shortcutSettings.saveTranslationHistory, "历史记录设置未持久化")
        try expect(
            AppSettings.defaultBaseURL == "https://api.openai.com/v1",
            "公开版本的默认接口地址错误"
        )

        let credentialDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Transnap-CredentialTests-\(UUID().uuidString)", isDirectory: true)
        let credentialURL = credentialDirectory.appendingPathComponent("api-key")
        let credentialSuiteName = "com.codex.Transnap.CredentialTests.\(UUID().uuidString)"
        guard let credentialDefaults = UserDefaults(suiteName: credentialSuiteName) else {
            throw SelfTestError.failed("无法创建密钥迁移测试设置")
        }
        defer {
            try? FileManager.default.removeItem(at: credentialDirectory)
            credentialDefaults.removePersistentDomain(forName: credentialSuiteName)
        }
        credentialDefaults.set("local-test-key", forKey: "apiKey")
        let credentialStore = CredentialStore(
            fileURL: credentialURL,
            defaults: credentialDefaults
        )
        try expect(credentialStore.loadAPIKey() == "local-test-key", "旧版密钥未正确迁移")
        try expect(credentialDefaults.string(forKey: "apiKey") == nil, "迁移后仍保留明文偏好设置")
        let credentialAttributes = try FileManager.default.attributesOfItem(atPath: credentialURL.path)
        let credentialMode = (credentialAttributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        try expect(credentialMode & 0o777 == 0o600, "密钥文件权限不是仅当前用户可读写")
        credentialStore.saveAPIKey("")
        try expect(!FileManager.default.fileExists(atPath: credentialURL.path), "清空密钥后本地文件仍存在")

        try expect(
            !TranslationLayoutPolicy.usesLargeWindow(for: "A short sentence."),
            "短文本不应使用大窗布局"
        )
        try expect(
            TranslationLayoutPolicy.usesLargeWindow(
                for: String(repeating: "长文本", count: TranslationLayoutPolicy.longTextCharacterThreshold)
            ),
            "长文本未使用大窗布局"
        )
        try expect(
            TranslationLayoutPolicy.usesLargeWindow(for: "1\n2\n3\n4\n5\n6\n7\n8"),
            "多行文本未使用大窗布局"
        )

        let visibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let selection = CGRect(x: 520, y: 600, width: 120, height: 24)
        let nearbyPlacement = TranslationPanelPlacement.calculate(
            panelSize: CGSize(width: 720, height: 300),
            near: selection,
            fallbackPoint: .zero,
            in: visibleFrame
        )
        try expect(nearbyPlacement.side == .below, "选区下方空间充足时未向下贴近")
        try expect(abs(nearbyPlacement.frame.maxY - (selection.minY - 10)) < 0.01, "浮层未贴近选区")
        try expect(nearbyPlacement.frame.minX >= 12, "浮层越过屏幕左侧安全边距")

        let bottomSelection = CGRect(x: 1_300, y: 40, width: 80, height: 22)
        let flippedPlacement = TranslationPanelPlacement.calculate(
            panelSize: CGSize(width: 720, height: 300),
            near: bottomSelection,
            fallbackPoint: .zero,
            in: visibleFrame
        )
        try expect(flippedPlacement.side == .above, "选区下方空间不足时未翻转到上方")
        try expect(abs(flippedPlacement.frame.minY - (bottomSelection.maxY + 10)) < 0.01, "上方浮层未贴近选区")
        try expect(flippedPlacement.frame.maxX <= visibleFrame.maxX - 12, "浮层越过屏幕右侧安全边距")

        let stablePlacement = TranslationPanelPlacement.calculate(
            panelSize: CGSize(width: 720, height: 420),
            near: selection,
            fallbackPoint: .zero,
            in: visibleFrame,
            preferredSide: nearbyPlacement.side
        )
        try expect(stablePlacement.side == nearbyPlacement.side, "译文出现后浮层不应突然换边")

        let externalWindow = CGRect(x: -375, y: 1_117, width: 2_560, height: 1_440)
        let pointerOnBuiltInDisplay = CGPoint(x: 800, y: 500)
        let crossDisplayFallback = SelectionAnchorPolicy.fallback(
            pointer: pointerOnBuiltInDisplay,
            focusedWindow: externalWindow
        )
        try expect(
            crossDisplayFallback.origin == CGPoint(x: externalWindow.midX, y: externalWindow.midY),
            "鼠标不在当前窗口时应回退到当前窗口所在屏幕"
        )
        let pointerOnExternalDisplay = CGPoint(x: 400, y: 1_800)
        let pointerFallback = SelectionAnchorPolicy.fallback(
            pointer: pointerOnExternalDisplay,
            focusedWindow: externalWindow
        )
        try expect(pointerFallback.origin == pointerOnExternalDisplay, "鼠标位于当前窗口时应保留鼠标锚点")
        let invalidSelectionBounds = CGRect(x: 500, y: 300, width: 100, height: 20)
        try expect(
            SelectionAnchorPolicy.resolve(
                candidate: invalidSelectionBounds,
                fallback: crossDisplayFallback,
                focusedWindow: externalWindow
            ) == crossDisplayFallback,
            "落在其他屏幕的异常选区坐标未被拒绝"
        )

        let historyDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Transnap-SelfTests-\(UUID().uuidString)", isDirectory: true)
        let historyURL = historyDirectory.appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: historyDirectory) }

        let historyStore = TranslationHistoryStore(fileURL: historyURL, maximumEntryCount: 2)
        historyStore.add(source: "One", translation: "一", model: "fast", createdAt: Date(timeIntervalSince1970: 1))
        historyStore.add(source: "Two", translation: "二", model: "fast", createdAt: Date(timeIntervalSince1970: 2))
        historyStore.add(source: "Three", translation: "三", model: "fast", createdAt: Date(timeIntervalSince1970: 3))
        try expect(historyStore.entries.map(\.source) == ["Three", "Two"], "翻译历史数量或排序错误")

        let reloadedHistoryStore = TranslationHistoryStore(fileURL: historyURL, maximumEntryCount: 2)
        try expect(reloadedHistoryStore.entries == historyStore.entries, "翻译历史未正确持久化")
        reloadedHistoryStore.add(source: "Three", translation: "三", model: "fast")
        try expect(reloadedHistoryStore.entries.count == 2, "重复翻译历史未去重")
        try expect(reloadedHistoryStore.entries.first?.source == "Three", "重复历史未移动到最前")
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw SelfTestError.failed(message) }
    }
}
