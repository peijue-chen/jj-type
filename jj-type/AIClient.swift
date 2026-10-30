//
//  AIClient.swift
//  jj-type
//
//  OpenAI-compatible chat-completions client (non-streaming, 30 s timeout).
//

import Foundation

enum AIError: LocalizedError {
    case invalidURL(String)
    case http(status: Int, message: String)
    case noValidResult(truncated: Bool)
    case malformedResponse
    case network(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let baseURL):
            return "无效的服务地址：\(baseURL)，请检查 Base URL 配置"
        case .http(let status, let message):
            return "请求失败（HTTP \(status)）：\(message)"
        case .noValidResult(let truncated):
            return truncated
                ? "AI 返回异常（推理内容被截断，重试仍无有效结果），请重试或更换模型"
                : "AI 返回异常（未包含有效结果，可能被截断），请重试"
        case .malformedResponse:
            return "AI 返回格式异常，请重试或更换模型"
        case .network(let message):
            return "网络错误：\(message)"
        }
    }
}

final class AIClient {
    struct Message: Codable {
        let role: String
        // Reasoning-style models (GLM/DeepSeek via OpenAI-compatible servers) can
        // return an empty content with the payload in reasoning_content.
        let content: String?
        let reasoning_content: String?

        init(role: String, content: String) {
            self.role = role
            self.content = content
            self.reasoning_content = nil
        }
    }

    struct ResponseFormat: Codable {
        let type: String
        static let jsonObject = ResponseFormat(type: "json_object")
    }

    struct RequestBody: Codable {
        let model: String
        let messages: [Message]
        let temperature: Double
        let response_format: ResponseFormat?
        let max_tokens: Int?
    }

    struct APIErrorBody: Codable {
        let message: String?
    }

    struct Choice: Codable {
        let message: Message
        let finish_reason: String?
    }

    struct ResponseBody: Codable {
        let choices: [Choice]?
        let error: APIErrorBody?
    }

    /// Usable output of one completion attempt (empty text = nothing recoverable).
    private struct Completion {
        var text: String = ""
        var finishReason: String?
    }

    /// Single shared session for every AIClient instance (AGENTS.md convention).
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    /// POST {baseURL}/chat/completions and return parse-ready output:
    /// content when present; otherwise the LAST valid JSON rehearsed inside
    /// reasoning_content (thinking text is NEVER returned raw). When nothing
    /// valid is recovered and the model was cut by max_tokens, one automatic
    /// retry runs at a doubled budget before a clean error is thrown.
    func complete(provider: ProviderConfig, apiKey: String,
                  systemPrompt: String, userPrompt: String) async throws -> String {
        let messages = [Message(role: "system", content: systemPrompt),
                        Message(role: "user", content: userPrompt)]
        var completion = try await attempt(provider: provider, apiKey: apiKey,
                                           messages: messages, maxTokens: 4096)
        if completion.text.isEmpty, completion.finishReason == "length" {
            // Truncated mid-reasoning — retry once with a doubled budget.
            completion = try await attempt(provider: provider, apiKey: apiKey,
                                           messages: messages, maxTokens: 8192)
            guard !completion.text.isEmpty else {
                throw AIError.noValidResult(truncated: true)
            }
        }
        guard !completion.text.isEmpty else {
            throw AIError.noValidResult(truncated: false)
        }
        return completion.text
    }

    /// Minimal connectivity probe ("Reply with exactly: OK"). Short 10 s timeout.
    /// Returns elapsed milliseconds; throws AIError on failure.
    @discardableResult
    func testConnection(provider: ProviderConfig, apiKey: String) async throws -> Int {
        let started = Date()
        let completion = try await attempt(provider: provider, apiKey: apiKey,
                                           messages: [Message(role: "user",
                                                              content: "Reply with exactly: OK")],
                                           maxTokens: 256, timeout: 10)
        guard !completion.text.isEmpty else {
            throw AIError.noValidResult(truncated: completion.finishReason == "length")
        }
        return Int(Date().timeIntervalSince(started) * 1000)
    }

    // MARK: - Private

    /// One request (with response_format 400-fallback) reduced to a Completion.
    private func attempt(provider: ProviderConfig, apiKey: String,
                         messages: [Message], maxTokens: Int,
                         timeout: TimeInterval? = nil) async throws -> Completion {
        do {
            return try await send(provider: provider, apiKey: apiKey, messages: messages,
                                  responseFormat: .jsonObject, maxTokens: maxTokens, timeout: timeout)
        } catch let AIError.http(status, _) where status == 400 {
            // Compatibility fallback: some strict endpoints reject response_format.
            return try await send(provider: provider, apiKey: apiKey, messages: messages,
                                  responseFormat: nil, maxTokens: maxTokens, timeout: timeout)
        }
    }

    private func send(provider: ProviderConfig, apiKey: String,
                      messages: [Message], responseFormat: ResponseFormat?,
                      maxTokens: Int?, timeout: TimeInterval?) async throws -> Completion {
        let request = try makeRequest(provider: provider, apiKey: apiKey,
                                      messages: messages, responseFormat: responseFormat,
                                      maxTokens: maxTokens, timeout: timeout)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch let error as URLError {
            throw AIError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw AIError.malformedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AIError.http(status: http.statusCode, message: Self.serverMessage(from: data))
        }
        let body: ResponseBody
        do {
            body = try JSONDecoder().decode(ResponseBody.self, from: data)
        } catch {
            // HTTP 200 but the body is not a valid chat-completions payload.
            throw AIError.malformedResponse
        }
        let choice = body.choices?.first
        // 1) Final answer in content (think-tag blocks stripped).
        let content = PromptBuilder.stripThinkingTags(choice?.message.content ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !content.isEmpty {
            return Completion(text: content, finishReason: choice?.finish_reason)
        }
        // 2) Reasoning models: NEVER return the thinking raw — only the last
        //    valid JSON object rehearsed inside it (the final one wins).
        let reasoning = choice?.message.reasoning_content ?? ""
        if let json = PromptBuilder.extractLastValidJSON(in: reasoning) {
            return Completion(text: json, finishReason: choice?.finish_reason)
        }
        return Completion(text: "", finishReason: choice?.finish_reason)
    }

    private func makeRequest(provider: ProviderConfig, apiKey: String,
                             messages: [Message], responseFormat: ResponseFormat?,
                             maxTokens: Int? = nil, timeout: TimeInterval? = nil) throws -> URLRequest {
        let trimmed = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        guard let url = URL(string: base + "/chat/completions") else {
            throw AIError.invalidURL(provider.baseURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if let timeout { request.timeoutInterval = timeout }
        let body = RequestBody(model: provider.model, messages: messages,
                               temperature: 0.2, response_format: responseFormat,
                               max_tokens: maxTokens)
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    /// Extracts {"error":{"message":...}} bodies produced by OpenAI-compatible servers.
    private static func serverMessage(from data: Data) -> String {
        if let body = try? JSONDecoder().decode(ResponseBody.self, from: data),
           let message = body.error?.message, !message.isEmpty {
            return message
        }
        return String(data: data.prefix(200), encoding: .utf8) ?? "未知错误"
    }
}
