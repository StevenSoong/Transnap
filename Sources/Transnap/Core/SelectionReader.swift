import AppKit
import ApplicationServices
import NaturalLanguage

struct CapturedText {
    let text: String
    let anchor: CGRect?
}

enum SelectionAnchorPolicy {
    static func fallback(pointer: CGPoint, focusedWindow: CGRect?) -> CGRect {
        guard let focusedWindow,
              focusedWindow.width > 0,
              focusedWindow.height > 0,
              !focusedWindow.isNull,
              !focusedWindow.isInfinite else {
            return CGRect(origin: pointer, size: .zero)
        }
        if focusedWindow.contains(pointer) {
            return CGRect(origin: pointer, size: .zero)
        }
        return CGRect(
            origin: CGPoint(x: focusedWindow.midX, y: focusedWindow.midY),
            size: .zero
        )
    }

    static func resolve(candidate: CGRect?, fallback: CGRect, focusedWindow: CGRect?) -> CGRect {
        guard let candidate,
              candidate.origin.x.isFinite,
              candidate.origin.y.isFinite,
              candidate.size.width.isFinite,
              candidate.size.height.isFinite else {
            return fallback
        }
        guard let focusedWindow,
              focusedWindow.width > 0,
              focusedWindow.height > 0 else {
            return candidate.standardized
        }

        let tolerance = focusedWindow.insetBy(dx: -80, dy: -80)
        let normalized = candidate.standardized
        return tolerance.contains(CGPoint(x: normalized.midX, y: normalized.midY))
            ? normalized
            : fallback
    }
}

@MainActor
final class SelectionReader {
    private let systemWide = AXUIElementCreateSystemWide()
    private let maximumLength = 12_000

    func capture(at appKitPoint: CGPoint) async -> CapturedText? {
        let focusedWindow = focusedWindowFrame()
        let fallbackAnchor = SelectionAnchorPolicy.fallback(
            pointer: appKitPoint,
            focusedWindow: focusedWindow
        )
        try? await Task.sleep(nanoseconds: 90_000_000)

        if let selected = focusedSelection(), !selected.text.isEmpty {
            return CapturedText(
                text: selected.text,
                anchor: SelectionAnchorPolicy.resolve(
                    candidate: selected.anchor,
                    fallback: fallbackAnchor,
                    focusedWindow: focusedWindow
                )
            )
        }
        let pointerIsInFocusedWindow = focusedWindow?.contains(appKitPoint) ?? true
        if pointerIsInFocusedWindow,
           let pointed = wordAtPoint(appKitPoint),
           !pointed.text.isEmpty {
            return CapturedText(
                text: pointed.text,
                anchor: SelectionAnchorPolicy.resolve(
                    candidate: pointed.anchor,
                    fallback: fallbackAnchor,
                    focusedWindow: focusedWindow
                )
            )
        }
        return await copySelectionFromFrontmostApplication(anchor: fallbackAnchor)
    }

    private func focusedSelection() -> CapturedText? {
        guard let rawElement = copyAttribute(systemWide, kAXFocusedUIElementAttribute as CFString),
              CFGetTypeID(rawElement) == AXUIElementGetTypeID() else {
            return nil
        }
        let element = unsafeBitCast(rawElement, to: AXUIElement.self)
        guard let rawText = copyAttribute(element, kAXSelectedTextAttribute as CFString) as? String else { return nil }
        let text = normalized(rawText)
        guard !text.isEmpty else { return nil }
        let bounds = copyAttribute(element, kAXSelectedTextRangeAttribute as CFString)
            .flatMap { rangeValue in boundsForRange(rangeValue, in: element) }
        return CapturedText(text: text, anchor: bounds.map(axRectToAppKit))
    }

    private func wordAtPoint(_ appKitPoint: CGPoint) -> CapturedText? {
        let axPoint = appKitPointToAX(appKitPoint)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(axPoint.x), Float(axPoint.y), &element) == .success,
              let element else { return nil }

        var point = axPoint
        guard let pointValue = AXValueCreate(.cgPoint, &point),
              let rawRange = copyParameterizedAttribute(
                element,
                kAXRangeForPositionParameterizedAttribute as CFString,
                pointValue
              ),
              let cursorRange = cfRange(from: rawRange) else { return nil }

        guard let value = copyAttribute(element, kAXValueAttribute as CFString) as? String,
              value.utf16.count <= 1_000_000,
              let token = tokenRange(in: value, utf16Offset: cursorRange.location) else { return nil }

