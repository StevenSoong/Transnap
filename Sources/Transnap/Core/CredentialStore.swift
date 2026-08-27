import Foundation

final class CredentialStore {
    private static let legacyDefaultsKey = "apiKey"

    private let fileURL: URL
    private let defaults: UserDefaults
    private let fileManager: FileManager

    init(
        fileURL: URL = CredentialStore.defaultFileURL(),
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.defaults = defaults
        self.fileManager = fileManager
    }

    func loadAPIKey() -> String? {
        if let data = try? Data(contentsOf: fileURL),
           let value = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }

        // Migrate versions that stored the key in UserDefaults. Remove the
        // legacy value only after the private file has been written safely.
        guard let legacy = defaults.string(forKey: Self.legacyDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !legacy.isEmpty else { return nil }
        if writeAPIKey(legacy) {
            defaults.removeObject(forKey: Self.legacyDefaultsKey)
        }
        return legacy
    }

    func saveAPIKey(_ value: String) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty {
            try? fileManager.removeItem(at: fileURL)
            defaults.removeObject(forKey: Self.legacyDefaultsKey)
        } else {
            _ = writeAPIKey(normalized)
        }
    }

    func importEnvironmentKeyIfNeeded() {
        guard loadAPIKey() == nil else { return }
        let environment = ProcessInfo.processInfo.environment
        let value = environment["TRANSNAP_API_KEY"]
            ?? environment["OPENAI_API_KEY"]
        guard let value, !value.isEmpty else { return }
        saveAPIKey(value)
    }

    static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent("Transnap", isDirectory: true)
            .appendingPathComponent("api-key", isDirectory: false)
    }

    private func writeAPIKey(_ value: String) -> Bool {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o700))],
                ofItemAtPath: directory.path
            )
            try Data(value.utf8).write(to: fileURL, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: fileURL.path
            )
            var localURL = fileURL
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            try? localURL.setResourceValues(resourceValues)
            return true
        } catch {
            NSLog("Transnap 无法保存接口密钥：%@", error.localizedDescription)
            return false
        }
    }
}
