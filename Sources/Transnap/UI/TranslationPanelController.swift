import AppKit

private enum TranslationPanelPalette {
    static let canvas = NSColor(calibratedRed: 0.976, green: 0.978, blue: 0.984, alpha: 1)
    static let sidebar = NSColor(calibratedRed: 0.941, green: 0.945, blue: 0.955, alpha: 1)
    static let sourcePane = NSColor(calibratedRed: 0.956, green: 0.959, blue: 0.966, alpha: 1)
    static let translationPane = NSColor(calibratedRed: 0.988, green: 0.989, blue: 0.992, alpha: 1)
    static let primaryText = NSColor(calibratedWhite: 0.13, alpha: 1)
    static let secondaryText = NSColor(calibratedWhite: 0.40, alpha: 1)
    static let tertiaryText = NSColor(calibratedWhite: 0.61, alpha: 1)
    static let divider = NSColor(calibratedWhite: 0.84, alpha: 1)
    static let skeleton = NSColor(calibratedWhite: 0.84, alpha: 1)
    static let accent = NSColor(calibratedRed: 0.08, green: 0.42, blue: 0.93, alpha: 1)
}

enum TranslationLayoutPolicy {
    static let longTextCharacterThreshold = 420
    static let longTextLineThreshold = 8

    static func usesLargeWindow(for source: String) -> Bool {
        let logicalLineCount = source.split(separator: "\n", omittingEmptySubsequences: false).count
        return source.count >= longTextCharacterThreshold || logicalLineCount >= longTextLineThreshold
    }
}

enum TranslationPanelVerticalSide {
    case below
    case above
}

struct TranslationPanelPlacement {
    let frame: CGRect
    let side: TranslationPanelVerticalSide

    static func calculate(
        panelSize requestedSize: CGSize,
        near requestedAnchor: CGRect?,
        fallbackPoint: CGPoint,
        in visibleFrame: CGRect,
        preferredSide: TranslationPanelVerticalSide? = nil,
        gap: CGFloat = 10,
        margin: CGFloat = 12
    ) -> TranslationPanelPlacement {
        let safeFrame = visibleFrame.insetBy(dx: margin, dy: margin)
        let size = CGSize(
            width: min(requestedSize.width, safeFrame.width),
            height: min(requestedSize.height, safeFrame.height)
        )
        let anchor = validAnchor(requestedAnchor)
            ?? CGRect(origin: fallbackPoint, size: .zero)

        let roomBelow = anchor.minY - safeFrame.minY - gap
        let roomAbove = safeFrame.maxY - anchor.maxY - gap
        let side = preferredSide ?? {
            if roomBelow >= size.height { return .below }
            if roomAbove >= size.height { return .above }
            return roomBelow >= roomAbove ? .below : .above
        }()

        // Keep the selection near the leading part of the panel instead of
        // centering a wide translation window hundreds of points away from it.
        let horizontalInset = min(112, size.width * 0.22)
        var origin = CGPoint(
            x: anchor.midX - horizontalInset,
            y: side == .below
                ? anchor.minY - gap - size.height
                : anchor.maxY + gap
        )
        origin.x = clamp(origin.x, lower: safeFrame.minX, upper: safeFrame.maxX - size.width)
        origin.y = clamp(origin.y, lower: safeFrame.minY, upper: safeFrame.maxY - size.height)
        return TranslationPanelPlacement(frame: CGRect(origin: origin, size: size), side: side)
    }

    private static func validAnchor(_ value: CGRect?) -> CGRect? {
        guard let value,
              value.origin.x.isFinite,
              value.origin.y.isFinite,
              value.size.width.isFinite,
              value.size.height.isFinite else { return nil }
        return value.standardized
    }

    private static func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        min(max(value, lower), max(lower, upper))
    }
}