        let text = normalized(String(value[token]))
        guard !text.isEmpty else { return nil }
        let nsRange = NSRange(token, in: value)
        var selectedRange = CFRange(location: nsRange.location, length: nsRange.length)
        let bounds = AXValueCreate(.cfRange, &selectedRange)
            .flatMap { boundsForRange($0, in: element) }
        return CapturedText(text: text, anchor: bounds.map(axRectToAppKit))
    }

    private func tokenRange(in text: String, utf16Offset: Int) -> Range<String.Index>? {
        guard !text.isEmpty else { return nil }
        let safeOffset = min(max(utf16Offset, 0), max(text.utf16.count - 1, 0))
        guard let utf16Index = text.utf16.index(text.utf16.startIndex, offsetBy: safeOffset, limitedBy: text.utf16.endIndex),
              let index = String.Index(utf16Index, within: text) else { return nil }

        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        let range = tokenizer.tokenRange(at: index)
        if !range.isEmpty {
            return range
        }

        let next = text.index(after: index)
        return index..<next
    }

    private func copySelectionFromFrontmostApplication(anchor: CGRect) async -> CapturedText? {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        let changeCount = pasteboard.changeCount

        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false) else { return nil }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        try? await Task.sleep(nanoseconds: 130_000_000)

        guard pasteboard.changeCount != changeCount else { return nil }
        let copied = pasteboard.string(forType: .string)
        snapshot.restore(to: pasteboard)
        guard let copied else { return nil }
        let text = normalized(copied)
        guard !text.isEmpty else { return nil }
        return CapturedText(text: text, anchor: anchor)
    }

    private func normalized(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maximumLength else { return trimmed }
        let end = trimmed.index(trimmed.startIndex, offsetBy: maximumLength)
        return String(trimmed[..<end])
    }

    private func copyAttribute(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value
    }

    private func copyParameterizedAttribute(
        _ element: AXUIElement,
        _ attribute: CFString,
        _ parameter: CFTypeRef
    ) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, attribute, parameter, &value) == .success else {
            return nil
        }
        return value
    }

    private func cfRange(from value: CFTypeRef) -> CFRange? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        return AXValueGetValue(axValue, .cfRange, &range) ? range : nil
    }

    private func boundsForRange(_ rangeValue: CFTypeRef, in element: AXUIElement) -> CGRect? {
        guard let rawBounds = copyParameterizedAttribute(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue
        ), CFGetTypeID(rawBounds) == AXValueGetTypeID() else { return nil }
        let value = rawBounds as! AXValue
        guard AXValueGetType(value) == .cgRect else { return nil }
        var rect = CGRect.zero
        return AXValueGetValue(value, .cgRect, &rect) ? rect : nil
    }

    private func focusedWindowFrame() -> CGRect? {
        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        guard let rawWindow = copyAttribute(appElement, kAXFocusedWindowAttribute as CFString),
              CFGetTypeID(rawWindow) == AXUIElementGetTypeID() else { return nil }
        let window = unsafeBitCast(rawWindow, to: AXUIElement.self)
        guard let rawPosition = copyAttribute(window, kAXPositionAttribute as CFString),
              let rawSize = copyAttribute(window, kAXSizeAttribute as CFString),
              let position = cgPoint(from: rawPosition),
              let size = cgSize(from: rawSize) else { return nil }
        return axRectToAppKit(CGRect(origin: position, size: size))
    }

    private func cgPoint(from value: CFTypeRef) -> CGPoint? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgPoint else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(axValue, .cgPoint, &point) ? point : nil
    }

    private func cgSize(from value: CFTypeRef) -> CGSize? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgSize else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(axValue, .cgSize, &size) ? size : nil
    }

    private func appKitPointToAX(_ point: CGPoint) -> CGPoint {
        let mainTop = NSScreen.screens.first?.frame.maxY ?? 0
        return CGPoint(x: point.x, y: mainTop - point.y)
    }

    private func axRectToAppKit(_ rect: CGRect) -> CGRect {
        let mainTop = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: rect.minX, y: mainTop - rect.maxY, width: rect.width, height: rect.height)
    }
}

private struct PasteboardSnapshot {
    struct Item {
        let values: [(NSPasteboard.PasteboardType, Data)]
    }

    let items: [Item]

    init(pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            Item(values: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restored = items.map { snapshot -> NSPasteboardItem in
            let item = NSPasteboardItem()
            snapshot.values.forEach { item.setData($0.1, forType: $0.0) }
            return item
        }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
    }
}
