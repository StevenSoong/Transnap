import AppKit

enum AccessibilityShortcutMonitorAction: Equatable {
    case none
    case stop
    case restart
}

enum AccessibilityShortcutMonitorTransition {
    static func action(
        previous: Bool?,
        current: Bool
    ) -> AccessibilityShortcutMonitorAction {
        guard previous != current else { return .none }
        return current ? .restart : .stop
    }
}

enum AccessibilityAuthorizationPhase: Equatable {
    case idle
    case dragging
    case dropped
}

struct AccessibilityAuthorizationPresentation: Equatable {
    let statusText: String
    let instructionText: String
    let buttonTitle: String
    let symbolName: String
    let showsDragSource: Bool

    static func make(
        isTrusted: Bool,
        canDragApplication: Bool,
        phase: AccessibilityAuthorizationPhase
    ) -> AccessibilityAuthorizationPresentation {
        if isTrusted {
            return AccessibilityAuthorizationPresentation(
                statusText: "已授权",
                instructionText: "权限已生效，可以读取其他 App 中选中的文字。",
                buttonTitle: "查看…",
                symbolName: "checkmark.circle.fill",
                showsDragSource: false
            )
        }

        guard canDragApplication else {
            return AccessibilityAuthorizationPresentation(
                statusText: "未授权",
                instructionText: "当前不是从 Transnap.app 运行。请先安装应用，或使用“打开设置…”手动添加。",
                buttonTitle: "打开设置…",
                symbolName: "exclamationmark.circle",
                showsDragSource: false
            )
        }

        switch phase {
        case .idle:
            return AccessibilityAuthorizationPresentation(
                statusText: "未授权",
                instructionText: "把闪译图标拖到系统设置的“辅助功能”列表，再打开右侧开关。",
                buttonTitle: "打开设置…",
                symbolName: "exclamationmark.circle",
                showsDragSource: true
            )
        case .dragging:
            return AccessibilityAuthorizationPresentation(
                statusText: "正在拖动",
                instructionText: "把图标放到系统设置的“辅助功能”列表中。",
                buttonTitle: "打开设置…",
                symbolName: "arrow.up.forward.circle",
                showsDragSource: true
            )
        case .dropped:
            return AccessibilityAuthorizationPresentation(
                statusText: "请确认",
                instructionText: "拖放已完成。请在系统设置中确认闪译已在列表，并打开右侧开关。",
                buttonTitle: "打开设置…",
                symbolName: "clock.badge.checkmark",
                showsDragSource: true
            )
        }
    }
}

enum AccessibilityDragPayload {
    static func applicationBundleURL(from bundleURL: URL) -> URL? {
        guard bundleURL.isFileURL,
              bundleURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
            return nil
        }
        return bundleURL.standardizedFileURL
    }

    static func pasteboardItem(for bundleURL: URL) -> NSPasteboardItem? {
        guard let applicationURL = applicationBundleURL(from: bundleURL) else { return nil }
        let item = NSPasteboardItem()
        guard item.setString(applicationURL.absoluteString, forType: .fileURL) else { return nil }
        return item
    }
}

@MainActor
final class ApplicationBundleDragView: NSView, NSDraggingSource {
    var applicationURL: URL? {
        didSet { updateApplicationIcon() }
    }
    var onDragBegan: (() -> Void)?
    var onDragEnded: ((Bool) -> Void)?

    private let imageView = NSImageView()
    private var initialMouseDownEvent: NSEvent?
    private var isDraggingApplication = false

    init(applicationURL: URL? = nil) {
        self.applicationURL = applicationURL
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        updateColors()

        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])

        toolTip = "把闪译拖到系统设置的辅助功能列表"
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("闪译应用图标，可拖到辅助功能设置")
        setAccessibilityHelp("拖动此图标到系统设置的辅助功能列表，然后打开闪译旁边的开关。")
        updateApplicationIcon()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: applicationURL == nil ? .arrow : .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        guard applicationURL != nil else {
            NSSound.beep()
            return
        }
        initialMouseDownEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isDraggingApplication,
              let applicationURL,
              let initialMouseDownEvent,
              let pasteboardItem = AccessibilityDragPayload.pasteboardItem(for: applicationURL)
        else { return }

        let start = initialMouseDownEvent.locationInWindow
        let current = event.locationInWindow
        guard hypot(current.x - start.x, current.y - start.y) >= 4 else { return }

        isDraggingApplication = true
        let item = NSDraggingItem(pasteboardWriter: pasteboardItem)
        item.setDraggingFrame(bounds.insetBy(dx: 4, dy: 4), contents: imageView.image)
        let session = beginDraggingSession(
            with: [item],
            event: event,
            source: self
        )
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func mouseUp(with event: NSEvent) {
        initialMouseDownEvent = nil
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        onDragBegan?()
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        initialMouseDownEvent = nil
        isDraggingApplication = false
        onDragEnded?(!operation.isEmpty)
    }

    private func updateApplicationIcon() {
        if let applicationURL {
            imageView.image = NSWorkspace.shared.icon(forFile: applicationURL.path)
        } else {
            imageView.image = NSImage(
                systemSymbolName: "app.dashed",
                accessibilityDescription: "当前应用不可拖动"
            )
        }
        window?.invalidateCursorRects(for: self)
    }

    private func updateColors() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor
    }
}