@MainActor
final class TranslationPanelController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let titleLabel = NSTextField(labelWithString: "闪译")
    private let appIconView = NSImageView()
    private let layoutButton = NSButton()
    private let settingsButton = NSButton()
    private let sourceView = NSTextView()
    private let translationView = NSTextView()
    private let historyContainer = NSView()
    private let historySeparator = NSView()
    private let paneSeparator = NSView()
    private let historyTable = NSTableView()
    private let historyEmptyIcon = NSImageView()
    private let historyEmptyLabel = NSTextField(labelWithString: "暂无翻译记录")
    private let historyEmptyHint = NSTextField(labelWithString: "完成翻译后会保存在这里")
    private let translationPlaceholderLabel = NSTextField(labelWithString: "译文会在这里出现")
    private let translationSkeleton = TranslationSkeletonView()
    private let contentStack = NSStackView()
    private let footerLabel = NSTextField(labelWithString: "")
    private let copyButton = NSButton()
    private let closeButton = NSButton()
    private let historyStore: TranslationHistoryStore

    private let compactMainWidth: CGFloat = 720
    private let historySidebarWidth: CGFloat = 244
    private var latestTranslation = ""
    private var currentSource = ""
    private var currentModel = ""
    private var currentAnchor: CGRect?
    private var placementSide: TranslationPanelVerticalSide?
    private var usesLargeLayout = false
    private var historyExpanded = false
    private var recordsHistory: Bool {
        !CommandLine.arguments.contains("--panel-preview")
            && !CommandLine.arguments.contains("--loading-preview")
            && !CommandLine.arguments.contains("--large-panel-preview")
            && !CommandLine.arguments.contains("--docs-panel-preview")
            && !CommandLine.arguments.contains("--docs-history-preview")
    }

    var onOpenSettings: (() -> Void)?

    init(historyStore: TranslationHistoryStore = TranslationHistoryStore()) {
        self.historyStore = historyStore
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: compactMainWidth, height: 320),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.animationBehavior = .utilityWindow
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        super.init(window: panel)
        buildContent(in: panel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func showLoading(source: String, model: String, near anchor: CGRect?) {
        latestTranslation = ""
        currentSource = source
        currentModel = model
        currentAnchor = anchor
        placementSide = nil
        usesLargeLayout = TranslationLayoutPolicy.usesLargeWindow(for: source)
        setHistoryExpanded(usesLargeLayout, animated: false, resize: false)
        reloadHistory()
        titleLabel.stringValue = "闪译"
        setText(source, in: sourceView, weight: .regular)
        setText("", in: translationView, weight: .regular)
        footerLabel.stringValue = "正在翻译"
        footerLabel.textColor = TranslationPanelPalette.secondaryText
        showSpinner(true)
        copyButton.isEnabled = false
        resizePanel(animated: false)
        showWindow(nil)
        window?.orderFrontRegardless()
    }

    func updateTranslation(_ value: String) {
        latestTranslation = value
        setText(value, in: translationView, weight: .regular)
        if !value.isEmpty {
            translationSkeleton.stopAnimating()
        }
        translationView.scrollToEndOfDocument(nil)
        copyButton.isEnabled = !value.isEmpty
    }

    func finish(_ value: String, recordHistory: Bool = true, autoCopy: Bool = false) {
        updateTranslation(value)
        showSpinner(false)
        if autoCopy {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            footerLabel.stringValue = "已自动复制 · 由 \(currentModel) 翻译"
        } else {
            footerLabel.stringValue = "由 \(currentModel) 翻译"
        }
        footerLabel.textColor = TranslationPanelPalette.secondaryText
        if recordsHistory, recordHistory {
            historyStore.add(source: currentSource, translation: value, model: currentModel)
            reloadHistory()
        }
        resizePanel(animated: true)
    }

    func showMessage(_ message: String, near anchor: CGRect? = nil, isError: Bool = true) {
        latestTranslation = ""
        currentSource = isError ? "无法翻译" : "提示"
        currentModel = ""
        currentAnchor = anchor
        placementSide = nil
        usesLargeLayout = false
        setHistoryExpanded(false, animated: false, resize: false)
        titleLabel.stringValue = "闪译"
        setText(currentSource, in: sourceView, weight: .regular)
        setText(message, in: translationView, weight: .regular)
        showSpinner(false)
        footerLabel.stringValue = isError ? "请检查设置或网络" : "Transnap"
        footerLabel.textColor = isError ? .systemRed : TranslationPanelPalette.secondaryText
        copyButton.isEnabled = false
        resizePanel(animated: false)
        showWindow(nil)
        window?.orderFrontRegardless()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        historyStore.entries.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard historyStore.entries.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("TranslationHistoryCell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? TranslationHistoryCellView)
            ?? TranslationHistoryCellView(identifier: identifier)
        cell.configure(with: historyStore.entries[row])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = historyTable.selectedRow
        guard historyStore.entries.indices.contains(row) else { return }
        let entry = historyStore.entries[row]
        currentSource = entry.source
        latestTranslation = entry.translation
        currentModel = entry.model
        setText(entry.source, in: sourceView, weight: .regular)
        setText(entry.translation, in: translationView, weight: .regular)
        showSpinner(false)
        footerLabel.stringValue = "\(Self.fullDateFormatter.string(from: entry.createdAt)) · \(entry.model)"
        footerLabel.textColor = TranslationPanelPalette.secondaryText
        copyButton.isEnabled = true
    }

    private func buildContent(in panel: NSPanel) {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.cornerRadius = 16
        root.layer?.masksToBounds = true
        root.layer?.backgroundColor = TranslationPanelPalette.canvas.cgColor
        root.layer?.borderWidth = 0.75
        root.layer?.borderColor = TranslationPanelPalette.divider.withAlphaComponent(0.9).cgColor
        panel.contentView = root

        configureHeader(in: root)
        configureContent(in: root)
    }

    private func configureHeader(in root: NSView) {
        let headerSymbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)

        closeButton.title = ""
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭")?
            .withSymbolConfiguration(headerSymbolConfiguration)
        closeButton.imagePosition = .imageOnly
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.isBordered = false
        closeButton.contentTintColor = TranslationPanelPalette.secondaryText
        closeButton.focusRingType = .none
        closeButton.toolTip = "关闭"
        closeButton.setAccessibilityLabel("关闭")
        closeButton.target = self
        closeButton.action = #selector(closePanel)
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        if let icon = NSApplication.shared.applicationIconImage.copy() as? NSImage {
            icon.size = NSSize(width: 18, height: 18)
            appIconView.image = icon
        }
        appIconView.imageScaling = .scaleProportionallyDown
        appIconView.translatesAutoresizingMaskIntoConstraints = false

        layoutButton.title = ""
        layoutButton.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "展开窗口")?
            .withSymbolConfiguration(headerSymbolConfiguration)
        layoutButton.imagePosition = .imageOnly
        layoutButton.imageScaling = .scaleProportionallyDown
        layoutButton.isBordered = false
        layoutButton.controlSize = .small
        layoutButton.contentTintColor = TranslationPanelPalette.secondaryText
        layoutButton.focusRingType = .none
        layoutButton.toolTip = "展开大窗口与翻译历史"
        layoutButton.setAccessibilityLabel("展开大窗口与翻译历史")
        layoutButton.target = self
        layoutButton.action = #selector(togglePanelLayout)
        layoutButton.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 15.5, weight: .semibold)
        titleLabel.textColor = TranslationPanelPalette.primaryText
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        settingsButton.title = ""
        settingsButton.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "打开闪译设置")?
            .withSymbolConfiguration(headerSymbolConfiguration)
        settingsButton.imagePosition = .imageOnly
        settingsButton.imageScaling = .scaleProportionallyDown
        settingsButton.isBordered = false
        settingsButton.controlSize = .small
        settingsButton.contentTintColor = TranslationPanelPalette.secondaryText
        settingsButton.focusRingType = .none
        settingsButton.toolTip = "打开闪译设置"
        settingsButton.setAccessibilityLabel("打开闪译设置")
        settingsButton.target = self
        settingsButton.action = #selector(openSettings)
        settingsButton.translatesAutoresizingMaskIntoConstraints = false

        [closeButton, appIconView, titleLabel, layoutButton, settingsButton].forEach(root.addSubview)

        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 9),
            closeButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 24),
            closeButton.heightAnchor.constraint(equalToConstant: 24),

            appIconView.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 7),
            appIconView.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            appIconView.widthAnchor.constraint(equalToConstant: 18),
            appIconView.heightAnchor.constraint(equalToConstant: 18),

            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 15),
            titleLabel.leadingAnchor.constraint(equalTo: appIconView.trailingAnchor, constant: 6),

            settingsButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -13),
            settingsButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            settingsButton.widthAnchor.constraint(equalToConstant: 26),
            settingsButton.heightAnchor.constraint(equalToConstant: 24),

            layoutButton.trailingAnchor.constraint(equalTo: settingsButton.leadingAnchor, constant: -5),
            layoutButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            layoutButton.widthAnchor.constraint(equalToConstant: 26),
            layoutButton.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    private func configureContent(in root: NSView) {
        configureHistorySidebar()

        let sourceColumn = textColumn(
            title: "原文",
            textView: sourceView,
            backgroundColor: TranslationPanelPalette.sourcePane
        )
        let translationColumn = textColumn(
            title: "译文",
            textView: translationView,
            backgroundColor: TranslationPanelPalette.translationPane
        )

        paneSeparator.wantsLayer = true
        paneSeparator.layer?.backgroundColor = TranslationPanelPalette.divider.cgColor
        paneSeparator.translatesAutoresizingMaskIntoConstraints = false
        paneSeparator.widthAnchor.constraint(equalToConstant: 1).isActive = true

        let textColumns = NSStackView(views: [sourceColumn, paneSeparator, translationColumn])
        textColumns.orientation = .horizontal
        textColumns.alignment = .top
        textColumns.distribution = .fill
        textColumns.spacing = 0
        textColumns.translatesAutoresizingMaskIntoConstraints = false
        sourceColumn.widthAnchor.constraint(equalTo: translationColumn.widthAnchor).isActive = true

        historySeparator.wantsLayer = true
        historySeparator.layer?.backgroundColor = TranslationPanelPalette.divider.cgColor
        historySeparator.translatesAutoresizingMaskIntoConstraints = false
        historySeparator.widthAnchor.constraint(equalToConstant: 1).isActive = true

        contentStack.orientation = .horizontal
        contentStack.alignment = .top
        contentStack.distribution = .fill
        contentStack.spacing = 0
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(historyContainer)
        contentStack.addArrangedSubview(historySeparator)
        contentStack.addArrangedSubview(textColumns)

        root.addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 13),
            contentStack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            historyContainer.widthAnchor.constraint(equalToConstant: historySidebarWidth),
            historyContainer.heightAnchor.constraint(equalTo: contentStack.heightAnchor),
            historySeparator.heightAnchor.constraint(equalTo: contentStack.heightAnchor),
            paneSeparator.heightAnchor.constraint(equalTo: contentStack.heightAnchor),
            textColumns.heightAnchor.constraint(equalTo: contentStack.heightAnchor),
        ])
    }

    private func configureHistorySidebar() {
        historyContainer.wantsLayer = true
        historyContainer.layer?.backgroundColor = TranslationPanelPalette.sidebar.cgColor
        historyContainer.translatesAutoresizingMaskIntoConstraints = false

        let historyTitle = NSTextField(labelWithString: "翻译历史")
        historyTitle.font = .systemFont(ofSize: 12.5, weight: .semibold)
        historyTitle.textColor = TranslationPanelPalette.secondaryText
        historyTitle.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("History"))
        column.resizingMask = .autoresizingMask
        historyTable.addTableColumn(column)
        historyTable.headerView = nil
        historyTable.rowHeight = 56
        historyTable.intercellSpacing = NSSize(width: 0, height: 2)
        historyTable.backgroundColor = .clear
        historyTable.style = .plain
        historyTable.selectionHighlightStyle = .regular
        historyTable.dataSource = self
        historyTable.delegate = self
        historyTable.focusRingType = .none

        let scroll = NSScrollView()
        scroll.documentView = historyTable
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        historyEmptyIcon.image = NSImage(
            systemSymbolName: "clock.arrow.circlepath",
            accessibilityDescription: "暂无翻译记录"
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 19, weight: .regular))
        historyEmptyIcon.contentTintColor = TranslationPanelPalette.tertiaryText
        historyEmptyIcon.translatesAutoresizingMaskIntoConstraints = false

        historyEmptyLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        historyEmptyLabel.textColor = TranslationPanelPalette.secondaryText
        historyEmptyLabel.alignment = .center
        historyEmptyLabel.translatesAutoresizingMaskIntoConstraints = false

        historyEmptyHint.font = .systemFont(ofSize: 11)
        historyEmptyHint.textColor = TranslationPanelPalette.tertiaryText
        historyEmptyHint.alignment = .center
        historyEmptyHint.translatesAutoresizingMaskIntoConstraints = false

        [historyTitle, scroll, historyEmptyIcon, historyEmptyLabel, historyEmptyHint]
            .forEach(historyContainer.addSubview)
        NSLayoutConstraint.activate([
            historyTitle.topAnchor.constraint(equalTo: historyContainer.topAnchor, constant: 15),
            historyTitle.leadingAnchor.constraint(equalTo: historyContainer.leadingAnchor, constant: 16),

            scroll.topAnchor.constraint(equalTo: historyTitle.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: historyContainer.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: historyContainer.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: historyContainer.bottomAnchor, constant: -8),

            historyEmptyIcon.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            historyEmptyIcon.centerYAnchor.constraint(equalTo: scroll.centerYAnchor, constant: -24),

            historyEmptyLabel.topAnchor.constraint(equalTo: historyEmptyIcon.bottomAnchor, constant: 9),
            historyEmptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),

            historyEmptyHint.topAnchor.constraint(equalTo: historyEmptyLabel.bottomAnchor, constant: 4),
            historyEmptyHint.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
        ])
    }

    private func textColumn(title: String, textView: NSTextView, backgroundColor: NSColor) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = backgroundColor.cgColor
        container.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11.5, weight: .semibold)
        label.textColor = TranslationPanelPalette.secondaryText
        label.translatesAutoresizingMaskIntoConstraints = false

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 3)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(label)
        container.addSubview(scroll)
        if textView === translationView {
            footerLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
            footerLabel.textColor = TranslationPanelPalette.secondaryText
            footerLabel.lineBreakMode = .byTruncatingTail
            footerLabel.translatesAutoresizingMaskIntoConstraints = false

            let copySymbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            configureFooterButton(
                copyButton,
                symbolName: "doc.on.doc",
                accessibilityDescription: "复制译文",
                toolTip: "复制译文",
                action: #selector(copyTranslation),
                symbolConfiguration: copySymbolConfiguration
            )

            translationPlaceholderLabel.font = .systemFont(ofSize: 13)
            translationPlaceholderLabel.textColor = TranslationPanelPalette.tertiaryText
            translationPlaceholderLabel.alignment = .center
            translationPlaceholderLabel.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(translationPlaceholderLabel)
            translationSkeleton.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(translationSkeleton)
            container.addSubview(footerLabel)
            container.addSubview(copyButton)
        }
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 15),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),

            scroll.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 11),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
        ])
        if textView === translationView {
            let translationFooterRule = separatorView()
            container.addSubview(translationFooterRule)
            NSLayoutConstraint.activate([
                scroll.bottomAnchor.constraint(equalTo: translationFooterRule.topAnchor),

                translationPlaceholderLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
                translationPlaceholderLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor, constant: -4),

                translationSkeleton.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 22),
                translationSkeleton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
                translationSkeleton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
                translationSkeleton.heightAnchor.constraint(equalToConstant: 74),

                copyButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -9),
                copyButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -7),
                copyButton.widthAnchor.constraint(equalToConstant: 26),
                copyButton.heightAnchor.constraint(equalToConstant: 26),

                footerLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
                footerLabel.centerYAnchor.constraint(equalTo: copyButton.centerYAnchor),
                footerLabel.trailingAnchor.constraint(lessThanOrEqualTo: copyButton.leadingAnchor, constant: -10),

                translationFooterRule.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                translationFooterRule.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                translationFooterRule.heightAnchor.constraint(equalToConstant: 1),
                translationFooterRule.bottomAnchor.constraint(equalTo: copyButton.topAnchor, constant: -7),
            ])
        } else {
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16).isActive = true
        }
        return container
    }

    private func configureFooterButton(
        _ button: NSButton,
        symbolName: String,
        accessibilityDescription: String,
        toolTip: String,
        action: Selector,
        symbolConfiguration: NSImage.SymbolConfiguration
    ) {
        button.title = ""
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityDescription)?
            .withSymbolConfiguration(symbolConfiguration)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.isBordered = false
        button.contentTintColor = TranslationPanelPalette.secondaryText
        button.focusRingType = .none
        button.toolTip = toolTip
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    private func separatorView() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = TranslationPanelPalette.divider.cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    private func setText(_ text: String, in textView: NSTextView, weight: NSFont.Weight) {
        let isTranslation = textView === translationView
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        paragraph.paragraphSpacing = 6
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: isTranslation ? 16 : 14.5, weight: weight),
                .foregroundColor: isTranslation
                    ? TranslationPanelPalette.primaryText
                    : TranslationPanelPalette.secondaryText,
                .paragraphStyle: paragraph,
            ]
        )
        textView.textStorage?.setAttributedString(attributed)
        if isTranslation {
            translationPlaceholderLabel.isHidden = !text.isEmpty
        }
    }

    private func reloadHistory() {
        historyTable.reloadData()
        let hasHistory = !historyStore.entries.isEmpty
        historyEmptyIcon.isHidden = hasHistory
        historyEmptyLabel.isHidden = hasHistory
        historyEmptyHint.isHidden = hasHistory
    }

    private func setHistoryExpanded(_ expanded: Bool, animated: Bool, resize: Bool) {
        historyExpanded = expanded
        historyContainer.isHidden = !expanded
        historySeparator.isHidden = !expanded
        layoutButton.image = NSImage(
            systemSymbolName: expanded
                ? "arrow.down.right.and.arrow.up.left"
                : "arrow.up.left.and.arrow.down.right",
            accessibilityDescription: expanded ? "收回紧凑窗口" : "展开窗口"
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium))
        layoutButton.contentTintColor = expanded
            ? TranslationPanelPalette.accent
            : TranslationPanelPalette.secondaryText
        layoutButton.toolTip = expanded ? "收回紧凑窗口" : "展开大窗口与翻译历史"
        layoutButton.setAccessibilityLabel(expanded ? "收回紧凑窗口" : "展开大窗口与翻译历史")
        if resize {
            resizePanel(animated: animated)
        }
    }

    private func showSpinner(_ visible: Bool) {
        if visible {
            translationPlaceholderLabel.isHidden = true
            translationSkeleton.startAnimating()
        } else {
            translationSkeleton.stopAnimating()
        }
    }

    private func desiredPanelSize(on screen: NSScreen?) -> NSSize {
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        if usesLargeLayout {
            let expandedWidth = min(max(visible.width * 0.70, 900), visible.width - 24)
            let height = min(max(visible.height * 0.69, 560), visible.height - 24)
            return NSSize(width: expandedWidth, height: height)
        }

        let collapsedWidth = min(compactMainWidth, visible.width - 24)
        let textWidth = max((collapsedWidth - 82) / 2, 220)
        let sourceHeight = measuredHeight(currentSource, width: textWidth, weight: .regular)
        let translationHeight = measuredHeight(latestTranslation, width: textWidth, weight: .regular)
        let contentHeight = max(sourceHeight, translationHeight, 62)
        let height = min(max(174 + contentHeight, 300), min(470, visible.height - 24))
        return NSSize(width: collapsedWidth, height: height)
    }

    private func measuredHeight(_ text: String, width: CGFloat, weight: NSFont.Weight) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [
                .font: NSFont.systemFont(ofSize: 15.5, weight: weight),
                .paragraphStyle: paragraph,
            ]
        )
        return ceil(bounds.height)
    }

    private func resizePanel(animated: Bool) {
        guard let window else { return }
        let fallbackPoint = currentAnchor.map { CGPoint(x: $0.midX, y: $0.midY) }
            ?? NSEvent.mouseLocation
        let screen = targetScreen(for: currentAnchor, fallbackPoint: fallbackPoint)
        let visible = screen?.visibleFrame ?? .zero
        let size = desiredPanelSize(on: screen)
        let placement = TranslationPanelPlacement.calculate(
            panelSize: size,
            near: currentAnchor,
            fallbackPoint: fallbackPoint,
            in: visible,
            preferredSide: placementSide
        )
        placementSide = placement.side
        let frame = placement.frame
        if animated, window.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().setFrame(frame, display: true)
            }
        } else {
            window.setFrame(frame, display: true)
        }
    }

    private func targetScreen(for anchor: CGRect?, fallbackPoint: CGPoint) -> NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return NSScreen.main }

        if let anchor, !anchor.isNull, !anchor.isInfinite {
            var bestScreen: NSScreen?
            var bestArea: CGFloat = 0
            for screen in screens {
                let intersection = screen.frame.intersection(anchor)
                guard !intersection.isNull else { continue }
                let area = intersection.width * intersection.height
                if area > bestArea {
                    bestArea = area
                    bestScreen = screen
                }
            }
            if let bestScreen { return bestScreen }
        }
        if let containing = screens.first(where: { $0.frame.contains(fallbackPoint) }) {
            return containing
        }
        return screens.min {
            squaredDistance(from: fallbackPoint, to: $0.frame)
                < squaredDistance(from: fallbackPoint, to: $1.frame)
        }
    }

    private func squaredDistance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(max(rect.minX - point.x, point.x - rect.maxX), 0)
        let dy = max(max(rect.minY - point.y, point.y - rect.maxY), 0)
        return dx * dx + dy * dy
    }

    @objc private func togglePanelLayout() {
        usesLargeLayout.toggle()
        setHistoryExpanded(usesLargeLayout, animated: true, resize: true)
    }

    @objc private func copyTranslation() {
        guard !latestTranslation.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(latestTranslation, forType: .string)
        footerLabel.stringValue = "已复制"
    }

    @objc private func closePanel() {
        window?.orderOut(nil)
        if CommandLine.arguments.contains("--panel-preview")
            || CommandLine.arguments.contains("--loading-preview")
            || CommandLine.arguments.contains("--large-panel-preview")
            || CommandLine.arguments.contains("--docs-panel-preview")
            || CommandLine.arguments.contains("--docs-history-preview") {
            NSApplication.shared.terminate(nil)
        }
    }

    @objc private func openSettings() {
        window?.orderOut(nil)
        onOpenSettings?()
    }

    private static let fullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

