import Foundation
import os

public protocol SpeechClient: Sendable {
    func transcribe(audio: Data, model: String, key: String) async throws -> InferenceResult
    func rewrite(text: String, settings: AppSettings, key: String) async throws -> InferenceResult
}

public actor OpenRouterClient: SpeechClient {
    private let logger = Logger(subsystem: "com.opentypeless.mac", category: "Dictionary")
    private let session: URLSession
    private let baseURL: URL
    public init(session: URLSession? = nil, baseURL: URL = URL(string: "https://openrouter.ai/api/v1/")!) {
        if let session { self.session = session } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 65
            configuration.timeoutIntervalForResource = 120
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration)
        }
        self.baseURL = baseURL
    }

    public func models(transcription: Bool) async throws -> [ModelDescriptor] {
        var components = URLComponents(url: baseURL.appendingPathComponent("models"), resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "output_modalities", value: transcription ? "transcription" : "text")]
        let (data, response) = try await session.data(from: components.url!)
        try check(response, data: data)
        struct Catalog: Decodable { let data: [ModelDescriptor] }
        return try JSONDecoder().decode(Catalog.self, from: data).data.sorted { $0.name < $1.name }
    }

    public func verifyKey(_ key: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("key"))
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try check(response, data: data)
    }

    public func transcribe(audio: Data, model: String, key: String) async throws -> InferenceResult {
        let data: Data
        // The multipart endpoint accepts the same WAV bytes without Base64's
        // size overhead. Keep oversized requests on the existing JSON path.
        if audio.count <= 24_000_000 {
            let boundary = "OpenTypeless-\(UUID().uuidString)"
            var body = Data()
            for (name, value) in [("model", model), ("language", "zh"), ("temperature", "0"), ("response_format", "json")] {
                body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
            }
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"recording.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
            body.append(audio)
            body.append(Data("\r\n--\(boundary)--\r\n".utf8))
            data = try await post("audio/transcriptions", data: body,
                                  contentType: "multipart/form-data; boundary=\(boundary)", key: key)
        } else {
            data = try await post("audio/transcriptions", body: [
                "model": model, "input_audio": ["data": audio.base64EncodedString(), "format": "wav"],
                "language": "zh", "temperature": 0, "response_format": "json"
            ], key: key)
        }
        struct Response: Decodable { let text: String; let usage: Usage? }
        let response = try JSONDecoder().decode(Response.self, from: data)
        let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SpeechFailure(.noText, cost: response.usage?.cost) }
        return InferenceResult(text: text, cost: response.usage?.cost)
    }

    public func rewrite(text: String, settings: AppSettings, key: String) async throws -> InferenceResult {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppError.message("原稿为空，无法整理。") }
        if settings.mode == .transcript { return InferenceResult(text: text, cost: 0) }
        guard text.count <= 40_000 else { throw AppError.message("原稿过长，已保留原稿。请分段整理。") }
        var body: [String: Any] = [
            "model": settings.rewriteModel,
            "messages": [
                ["role": "system", "content": RewritePrompt.system(mode: settings.mode)],
                ["role": "user", "content": try RewritePrompt.user(transcript: text, vocabulary: settings.vocabulary, corrections: settings.spellingCorrections)]
            ],
            "max_tokens": min(16_000, max(2_048, text.count * 3 + 512)),
            "stream": false
        ]
        if settings.rewriteModel.hasPrefix("google/gemini-3") {
            body["reasoning"] = ["effort": "minimal", "exclude": true] as [String: Any]
        }
        let data = try await post("chat/completions", body: body, key: key)
        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String?; let refusal: String? }
                let message: Message
                let finish_reason: String?
            }
            let choices: [Choice]
            let usage: Usage?
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard let choice = response.choices.first else { throw AppError.message("整理模型没有返回结果，原稿已保留。") }
        guard choice.finish_reason == "stop", choice.message.refusal == nil else {
            throw AppError.message("整理结果被截断或未正常完成，未自动插入。请使用原稿或重试。")
        }
        let output = (choice.message.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { throw AppError.message("整理结果为空，原稿已保留。") }
        let corrected = ClearWordCorrection.apply(to: output, original: text, corrections: settings.spellingCorrections)
        if corrected != output { logger.info("Applied local spelling correction; scope=wordTest") }
        return InferenceResult(text: corrected, cost: response.usage?.cost)
    }

    private struct Usage: Decodable { let cost: Double? }

    private func post(_ path: String, body: [String: Any], key: String) async throws -> Data {
        try await post(path, data: JSONSerialization.data(withJSONObject: body), contentType: "application/json", key: key)
    }

    private func post(_ path: String, data: Data, contentType: String, key: String) async throws -> Data {
        guard !key.isEmpty else { throw SpeechFailure(.account) }
        try Task.checkCancellation()
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("OpenTypeless", forHTTPHeaderField: "X-Title")
        request.httpBody = data
        let metrics = SpeechRequestMetrics(kind: path == "audio/transcriptions" ? "recognition" : "rewrite", uploadBytes: data.count)
        let (data, response) = try await session.data(for: request, delegate: metrics)
        try Task.checkCancellation()
        try check(response, data: data)
        return data
    }

    private func check(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw SpeechFailure(.invalidResponse) }
        guard (200..<300).contains(http.statusCode) else {
            let kind: SpeechFailure.Kind
            switch http.statusCode {
            case 401, 402, 403: kind = .account
            case 400, 404, 413, 422: kind = .request
            default: kind = .temporary
            }
            // Do not echo upstream bodies: they can contain user audio/text or credentials.
            throw SpeechFailure(kind, status: http.statusCode)
        }
    }
}
