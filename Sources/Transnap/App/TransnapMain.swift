import AppKit
import ApplicationServices
import Darwin
import SwiftUI

@main
@MainActor
struct TransnapMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        if CommandLine.arguments.contains("--self-test") {
            do {
                try SelfTests.run()
                print("Self-tests passed")
                exit(0)
            } catch {
                fputs("Self-test failed: \(error)\n", stderr)
                exit(1)
            }
        }

        if CommandLine.arguments.contains("--accessibility-status") {
            print(AXIsProcessTrusted() ? "trusted" : "not-trusted")
            exit(AXIsProcessTrusted() ? 0 : 3)
        }

        if CommandLine.arguments.contains("--api-smoke-test") {
            DispatchQueue.main.async {
                Self.runAPISmokeTest()
            }
        }
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }

    private static func runAPISmokeTest() {
        let environment = ProcessInfo.processInfo.environment
        guard let key = environment["TRANSNAP_API_KEY"]
            ?? environment["OPENAI_API_KEY"] else {
            fputs("API smoke test skipped: set TRANSNAP_API_KEY or OPENAI_API_KEY\n", stderr)
            exit(2)
        }
        Task {
            do {
                let result = try await TranslationClient().translate(
                    text: "A precise tool should feel simple.",
                    apiKey: key,
                    settings: AppSettingsSnapshot(
                        baseURL: AppSettings.defaultBaseURL,
                        model: AppSettings.defaultModel,
                        targetLanguage: .simplifiedChinese,
                        translationPrompt: AppSettings.defaultTranslationPrompt
                    ),
                    onDelta: { _ in }
                )
                print(result)
                exit(0)
            } catch {
                fputs("API smoke test failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
    }
}
