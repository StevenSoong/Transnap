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
        try expect(body["chat_template_kwargs"] == nil, "通用模型请求携带了 GLM 专用字段")
        try expect(body["stream"] as? Bool == true, "翻译请求未启用流式响应")
        let messages = body["messages"] as? [[String: String]]
        try expect(
            messages?.first?["content"] == "Translate to 简体中文.",
            "自定义翻译提示词或目标语言变量未生效"
        )

        let contextualBody = TranslationClient.requestBody(
            text: "bank",
            context: TranslationContext(
                before: "She deposited the cheque at the",
                after: "before it closed."
            ),
            settings: settings
        )
        let contextualMessages = contextualBody["messages"] as? [[String: String]]
        let contextualUserMessage = contextualMessages?.last?["content"] ?? ""
        let contextualPayload = contextualUserMessage.data(using: .utf8).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: String]
        }
        try expect(contextualPayload?["text_to_translate"] == "bank", "上下文请求丢失待翻译词")
        try expect(
            contextualPayload?["context_before"] == "She deposited the cheque at the",
            "上下文请求丢失前文"
        )
        try expect(
            contextualMessages?.first?["content"]?.contains("只翻译 text_to_translate") == true,
            "上下文请求未限制模型只翻译选中词"
        )

        let contextSource = "She deposited the cheque at the bank before it closed."
        let bankRange = (contextSource as NSString).range(of: "bank")
        let nearbyContext = SelectionContextPolicy.context(
            in: contextSource,
            selectionRange: bankRange,
            selectedText: "bank"
        )
        try expect(nearbyContext?.before == "She deposited the cheque at the", "未正确截取前文")
        try expect(nearbyContext?.after == "before it closed.", "未正确截取后文")
        try expect(
            SelectionContextPolicy.context(
                in: contextSource,
                selectionRange: NSRange(location: 0, length: contextSource.utf16.count),
                selectedText: contextSource
            ) == nil,
            "长句不应额外读取上下文"
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

        let shortcut = KeyboardShortcut(keyCode: 17, modifiers: [.control, .option], keyLabel: "T")
        try expect(shortcut.displayString == "⌃⌥T", "快捷键显示错误")
        try expect(shortcut.matches(keyCode: 17, modifiers: [.control, .option]), "正确快捷键未匹配")
        try expect(!shortcut.matches(keyCode: 17, modifiers: [.control, .option, .shift]), "额外修饰键不应匹配")
        try expect(!shortcut.matches(keyCode: 16, modifiers: [.control, .option]), "错误普通按键不应匹配")

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
