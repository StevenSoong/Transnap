import AppKit

@MainActor
final class TranslationShortcutMonitor {
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var shortcut: KeyboardShortcut
    private var lastTrigger = Date.distantPast
    private let onTrigger: (CGPoint) -> Void

    init(shortcut: KeyboardShortcut, onTrigger: @escaping (CGPoint) -> Void) {
        self.shortcut = shortcut
        self.onTrigger = onTrigger
    }

    func start() {
        guard globalKeyMonitor == nil, localKeyMonitor == nil else { return }

        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let modifiers = event.modifierFlags
            let isRepeat = event.isARepeat
            DispatchQueue.main.async {
                self?.handle(keyCode: keyCode, modifiers: modifiers, isRepeat: isRepeat)
            }
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(keyCode: event.keyCode, modifiers: event.modifierFlags, isRepeat: event.isARepeat)
            return event
        }
    }

    func updateShortcut(_ shortcut: KeyboardShortcut) {
        self.shortcut = shortcut
    }

    func stop() {
        [globalKeyMonitor, localKeyMonitor]
            .compactMap { $0 }
            .forEach(NSEvent.removeMonitor)
        globalKeyMonitor = nil
        localKeyMonitor = nil
    }

    private func handle(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, isRepeat: Bool) {
        guard !isRepeat, shortcut.matches(keyCode: keyCode, modifiers: modifiers) else { return }
        let now = Date()
        guard now.timeIntervalSince(lastTrigger) > 0.45 else { return }
        lastTrigger = now
        onTrigger(NSEvent.mouseLocation)
    }

    deinit {
        [globalKeyMonitor, localKeyMonitor]
            .compactMap { $0 }
            .forEach(NSEvent.removeMonitor)
    }
}
