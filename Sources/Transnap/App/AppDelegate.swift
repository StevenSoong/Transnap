import AppKit
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings()
    private let credentials = CredentialStore()
    private let selectionReader = SelectionReader()
    private let client = TranslationClient()
    private lazy var panelController = TranslationPanelController()
    private var documentationPanelController: TranslationPanelController?
    private var documentationPreviewDirectory: URL?
    private var documentationDefaultsSuiteName: String?
    private var statusItem: NSStatusItem?
    private var settingsController: SettingsWindowController!
    private var monitor: TranslationShortcutMonitor!
    private var translationTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--api-smoke-test") {
            return
        }

        if CommandLine.arguments.contains("--docs-settings-preview") {
            showDocumentationSettingsPreview()
            return
        }

        if CommandLine.arguments.contains("--docs-panel-preview")
            || CommandLine.arguments.contains("--docs-history-preview") {
            showDocumentationPanelPreview(
                expanded: CommandLine.arguments.contains("--docs-history-preview")
            )
            return
        }

        if CommandLine.arguments.contains("--settings-preview") {
            NSApplication.shared.setActivationPolicy(.regular)
            settingsController = SettingsWindowController(
                settings: settings,
                credentials: credentials,
                onShortcutChanged: { _ in }
            )
            settingsController.present()
            return
        }

        let isPanelPreview = CommandLine.arguments.contains("--panel-preview")
        let isLoadingPreview = CommandLine.arguments.contains("--loading-preview")
        let isLargePanelPreview = CommandLine.arguments.contains("--large-panel-preview")
        if isPanelPreview || isLoadingPreview || isLargePanelPreview {
            NSApplication.shared.setActivationPolicy(.regular)
            panelController.showLoading(
                source: isLargePanelPreview
                    ? String(repeating: "Great design should make complex information easier to understand. A thoughtful interface keeps the original text and its translation visible at the same time, while preserving enough room for longer paragraphs and translation history.\n\n", count: 3)
                    : "Great design makes complexity feel effortless. It doesn't show off technology; it helps people reach their goals naturally.",
                model: AppSettings.defaultModel,
                near: nil
            )
            NSApplication.shared.activate(ignoringOtherApps: true)
            if !isLoadingPreview {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    self?.panelController.finish(
                        isLargePanelPreview
                            ? String(repeating: "优秀的设计应当让复杂信息更容易理解。经过认真设计的界面会同时保留原文与译文，并为较长的段落和翻译历史留出足够空间。\n\n", count: 3)
                            : "优秀的设计，会让复杂的事物显得毫不费力。\n\n它不会炫耀技术，而是帮助人们自然地完成目标。"
                    )
                }
            }
            return
        }

        if CommandLine.arguments.contains("--status-item-test") {
            configureStatusItem()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                let visible = self?.statusItem?.isVisible == true
                let hasImage = self?.statusItem?.button?.image != nil
                print("status-item visible=\(visible) image=\(hasImage)")
                exit(visible && hasImage ? 0 : 1)
            }
            return
        }

        configureStatusItem()
        if CommandLine.arguments.contains("--reveal-status-item") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.statusItem?.button?.performClick(nil)
            }
        }
        credentials.importEnvironmentKeyIfNeeded()
        settingsController = SettingsWindowController(
            settings: settings,
            credentials: credentials
        ) { [weak self] shortcut in
            self?.monitor?.updateShortcut(shortcut)
        }
        panelController.onOpenSettings = { [weak self] in
            self?.settingsController.present()
        }
        monitor = TranslationShortcutMonitor(shortcut: settings.keyboardShortcut) { [weak self] point in
            self?.translateSelection(at: point)
        }
        monitor.start()

        if !AXIsProcessTrusted() || credentials.loadAPIKey() == nil {
            settingsController.present()
            if !AXIsProcessTrusted() { requestAccessibilityPermission() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        translationTask?.cancel()
        monitor?.stop()
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        if let suiteName = documentationDefaultsSuiteName {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        if let directory = documentationPreviewDirectory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { settingsController?.present() }
        return true
    }

    private func translateSelection(at point: CGPoint) {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            return
        }
        translationTask?.cancel()
        translationTask = Task { [weak self] in
            guard let self else { return }
            guard AXIsProcessTrusted() else {
                return
            }
            guard let apiKey = self.credentials.loadAPIKey(), !apiKey.isEmpty else {
                return
            }
            guard let captured = await self.selectionReader.capture(at: point) else {
                return
            }

            self.panelController.showLoading(source: captured.text, model: self.settings.model, near: captured.anchor)
            do {
                let result = try await self.client.translate(
                    text: captured.text,
                    context: captured.context,
                    apiKey: apiKey,
                    settings: self.settings.snapshot
                ) { [weak self] partial in
                    guard let self, self.settings.streamTranslation else { return }
                    self.panelController.updateTranslation(partial)
                }
                guard !Task.isCancelled else { return }
                self.panelController.finish(
                    result,
                    recordHistory: self.settings.saveTranslationHistory,
                    autoCopy: self.settings.autoCopyTranslation
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.panelController.showMessage(error.localizedDescription, near: captured.anchor)
            }
        }
    }

    private func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    @objc func translateFromMenuBar() {
        translateSelection(at: NSEvent.mouseLocation)
    }

    @objc func presentSettings() {
        settingsController?.present()
    }

    @objc private func quitApplication() {
        NSApplication.shared.terminate(nil)
    }

    private func configureStatusItem() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = Self.makeMenuBarIcon()
            button.imagePosition = .imageOnly
            button.toolTip = "Transnap · 闪译"
            button.setAccessibilityLabel("Transnap · 闪译")
        }

        let menu = NSMenu()
        let translateItem = NSMenuItem(
            title: "翻译当前选中文本",
            action: #selector(translateFromMenuBar),
            keyEquivalent: ""
        )
        translateItem.target = self
        menu.addItem(translateItem)
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "闪译设置…",
            action: #selector(presentSettings),
            keyEquivalent: ","
        )
        settingsItem.keyEquivalentModifierMask = [.command]
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(
            title: "退出 Transnap",
            action: #selector(quitApplication),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        item.isVisible = true
        statusItem = item
    }

    private func showDocumentationSettingsPreview() {
        NSApplication.shared.setActivationPolicy(.regular)
        let suiteName = "com.codex.Transnap.DocumentationPreview.\(ProcessInfo.processInfo.processIdentifier)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        defaults.removePersistentDomain(forName: suiteName)
        documentationDefaultsSuiteName = suiteName

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(suiteName, isDirectory: true)
        documentationPreviewDirectory = directory
        let previewSettings = AppSettings(defaults: defaults)
        previewSettings.baseURL = AppSettings.defaultBaseURL
        previewSettings.model = AppSettings.defaultModel
        let previewCredentials = CredentialStore(
            fileURL: directory.appendingPathComponent("api-key"),
            defaults: defaults
        )
        previewCredentials.saveAPIKey("transnap-documentation-demo-key")

        settingsController = SettingsWindowController(
            settings: previewSettings,
            credentials: previewCredentials,
            onShortcutChanged: { _ in }
        )
        settingsController.presentModelPage()
    }

    private func showDocumentationPanelPreview(expanded: Bool) {
        NSApplication.shared.setActivationPolicy(.regular)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "com.codex.Transnap.DocumentationPanel.\(ProcessInfo.processInfo.processIdentifier)",
                isDirectory: true
            )
        documentationPreviewDirectory = directory
        let history = TranslationHistoryStore(
            fileURL: directory.appendingPathComponent("history.json")
        )
        history.add(
            source: "Design is intelligence made visible.",
            translation: "设计，是看得见的智慧。",
            model: AppSettings.defaultModel
        )
        history.add(
            source: "Good tools stay out of the way.",
            translation: "好工具不会打扰你的思路。",
            model: AppSettings.defaultModel
        )
        let controller = TranslationPanelController(historyStore: history)
        documentationPanelController = controller

        let source = expanded
            ? String(repeating: "A thoughtful interface keeps the original text and its translation visible, while leaving enough room for context and history.\n\n", count: 4)
            : "Great design makes complexity feel effortless."
        controller.showLoading(source: source, model: AppSettings.defaultModel, near: nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            controller.finish(
                expanded
                    ? String(repeating: "经过认真设计的界面会同时保留原文与译文，也为上下文和翻译历史留出足够空间。\n\n", count: 4)
                    : "优秀的设计，会让复杂的事物显得毫不费力。"
            )
        }
    }

    private static func makeMenuBarIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()

            let bubble = NSBezierPath(
                roundedRect: NSRect(x: 2.25, y: 4.25, width: 13.5, height: 11.25),
                xRadius: 3,
                yRadius: 3
            )
            bubble.fill()

            let tail = NSBezierPath()
            tail.move(to: NSPoint(x: 5.3, y: 4.6))
            tail.line(to: NSPoint(x: 4.7, y: 1.7))
            tail.line(to: NSPoint(x: 8.9, y: 4.6))
            tail.close()
            tail.fill()

            NSGraphicsContext.current?.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .clear
            let bolt = NSBezierPath()
            bolt.move(to: NSPoint(x: 10.7, y: 13.8))
            bolt.line(to: NSPoint(x: 6.7, y: 9.0))
            bolt.line(to: NSPoint(x: 8.8, y: 9.0))
            bolt.line(to: NSPoint(x: 7.5, y: 5.1))
            bolt.line(to: NSPoint(x: 11.6, y: 10.3))
            bolt.line(to: NSPoint(x: 9.5, y: 10.3))
            bolt.close()
            bolt.fill()
            NSGraphicsContext.current?.restoreGraphicsState()
            return true
        }
        image.isTemplate = true
        return image
    }
}
