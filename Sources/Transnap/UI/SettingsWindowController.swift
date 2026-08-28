import AppKit
import ApplicationServices

private final class SettingsCardView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        if #available(macOS 14.0, *) {
            layer?.backgroundColor = NSColor.quinarySystemFill.cgColor
        } else {
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        }
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.22).cgColor
    }
}

@MainActor
final class SettingsWindowController: NSWindowController,
    NSTableViewDataSource,
    NSTableViewDelegate,
    NSTextFieldDelegate,
    NSTextViewDelegate,
    NSWindowDelegate
{
    private enum Section: Int, CaseIterable {
        case general
        case translation
        case model

        var title: String {
            switch self {
            case .general: return "通用"
            case .translation: return "翻译"
            case .model: return "模型"
            }
        }

        var subtitle: String {
            switch self {
            case .general: return "快捷键、系统权限与本地记录"
            case .translation: return "译文方向、生成方式与翻译指令"
            case .model: return "远程模型接口与访问凭证"
            }
        }

        var symbolName: String {
            switch self {
            case .general: return "gearshape"
            case .translation: return "character.bubble"
            case .model: return "cpu"
            }
        }
    }

    private let settings: AppSettings
    private let credentials: CredentialStore
    private let accessibilityTrustProvider: () -> Bool
    private let onAccessibilityChanged: (Bool) -> Void
    private let onShortcutChanged: (KeyboardShortcut) -> Void

    private let sidebarTable = NSTableView()
    private let detailHost = NSView()
    private var pageViews: [Section: NSView] = [:]
    private var selectedSection = Section.general
    private var isLoadingValues = false

    private let shortcutRecorder = ShortcutRecorderButton()
    private let permissionStatusIcon = NSImageView()
    private let permissionStatusLabel = NSTextField(labelWithString: "")
    private let permissionInstructionLabel = NSTextField(labelWithString: "")
    private let permissionButton = NSButton()
    private let permissionDragView = ApplicationBundleDragView(
        applicationURL: AccessibilityDragPayload.applicationBundleURL(from: Bundle.main.bundleURL)
    )
    private let saveHistorySwitch = NSSwitch()
    private var permissionPhase = AccessibilityAuthorizationPhase.idle
    private var lastPermissionTrusted: Bool?
    private var permissionPollTimer: Timer?

    private let targetPopup = NSPopUpButton()
    private let streamSwitch = NSSwitch()
    private let autoCopySwitch = NSSwitch()
    private let promptTextView = NSTextView()
    private let promptStatusLabel = NSTextField(labelWithString: "")

    private let keyField = NSSecureTextField()
    private let baseURLField = NSTextField()
    private let modelField = NSTextField()
    private let modelStatusLabel = NSTextField(labelWithString: "")

    init(
        settings: AppSettings,
        credentials: CredentialStore,
        accessibilityTrustProvider: @escaping () -> Bool = { AXIsProcessTrusted() },
        onAccessibilityChanged: @escaping (Bool) -> Void = { _ in },
        onShortcutChanged: @escaping (KeyboardShortcut) -> Void
    ) {
        self.settings = settings
        self.credentials = credentials
        self.accessibilityTrustProvider = accessibilityTrustProvider
        self.onAccessibilityChanged = onAccessibilityChanged
        self.onShortcutChanged = onShortcutChanged

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 530),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "闪译设置"
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.center()

        super.init(window: window)
        window.delegate = self
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        buildUI(in: window)
        configureActions()
        loadValues()
        showSection(.general)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        permissionPollTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    func present() {
        loadValues()
        showSection(selectedSection)
        NSApplication.shared.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        startPermissionPolling()
    }

    func presentModelPage() {
        selectedSection = .model
        present()
    }

    private func buildUI(in window: NSWindow) {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = root

        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.state = .active
        sidebar.translatesAutoresizingMaskIntoConstraints = false

        let sidebarRule = NSBox()
        sidebarRule.boxType = .separator
        sidebarRule.translatesAutoresizingMaskIntoConstraints = false

        detailHost.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(sidebar)
        root.addSubview(sidebarRule)
        root.addSubview(detailHost)

        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 184),

            sidebarRule.topAnchor.constraint(equalTo: root.topAnchor),
            sidebarRule.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            sidebarRule.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebarRule.widthAnchor.constraint(equalToConstant: 1),

            detailHost.topAnchor.constraint(equalTo: root.topAnchor),
            detailHost.leadingAnchor.constraint(equalTo: sidebarRule.trailingAnchor),
            detailHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            detailHost.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        configureSidebar(sidebar)
        configurePages()
    }

    private func configureSidebar(_ sidebar: NSView) {
        let appIcon = NSImageView()
        appIcon.image = NSApplication.shared.applicationIconImage
        appIcon.imageScaling = .scaleProportionallyDown
        appIcon.translatesAutoresizingMaskIntoConstraints = false

        let heading = NSTextField(labelWithString: "闪译")
        heading.font = .systemFont(ofSize: 13.5, weight: .semibold)
        heading.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SettingsSidebar"))
        column.resizingMask = .autoresizingMask
        sidebarTable.addTableColumn(column)
        sidebarTable.headerView = nil
        sidebarTable.backgroundColor = .clear
        sidebarTable.style = .sourceList
        sidebarTable.rowHeight = 32
        sidebarTable.intercellSpacing = NSSize(width: 0, height: 3)
        sidebarTable.allowsEmptySelection = false
        sidebarTable.allowsMultipleSelection = false
        sidebarTable.focusRingType = .none
        sidebarTable.dataSource = self
        sidebarTable.delegate = self
        scrollView.documentView = sidebarTable

        sidebar.addSubview(appIcon)
        sidebar.addSubview(heading)
        sidebar.addSubview(scrollView)
        NSLayoutConstraint.activate([
            appIcon.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 16),
            appIcon.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 16),
            appIcon.widthAnchor.constraint(equalToConstant: 30),
            appIcon.heightAnchor.constraint(equalToConstant: 30),

            heading.leadingAnchor.constraint(equalTo: appIcon.trailingAnchor, constant: 9),
            heading.trailingAnchor.constraint(lessThanOrEqualTo: sidebar.trailingAnchor, constant: -14),
            heading.centerYAnchor.constraint(equalTo: appIcon.centerYAnchor),

            scrollView.topAnchor.constraint(equalTo: appIcon.bottomAnchor, constant: 14),
            scrollView.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 10),
            scrollView.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),
            scrollView.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -12),
        ])
    }

    private func configurePages() {
        let pages: [(Section, NSView)] = [
            (.general, makeGeneralPage()),
            (.translation, makeTranslationPage()),
            (.model, makeModelPage()),
        ]

        for (section, page) in pages {
            page.translatesAutoresizingMaskIntoConstraints = false
            detailHost.addSubview(page)
            NSLayoutConstraint.activate([
                page.topAnchor.constraint(equalTo: detailHost.topAnchor),
                page.leadingAnchor.constraint(equalTo: detailHost.leadingAnchor),
                page.trailingAnchor.constraint(equalTo: detailHost.trailingAnchor),
                page.bottomAnchor.constraint(equalTo: detailHost.bottomAnchor),
            ])
            pageViews[section] = page
        }
    }

    private func makeGeneralPage() -> NSView {
        shortcutRecorder.controlSize = .regular
        shortcutRecorder.widthAnchor.constraint(equalToConstant: 150).isActive = true

        configureSwitch(saveHistorySwitch)

        let basics = settingsGroup([
            settingRow(title: "翻译快捷键", control: shortcutRecorder),
            makeAccessibilityPermissionRow(),
        ])
        let records = settingsGroup([
            settingRow(
                title: "保存翻译历史",
                subtitle: "关闭后停止新增记录，已有历史会继续保留。",
                control: saveHistorySwitch
            ),
        ])

        return page(
            section: .general,
            blocks: [
                sectionBlock(title: "基础", body: basics),
                sectionBlock(title: "记录", body: records),
            ]
        )
    }

    private func makeAccessibilityPermissionRow() -> NSView {
        let row = NSView()

        let titleLabel = NSTextField(labelWithString: "辅助功能")
        titleLabel.font = .systemFont(ofSize: 12.5)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let subtitleLabel = NSTextField(labelWithString: "闪译仅使用此权限读取其他 App 中选中的文字。")
        subtitleLabel.font = .systemFont(ofSize: 10.5)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        permissionStatusIcon.imageScaling = .scaleProportionallyDown
        permissionStatusIcon.translatesAutoresizingMaskIntoConstraints = false
        permissionStatusIcon.widthAnchor.constraint(equalToConstant: 15).isActive = true
        permissionStatusIcon.heightAnchor.constraint(equalToConstant: 15).isActive = true

        permissionStatusLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        permissionStatusLabel.setContentHuggingPriority(.required, for: .horizontal)
        permissionStatusLabel.setAccessibilityLabel("辅助功能权限状态")

        let statusStack = NSStackView(views: [permissionStatusIcon, permissionStatusLabel])
        statusStack.orientation = .horizontal
        statusStack.alignment = .centerY
        statusStack.spacing = 5

        permissionButton.bezelStyle = .rounded
        permissionButton.controlSize = .small

        let headerControls = NSStackView(views: [statusStack, permissionButton])
        headerControls.orientation = .horizontal
        headerControls.alignment = .centerY
        headerControls.spacing = 9
        headerControls.translatesAutoresizingMaskIntoConstraints = false
        headerControls.setContentHuggingPriority(.required, for: .horizontal)
        headerControls.setContentCompressionResistancePriority(.required, for: .horizontal)

        permissionDragView.translatesAutoresizingMaskIntoConstraints = false
        permissionDragView.widthAnchor.constraint(equalToConstant: 44).isActive = true
        permissionDragView.heightAnchor.constraint(equalToConstant: 44).isActive = true

        permissionInstructionLabel.font = .systemFont(ofSize: 10.5)
        permissionInstructionLabel.textColor = .secondaryLabelColor
        permissionInstructionLabel.lineBreakMode = .byWordWrapping
        permissionInstructionLabel.maximumNumberOfLines = 2
        permissionInstructionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let instructionStack = NSStackView(views: [permissionDragView, permissionInstructionLabel])
        instructionStack.orientation = .horizontal
        instructionStack.alignment = .centerY
        instructionStack.spacing = 10
        instructionStack.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(titleLabel)
        row.addSubview(subtitleLabel)
        row.addSubview(headerControls)
        row.addSubview(instructionStack)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: row.topAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: headerControls.leadingAnchor, constant: -12),

            headerControls.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -13),
            headerControls.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -14),

            instructionStack.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 9),
            instructionStack.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            instructionStack.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),
            instructionStack.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -10),
        ])
        return row
    }

    private func makeTranslationPage() -> NSView {
        TargetLanguage.allCases.forEach { targetPopup.addItem(withTitle: $0.title) }
        targetPopup.controlSize = .regular
        targetPopup.widthAnchor.constraint(equalToConstant: 235).isActive = true
        configureSwitch(streamSwitch)
        configureSwitch(autoCopySwitch)

        let behavior = settingsGroup([
            settingRow(title: "目标语言", control: targetPopup),
            settingRow(
                title: "边生成边显示",
                subtitle: "模型输出时同步更新译文。",
                control: streamSwitch
            ),
            settingRow(
                title: "自动复制译文",
                subtitle: "翻译完成后写入剪贴板。",
                control: autoCopySwitch
            ),
        ])

        return page(
            section: .translation,
            blocks: [
                sectionBlock(title: "翻译行为", body: behavior),
                sectionBlock(title: "翻译提示词", body: makePromptEditor()),
            ]
        )
    }

    private func makeModelPage() -> NSView {
        keyField.placeholderString = "输入接口密钥"
        baseURLField.placeholderString = AppSettings.defaultBaseURL
        modelField.placeholderString = AppSettings.defaultModel

        for field in [keyField, baseURLField, modelField] {
            field.controlSize = .regular
            field.delegate = self
            field.widthAnchor.constraint(equalToConstant: 292).isActive = true
        }

        let connection = settingsGroup([
            settingRow(title: "接口密钥", control: keyField),
            settingRow(title: "接口地址", control: baseURLField),
            settingRow(title: "模型名称", control: modelField),
        ])

        let resetButton = NSButton(title: "恢复默认接口与模型", target: self, action: #selector(resetModel))
        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .regular
        let defaultsGroup = settingsGroup([
            settingRow(
                title: "默认模型",
                subtitle: "恢复推荐的接口地址与快速模型。",
                control: resetButton
            ),
        ])

        configureStatusLabel(modelStatusLabel)
        modelStatusLabel.stringValue = "密钥仅保存在当前 Mac 的私有配置文件中，不随应用或源码分发。"

        return page(
            section: .model,
            blocks: [
                sectionBlock(title: "连接", body: connection, footer: modelStatusLabel),
                sectionBlock(title: "默认值", body: defaultsGroup),
            ]
        )
    }

    private func makePromptEditor() -> NSView {
        promptTextView.isRichText = false
        promptTextView.isAutomaticQuoteSubstitutionEnabled = false
        promptTextView.isAutomaticDashSubstitutionEnabled = false
        promptTextView.font = .systemFont(ofSize: 12.5)
        promptTextView.textContainerInset = NSSize(width: 11, height: 10)
        promptTextView.isHorizontallyResizable = false
        promptTextView.textContainer?.widthTracksTextView = true
        promptTextView.drawsBackground = false
        promptTextView.delegate = self

        let scrollView = NSScrollView()
        scrollView.documentView = promptTextView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let separator = horizontalSeparator()
        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false

        let helper = NSTextField(labelWithString: "{target_language} 会替换为当前目标语言")
        helper.font = .systemFont(ofSize: 10.5)
        helper.textColor = .secondaryLabelColor
        helper.translatesAutoresizingMaskIntoConstraints = false

        let resetButton = NSButton(title: "恢复默认", target: self, action: #selector(resetPrompt))
        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .small
        resetButton.translatesAutoresizingMaskIntoConstraints = false

        footer.addSubview(helper)
        footer.addSubview(resetButton)
        NSLayoutConstraint.activate([
            helper.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 14),
            helper.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            helper.trailingAnchor.constraint(lessThanOrEqualTo: resetButton.leadingAnchor, constant: -10),

            resetButton.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -12),
            resetButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            footer.heightAnchor.constraint(equalToConstant: 42),
        ])

        let card = SettingsCardView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(scrollView)
        card.addSubview(separator)
        card.addSubview(footer)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: card.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: 145),

            separator.topAnchor.constraint(equalTo: scrollView.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            separator.trailingAnchor.constraint(equalTo: card.trailingAnchor),

            footer.topAnchor.constraint(equalTo: separator.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])

        configureStatusLabel(promptStatusLabel)
        promptStatusLabel.stringValue = "更改会自动保存。"

        let wrapper = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        promptStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(card)
        wrapper.addSubview(promptStatusLabel)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: wrapper.topAnchor),
            card.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),

            promptStatusLabel.topAnchor.constraint(equalTo: card.bottomAnchor, constant: 6),
            promptStatusLabel.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 3),
            promptStatusLabel.trailingAnchor.constraint(lessThanOrEqualTo: wrapper.trailingAnchor),
            promptStatusLabel.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
        ])
        return wrapper
    }

    private func page(section: Section, blocks: [NSView]) -> NSView {
        let container = NSView()

        let title = NSTextField(labelWithString: section.title)
        title.font = .systemFont(ofSize: 21, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = NSTextField(labelWithString: section.subtitle)
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        let contentStack = NSStackView(views: blocks)
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 19
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        for block in blocks {
            block.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }

        container.addSubview(title)
        container.addSubview(subtitle)
        container.addSubview(contentStack)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 25),
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 30),
            title.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -30),

            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -30),

            contentStack.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 23),
            contentStack.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -30),
            contentStack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -20),
        ])
        return container
    }

    private func sectionBlock(title: String, body: NSView, footer: NSView? = nil) -> NSView {
        let container = NSView()
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 11.5, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        body.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(titleLabel)
        container.addSubview(body)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 3),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),

            body.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 7),
            body.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        if let footer {
            footer.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(footer)
            NSLayoutConstraint.activate([
                footer.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 6),
                footer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 3),
                footer.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
                footer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        } else {
            body.bottomAnchor.constraint(equalTo: container.bottomAnchor).isActive = true
        }
        return container
    }

    private func settingsGroup(_ rows: [NSView]) -> NSView {
        let card = SettingsCardView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false

        for (index, row) in rows.enumerated() {
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            if index < rows.count - 1 {
                let separator = horizontalSeparator()
                stack.addArrangedSubview(separator)
                separator.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -14).isActive = true
            }
        }

        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        return card
    }

    private func settingRow(title: String, subtitle: String? = nil, control: NSView) -> NSView {
        let row = NSView()
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12.5)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        control.translatesAutoresizingMaskIntoConstraints = false
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)

        row.addSubview(titleLabel)
        row.addSubview(control)

        if let subtitle {
            let subtitleLabel = NSTextField(labelWithString: subtitle)
            subtitleLabel.font = .systemFont(ofSize: 10.5)
            subtitleLabel.textColor = .secondaryLabelColor
            subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(subtitleLabel)
            NSLayoutConstraint.activate([
                titleLabel.topAnchor.constraint(equalTo: row.topAnchor, constant: 10),
                titleLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
                titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -14),

                subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
                subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
                subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -14),
                subtitleLabel.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -8),

                control.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -13),
                control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                row.heightAnchor.constraint(equalToConstant: 56),
            ])
        } else {
            NSLayoutConstraint.activate([
                titleLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
                titleLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -14),

                control.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -13),
                control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                row.heightAnchor.constraint(equalToConstant: 48),
            ])
        }
        return row
    }

    private func horizontalSeparator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return separator
    }

    private func configureSwitch(_ control: NSSwitch) {
        control.controlSize = .mini
        control.setContentHuggingPriority(.required, for: .horizontal)
    }

    private func configureStatusLabel(_ label: NSTextField) {
        label.font = .systemFont(ofSize: 10.5)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
    }

    private func configureActions() {
        shortcutRecorder.onChange = { [weak self] shortcut in
            guard let self else { return }
            self.settings.keyboardShortcut = shortcut
            self.onShortcutChanged(shortcut)
        }

        permissionButton.target = self
        permissionButton.action = #selector(requestAccessibility)
        permissionDragView.onDragBegan = { [weak self] in
            guard let self else { return }
            self.permissionPhase = .dragging
            self.updatePermissionStatus()
            self.openAccessibilitySettings()
        }
        permissionDragView.onDragEnded = { [weak self] wasAccepted in
            guard let self else { return }
            self.permissionPhase = wasAccepted ? .dropped : .idle
            self.updatePermissionStatus()
        }

        saveHistorySwitch.target = self
        saveHistorySwitch.action = #selector(saveHistoryChanged)
        targetPopup.target = self
        targetPopup.action = #selector(targetLanguageChanged)
        streamSwitch.target = self
        streamSwitch.action = #selector(streamChanged)
        autoCopySwitch.target = self
        autoCopySwitch.action = #selector(autoCopyChanged)
    }

    private func loadValues() {
        isLoadingValues = true
        defer { isLoadingValues = false }

        keyField.stringValue = credentials.loadAPIKey() ?? ""
        baseURLField.stringValue = settings.baseURL
        modelField.stringValue = settings.model
        shortcutRecorder.shortcut = settings.keyboardShortcut
        saveHistorySwitch.state = settings.saveTranslationHistory ? .on : .off

        let targetIndex = TargetLanguage.allCases.firstIndex(of: settings.targetLanguage) ?? 0
        targetPopup.selectItem(at: targetIndex)
        streamSwitch.state = settings.streamTranslation ? .on : .off
        autoCopySwitch.state = settings.autoCopyTranslation ? .on : .off
        promptTextView.string = settings.translationPrompt

        promptStatusLabel.textColor = .secondaryLabelColor
        promptStatusLabel.stringValue = "更改会自动保存。"
        modelStatusLabel.textColor = .secondaryLabelColor
        modelStatusLabel.stringValue = "密钥仅保存在当前 Mac 的私有配置文件中，不随应用或源码分发。"
        updatePermissionStatus()
    }

    private func showSection(_ section: Section) {
        selectedSection = section
        for (candidate, page) in pageViews {
            page.isHidden = candidate != section
        }
        if sidebarTable.selectedRow != section.rawValue {
            sidebarTable.selectRowIndexes(IndexSet(integer: section.rawValue), byExtendingSelection: false)
        }
    }

    private func updatePermissionStatus() {
        let trusted = accessibilityTrustProvider()
        if trusted {
            permissionPhase = .idle
        }
        let presentation = AccessibilityAuthorizationPresentation.make(
            isTrusted: trusted,
            canDragApplication: permissionDragView.applicationURL != nil,
            phase: permissionPhase
        )

        permissionStatusIcon.image = NSImage(
            systemSymbolName: presentation.symbolName,
            accessibilityDescription: presentation.statusText
        )
        permissionStatusIcon.contentTintColor = trusted
            ? .systemGreen
            : permissionPhase == .dropped ? .systemOrange : .secondaryLabelColor
        permissionStatusLabel.stringValue = presentation.statusText
        permissionStatusLabel.textColor = trusted
            ? .systemGreen
            : permissionPhase == .dropped ? .systemOrange : .secondaryLabelColor
        permissionStatusLabel.setAccessibilityValue(presentation.statusText)
        permissionInstructionLabel.stringValue = presentation.instructionText
        permissionInstructionLabel.setAccessibilityLabel(presentation.instructionText)
        permissionButton.title = presentation.buttonTitle
        permissionButton.setAccessibilityLabel(
            trusted ? "查看辅助功能设置" : "打开辅助功能设置"
        )
        permissionDragView.isHidden = !presentation.showsDragSource

        let didChange = lastPermissionTrusted.map { $0 != trusted } ?? false
        lastPermissionTrusted = trusted
        if didChange {
            onAccessibilityChanged(trusted)
        }
    }

    private func persistEditableValues() {
        persistPrompt(showFeedback: false)
        persistModel(showFeedback: false)
    }

    private func persistPrompt(showFeedback: Bool) {
        let value = promptTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            promptStatusLabel.textColor = .systemRed
            promptStatusLabel.stringValue = "提示词不能为空，已保留上次设置。"
            return
        }
        settings.translationPrompt = value
        if showFeedback {
            promptStatusLabel.textColor = .systemGreen
            promptStatusLabel.stringValue = "更改已保存"
        }
    }

    private func persistModel(showFeedback: Bool) {
        credentials.saveAPIKey(keyField.stringValue)
        let baseURL = baseURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (try? TranslationClient.endpoint(from: baseURL)) != nil, !model.isEmpty else {
            modelStatusLabel.textColor = .systemRed
            modelStatusLabel.stringValue = "接口地址或模型名称无效，已保留上次设置。"
            return
        }
        settings.baseURL = baseURL
        settings.model = model
        if showFeedback {
            modelStatusLabel.textColor = .systemGreen
            modelStatusLabel.stringValue = "更改已保存"
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        Section.allCases.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        32
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let section = Section(rawValue: row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("SettingsSidebarCell")
        if let existing = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            existing.textField?.stringValue = section.title
            existing.imageView?.image = sidebarImage(for: section)
            return existing
        }

        let cell = NSTableCellView()
        cell.identifier = identifier

        let imageView = NSImageView()
        imageView.image = sidebarImage(for: section)
        imageView.imageScaling = .scaleProportionallyDown
        imageView.contentTintColor = .secondaryLabelColor
        imageView.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: section.title)
        label.font = .systemFont(ofSize: 12.5, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        cell.imageView = imageView
        cell.textField = label
        cell.addSubview(imageView)
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 17),
            imageView.heightAnchor.constraint(equalToConstant: 17),

            label.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -7),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isLoadingValues,
              sidebarTable.selectedRow >= 0,
              let section = Section(rawValue: sidebarTable.selectedRow)
        else { return }
        if section != selectedSection {
            persistEditableValues()
            showSection(section)
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard !isLoadingValues, let field = obj.object as? NSTextField else { return }
        if field === keyField {
            credentials.saveAPIKey(keyField.stringValue)
            modelStatusLabel.textColor = .systemGreen
            modelStatusLabel.stringValue = keyField.stringValue.isEmpty ? "接口密钥已清除" : "接口密钥已保存"
        } else if field === baseURLField || field === modelField {
            persistModel(showFeedback: true)
        }
    }

    func textDidEndEditing(_ notification: Notification) {
        guard !isLoadingValues else { return }
        persistPrompt(showFeedback: true)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        updatePermissionStatus()
        startPermissionPolling()
    }

    func windowWillClose(_ notification: Notification) {
        stopPermissionPolling()
        permissionPhase = .idle
        persistEditableValues()
    }

    @objc private func applicationDidBecomeActive(_ notification: Notification) {
        guard window?.isVisible == true else { return }
        updatePermissionStatus()
        startPermissionPolling()
    }

    private func startPermissionPolling() {
        guard permissionPollTimer == nil, window?.isVisible == true else { return }
        let timer = Timer(
            timeInterval: 0.75,
            target: self,
            selector: #selector(pollAccessibilityPermission),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        permissionPollTimer = timer
    }

    private func stopPermissionPolling() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
    }

    @objc private func pollAccessibilityPermission() {
        guard window?.isVisible == true else {
            stopPermissionPolling()
            return
        }
        updatePermissionStatus()
    }

    private func sidebarImage(for section: Section) -> NSImage? {
        NSImage(
            systemSymbolName: section.symbolName,
            accessibilityDescription: section.title
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
    }

    @objc private func requestAccessibility() {
        openAccessibilitySettings()
        updatePermissionStatus()
    }

    private func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func saveHistoryChanged() {
        guard !isLoadingValues else { return }
        settings.saveTranslationHistory = saveHistorySwitch.state == .on
    }

    @objc private func targetLanguageChanged() {
        guard !isLoadingValues, targetPopup.indexOfSelectedItem >= 0 else { return }
        settings.targetLanguage = TargetLanguage.allCases[targetPopup.indexOfSelectedItem]
    }

    @objc private func streamChanged() {
        guard !isLoadingValues else { return }
        settings.streamTranslation = streamSwitch.state == .on
    }

    @objc private func autoCopyChanged() {
        guard !isLoadingValues else { return }
        settings.autoCopyTranslation = autoCopySwitch.state == .on
    }

    @objc private func resetPrompt() {
        promptTextView.string = AppSettings.defaultTranslationPrompt
        settings.translationPrompt = AppSettings.defaultTranslationPrompt
        promptStatusLabel.textColor = .systemGreen
        promptStatusLabel.stringValue = "已恢复默认提示词"
    }

    @objc private func resetModel() {
        baseURLField.stringValue = AppSettings.defaultBaseURL
        modelField.stringValue = AppSettings.defaultModel
        settings.baseURL = AppSettings.defaultBaseURL
        settings.model = AppSettings.defaultModel
        modelStatusLabel.textColor = .systemGreen
        modelStatusLabel.stringValue = "已恢复默认接口与模型"
    }
}