private final class TranslationSkeletonView: NSView {
    private let lines = (0..<4).map { _ in NSView() }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true
        setAccessibilityElement(false)

        lines.forEach { line in
            line.wantsLayer = true
            line.layer?.backgroundColor = TranslationPanelPalette.skeleton.cgColor
            line.layer?.cornerRadius = 5
            line.layer?.opacity = 0.56
            line.translatesAutoresizingMaskIntoConstraints = false
            addSubview(line)
            line.heightAnchor.constraint(equalToConstant: 10).isActive = true
            line.leadingAnchor.constraint(equalTo: leadingAnchor).isActive = true
        }

        NSLayoutConstraint.activate([
            lines[0].topAnchor.constraint(equalTo: topAnchor),
            lines[0].widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.88),

            lines[1].topAnchor.constraint(equalTo: lines[0].bottomAnchor, constant: 10),
            lines[1].widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.72),

            lines[2].topAnchor.constraint(equalTo: lines[1].bottomAnchor, constant: 10),
            lines[2].widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.81),

            lines[3].topAnchor.constraint(equalTo: lines[2].bottomAnchor, constant: 10),
            lines[3].widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.54),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func startAnimating() {
        isHidden = false
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }

        for (index, line) in lines.enumerated() {
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = 0.34
            animation.toValue = 0.72
            animation.duration = 0.82
            animation.beginTime = CACurrentMediaTime() + Double(index) * 0.08
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            line.layer?.add(animation, forKey: "skeleton-opacity")
        }
    }

    func stopAnimating() {
        isHidden = true
        lines.forEach { $0.layer?.removeAnimation(forKey: "skeleton-opacity") }
    }
}

