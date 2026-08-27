import AppKit

struct KeyboardShortcut: Equatable {
    static let defaultShortcut = KeyboardShortcut(
        keyCode: 17,
        modifiers: [.control, .option],
        keyLabel: "T"
    )

    static let supportedModifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags
    let keyLabel: String

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(Self.supportedModifiers)
        self.keyLabel = keyLabel
    }

    init?(event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(Self.supportedModifiers)
        guard !modifiers.isEmpty, event.keyCode != 53 else { return nil }

        let label = Self.label(for: event)
        guard !label.isEmpty else { return nil }
        self.init(keyCode: event.keyCode, modifiers: modifiers, keyLabel: label)
    }

    var displayString: String {
        var value = ""
        if modifiers.contains(.control) { value += "⌃" }
        if modifiers.contains(.option) { value += "⌥" }
        if modifiers.contains(.shift) { value += "⇧" }
        if modifiers.contains(.command) { value += "⌘" }
        return value + keyLabel
    }

    func matches(keyCode: UInt16, modifiers eventModifiers: NSEvent.ModifierFlags) -> Bool {
        keyCode == self.keyCode
            && eventModifiers.intersection(Self.supportedModifiers) == modifiers
    }

    private static func label(for event: NSEvent) -> String {
        switch event.keyCode {
        case 36: return "↩"
        case 48: return "⇥"
        case 49: return "Space"
        case 51: return "⌫"
        case 115: return "Home"
        case 116: return "Page Up"
        case 117: return "⌦"
        case 119: return "End"
        case 121: return "Page Down"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default:
            return (event.charactersIgnoringModifiers ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
        }
    }
}
