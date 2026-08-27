import Foundation

enum TranslationError: LocalizedError {
    case invalidBaseURL
    case invalidResponse
    case http(Int, String)
    case provider(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL: return "接口地址无效"
        case .invalidResponse: return "接口返回了无法识别的响应"
        case .http(let status, let detail): return "接口请求失败（HTTP \(status)）：\(detail)"
        case .provider(let message): return "模型接口报错：\(message)"
        case .emptyResponse: return "模型没有返回翻译内容"
        }
    }
}

final class TranslationClient {
    typealias DeltaHandler = @MainActor (String) -> Void

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 300
            configuration.timeoutIntervalForResource = 600
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration)
        }
    }

    func translate(
        text: String,
        apiKey: String,
        settings: AppSettingsSnapshot,
        onDelta: @escaping DeltaHandler
    ) async throws -> String {
        let endpoint = try Self.endpoint(from: settings.baseURL)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.requestBody(text: text, settings: settings))

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw TranslationError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            var detail = ""
            for try await line in bytes.lines {
                detail += line
                if detail.count >= 2_000 { break }
            }
            throw TranslationError.http(http.statusCode, String(detail.prefix(2_000)))
        }

        var output = ""
        var receivedSSE = false
        var plainLines: [String] = []
        for try await line in bytes.lines {
            guard !line.isEmpty else { continue }
            if line.hasPrefix("data:") {
                receivedSSE = true
                let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if data == "[DONE]" { continue }
                let delta = try Self.contentDelta(from: data)
                if !delta.isEmpty {
                    output += delta
                    await onDelta(output)
                }
            } else if !receivedSSE {
                plainLines.append(line)
            }
        }

        if !receivedSSE, !plainLines.isEmpty {
            output = try Self.contentFromJSON(plainLines.joined(separator: "\n"))
            await onDelta(output)
        }
        let result = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw TranslationError.emptyResponse }
        return result
    }

    static func endpoint(from baseURL: String) throws -> URL {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        let value = trimmed.hasSuffix("/chat/completions") ? trimmed : trimmed + "/chat/completions"
        guard let url = URL(string: value), let scheme = url.scheme, ["http", "https"].contains(scheme) else {
            throw TranslationError.invalidBaseURL
        }
        return url
    }

    static func requestBody(text: String, settings: AppSettingsSnapshot) -> [String: Any] {
        let target = settings.targetLanguage.instruction(for: text)
        let system = settings.translationPrompt
            .replacingOccurrences(of: "{target_language}", with: target)
        var body: [String: Any] = [
            "model": settings.model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": text],
            ],
            "stream": true,
            "stream_options": ["include_usage": true],
            "temperature": 0,
            "max_tokens": 2_048,
        ]
        if settings.model.lowercased().hasPrefix("glm-") {
            body["thinking_budget"] = 1_024
            body["chat_template_kwargs"] = ["enable_thinking": false]
        }
        return body
    }

    static func contentDelta(from sseData: String) throws -> String {
        guard let data = sseData.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranslationError.invalidResponse
        }
        if let error = object["error"] as? [String: Any] {
            throw TranslationError.provider(error["message"] as? String ?? String(describing: error))
        }
        guard let choices = object["choices"] as? [[String: Any]] else { return "" }
        return choices.compactMap { choice in
            (choice["delta"] as? [String: Any])?["content"] as? String
        }.joined()
    }

    static func contentFromJSON(_ source: String) throws -> String {
        guard let data = source.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranslationError.invalidResponse
        }
        if let error = object["error"] as? [String: Any] {
            throw TranslationError.provider(error["message"] as? String ?? String(describing: error))
        }
        guard let choices = object["choices"] as? [[String: Any]] else { throw TranslationError.invalidResponse }
        return choices.compactMap { choice in
            (choice["message"] as? [String: Any])?["content"] as? String
        }.joined()
    }
}