private final class TranslationHistoryCellView: NSTableCellView {
    private let sourceLabel = NSTextField(labelWithString: "")
    private let translationLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        sourceLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        sourceLabel.textColor = TranslationPanelPalette.primaryText
        sourceLabel.lineBreakMode = .byTruncatingTail
        sourceLabel.maximumNumberOfLines = 1

        translationLabel.font = .systemFont(ofSize: 11.5)
        translationLabel.textColor = TranslationPanelPalette.secondaryText
        translationLabel.lineBreakMode = .byTruncatingTail
        translationLabel.maximumNumberOfLines = 1

        dateLabel.font = .systemFont(ofSize: 10)
        dateLabel.textColor = TranslationPanelPalette.tertiaryText
        dateLabel.alignment = .right

        [sourceLabel, translationLabel, dateLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }

        NSLayoutConstraint.activate([
            sourceLabel.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            sourceLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            sourceLabel.trailingAnchor.constraint(lessThanOrEqualTo: dateLabel.leadingAnchor, constant: -7),

            dateLabel.centerYAnchor.constraint(equalTo: sourceLabel.centerYAnchor),
            dateLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            dateLabel.widthAnchor.constraint(equalToConstant: 54),

            translationLabel.topAnchor.constraint(equalTo: sourceLabel.bottomAnchor, constant: 5),
            translationLabel.leadingAnchor.constraint(equalTo: sourceLabel.leadingAnchor),
            translationLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(with entry: TranslationHistoryEntry) {
        sourceLabel.stringValue = entry.source.replacingOccurrences(of: "\n", with: " ")
        translationLabel.stringValue = entry.translation.replacingOccurrences(of: "\n", with: " ")
        dateLabel.stringValue = Self.timeFormatter.string(from: entry.createdAt)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
}
