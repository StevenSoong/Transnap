import AppKit

@MainActor
final class ShortcutRecorderButton: NSButton {
    var onChange: ((KeyboardShortcut) -> Void)?

    var shortcut: KeyboardShortcut = .defaultShortcut {
        didSet {
            if !isRecording { title = shortcut.displayString }
        }
    }

    private(set) var isRecording = false

    init() {
        super.init(frame: .zero)
        title = shortcut.displayString
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(beginRecording)
        toolTip = "点击后按下新的快捷键"
        setAccessibilityLabel("翻译快捷键")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    @objc private func beginRecording() {
        isRecording = true
        title = "请按组合键…"
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        capture(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }
        capture(event)
        return true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        title = shortcut.displayString
        return super.resignFirstResponder()
    }

    private func capture(_ event: NSEvent) {
        guard !event.isARepeat else { return }
        if event.keyCode == 53 {
            isRecording = false
            title = shortcut.displayString
            window?.makeFirstResponder(nil)
            return
        }
        guard let recorded = KeyboardShortcut(event: event) else {
            NSSound.beep()
            title = "请同时按修饰键和普通按键"
            return
        }
        shortcut = recorded
        onChange?(recorded)
        isRecording = false
        window?.makeFirstResponder(nil)
    }
}
