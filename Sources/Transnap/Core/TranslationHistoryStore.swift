import Foundation

struct TranslationHistoryEntry: Codable, Equatable, Identifiable {
    let id: UUID
    let source: String
    let translation: String
    let model: String
    let createdAt: Date
}

final class TranslationHistoryStore {
    private(set) var entries: [TranslationHistoryEntry]

    private let fileURL: URL
    private let maximumEntryCount: Int
    private let fileManager: FileManager

    init(
        fileURL: URL = TranslationHistoryStore.defaultFileURL(),
        maximumEntryCount: Int = 200,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.maximumEntryCount = max(1, maximumEntryCount)
        self.fileManager = fileManager
        entries = []
        entries = loadEntries()
    }

    @discardableResult
    func add(source: String, translation: String, model: String, createdAt: Date = Date()) -> TranslationHistoryEntry? {
        let cleanSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTranslation = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSource.isEmpty, !cleanTranslation.isEmpty else { return nil }

        entries.removeAll { entry in
            entry.source == cleanSource && entry.translation == cleanTranslation
        }

        let entry = TranslationHistoryEntry(
            id: UUID(),
            source: cleanSource,
            translation: cleanTranslation,
            model: model,
            createdAt: createdAt
        )
        entries.insert(entry, at: 0)
        if entries.count > maximumEntryCount {
            entries.removeLast(entries.count - maximumEntryCount)
        }
        persist()
        return entry
    }

    static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent("Transnap", isDirectory: true)
            .appendingPathComponent("translation-history.json", isDirectory: false)
    }

    private func loadEntries() -> [TranslationHistoryEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([TranslationHistoryEntry].self, from: data) else { return [] }
        return Array(decoded.prefix(maximumEntryCount))
    }

    private func persist() {
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Transnap 无法保存翻译历史：%@", error.localizedDescription)
        }
    }
}
