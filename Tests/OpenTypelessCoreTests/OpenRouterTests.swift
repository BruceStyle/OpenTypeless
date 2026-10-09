import Foundation
import XCTest
@testable import OpenTypelessCore

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class OpenRouterTests: XCTestCase {
    private func client() -> OpenRouterClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return OpenRouterClient(session: URLSession(configuration: config))
    }
    override func tearDown() { StubURLProtocol.handler = nil }
    private func bytes(_ request: URLRequest) -> Data {
        let data: Data
        if let bytes = request.httpBody { data = bytes }
        else if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = Data(); var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; bytes.append(contentsOf: buffer.prefix(count)) }
            data = bytes
        } else { data = Data() }
        return data
    }
    private func body(_ request: URLRequest) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: bytes(request)) as! [String: Any]
    }
    func testAudioRequestUsesDedicatedEndpointAndReturnsActualCost() async throws {
        let audio = WaveEncoder.encode([0, -1, 0.5, 1, 0.02])
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/audio/transcriptions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-only-key")
            let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
            XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
            let boundary = try XCTUnwrap(contentType.components(separatedBy: "boundary=").last)
            let data = self.bytes(request)
            for (name, value) in [("model", "openai/gpt-4o-mini-transcribe"), ("language", "zh"), ("temperature", "0"), ("response_format", "json")] {
                XCTAssertNotNil(data.range(of: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8)))
            }
            let header = Data("Content-Disposition: form-data; name=\"file\"; filename=\"recording.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8)
            let start = try XCTUnwrap(data.range(of: header)).upperBound
            let footer = Data("\r\n--\(boundary)--\r\n".utf8)
            XCTAssertEqual(data.suffix(footer.count), footer)
            XCTAssertEqual(data[start..<(data.count - footer.count)], audio, "Binary WAV, including NUL/CRLF bytes, must be preserved exactly")
            return (200, Data(#"{"text":"不要改公共组件。","usage":{"cost":0.000123}}"#.utf8))
        }
        let result = try await client().transcribe(audio: audio, model: "openai/gpt-4o-mini-transcribe", key: "test-only-key")
        XCTAssertEqual(result.text, "不要改公共组件。")
        XCTAssertEqual(result.cost, 0.000123)
    }
    func testMultipartReducesNormalAudioPayloadWithoutLossyEncoding() async throws {
        let audio = WaveEncoder.encode(Array(repeating: Float(0.03125), count: 16_000 * 10))
        let baseline = try JSONSerialization.data(withJSONObject: [
            "model": "openai/gpt-4o-mini-transcribe", "input_audio": ["data": audio.base64EncodedString(), "format": "wav"],
            "language": "zh", "temperature": 0, "response_format": "json"
        ])
        StubURLProtocol.handler = { request in
            let uploaded = self.bytes(request)
            XCTAssertNotNil(uploaded.range(of: audio))
            XCTAssertLessThan(Double(uploaded.count) / Double(baseline.count), 0.76)
            print("LATENCY_PAYLOAD wav=\(audio.count) oldJSON=\(baseline.count) multipart=\(uploaded.count)")
            return (200, Data(#"{"text":"同一份音频"}"#.utf8))
        }
        _ = try await client().transcribe(audio: audio, model: "openai/gpt-4o-mini-transcribe", key: "test-only-key")
    }
    func testOversizedAudioKeepsJSONTransportInsteadOfHittingMultipartLimit() async throws {
        let audio = Data(repeating: 0x85, count: 24_000_001)
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let input = try XCTUnwrap(self.body(request)["input_audio"] as? [String: String])
            XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(input["data"])), audio)
            return (200, Data(#"{"text":"保留原有大文件行为"}"#.utf8))
        }
        _ = try await client().transcribe(audio: audio, model: "fake", key: "test-only-key")
    }
    func testRewriteSeparatesInstructionsFromTranscript() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/chat/completions")
            let body = try self.body(request)
            let messages = body["messages"] as! [[String: String]]
            XCTAssertEqual(messages.map { $0["role"]! }, ["system", "user"])
            XCTAssertTrue(messages[1]["content"]!.contains("先不接后端"))
            XCTAssertNil(body["tools"])
            return (200, Data(#"{"choices":[{"message":{"content":"先不接后端。"},"finish_reason":"stop"}],"usage":{"cost":0.002}}"#.utf8))
        }
        let result = try await client().rewrite(text: "先不接后端", settings: AppSettings(), key: "test-only-key")
        XCTAssertEqual(result.text, "先不接后端。")
    }
    func testTruncatedResultCannotReachInsertion() async {
        StubURLProtocol.handler = { _ in (200, Data(#"{"choices":[{"message":{"content":"不要"},"finish_reason":"length"}]}"#.utf8)) }
        do { _ = try await client().rewrite(text: "不要删除文件", settings: AppSettings(), key: "test-only-key"); XCTFail("Should reject truncation") }
        catch { XCTAssertTrue(error.localizedDescription.contains("截断")) }
    }
    func testLearnedWordsUseOneExistingRewriteRequestAndOnlyConfirmedSpellings() async throws {
        let words = [LearnedWord(term: "CodePilot", variants: ["扣得派洛特"], status: .active),
                     LearnedWord(term: "PendingWord", variants: [], status: .pending),
                     LearnedWord(term: "ExcludedWord", variants: [], status: .excluded)]
        var settings = AppSettings(); settings.dictionary = "SwiftUI"
        settings = DictionaryVocabulary.settings(settings, words: words, transcript: "使用扣得派洛特")
        var requests = 0
        StubURLProtocol.handler = { request in
            requests += 1
            XCTAssertEqual(request.url?.path, "/api/v1/chat/completions")
            let messages = try XCTUnwrap(self.body(request)["messages"] as? [[String: String]])
            let payload = try XCTUnwrap(messages.last?["content"]?.data(using: .utf8))
            let input = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
            XCTAssertEqual(input["dictionary"] as? [String], ["CodePilot", "SwiftUI"])
            XCTAssertEqual(input["transcript"] as? String, "使用扣得派洛特")
            XCTAssertEqual(input["corrections"] as? [[String: String]], [["heard": "扣得派洛特", "preferred": "CodePilot"]])
            XCTAssertNil(input["baseline"])
            return (200, Data(#"{"choices":[{"message":{"content":"使用 CodePilot。"},"finish_reason":"stop"}]}"#.utf8))
        }
        _ = try await client().rewrite(text: "使用扣得派洛特", settings: settings, key: "test-only-key")
        XCTAssertEqual(requests, 1)
    }
    func testUpstreamErrorDoesNotEchoSensitiveBody() async {
        StubURLProtocol.handler = { _ in (401, Data(#"{"error":{"message":"private transcript sk-secret"}}"#.utf8)) }
        do { _ = try await client().transcribe(audio: Data(), model: "fake", key: "test-only-key"); XCTFail("Should reject auth") }
        catch { XCTAssertTrue(error.localizedDescription.contains("API Key")); XCTAssertFalse(error.localizedDescription.contains("sk-secret")) }
    }
    func testWordTestCorrectionReachesCallerWhenProviderLeavesAliasUnchanged() async throws {
        var settings = AppSettings()
        settings.spellingCorrections = [.init(heard: "tablets", preferred: "Typeless")]
        var requests = 0
        StubURLProtocol.handler = { _ in
            requests += 1
            return (200, Data(#"{"choices":[{"message":{"content":"OK，那这次让我们再测试一下 Tablets。"},"finish_reason":"stop"}],"usage":{"cost":0.002}}"#.utf8))
        }
        let result = try await client().rewrite(text: "OK，那这次让我们再测试一下Tablets。", settings: settings, key: "test-only-key")
        XCTAssertEqual(result.text, "OK，那这次让我们再测试一下 Typeless。")
        XCTAssertEqual(result.cost, 0.002)
        XCTAssertEqual(requests, 1, "The deterministic backstop must not add a second model request")
    }
    func testVerbatimModeDoesNotCallRewriteAPI() async throws {
        StubURLProtocol.handler = { _ in XCTFail("No network request expected"); return (500, Data()) }
        var settings = AppSettings(); settings.mode = .transcript
        settings.spellingCorrections = [.init(heard: "tablets", preferred: "Typeless")]
        let result = try await client().rewrite(text: "先别改 tablets。", settings: settings, key: "")
        XCTAssertEqual(result.text, "先别改 tablets。")
        XCTAssertEqual(result.cost, 0)
    }
    func testEmptyTranscriptIsNotInvented() async {
        StubURLProtocol.handler = { _ in (200, Data(#"{"text":"  "}"#.utf8)) }
        do { _ = try await client().transcribe(audio: Data(), model: "fake", key: "test-only-key"); XCTFail("Should reject empty speech") }
        catch { XCTAssertTrue(error.localizedDescription.contains("没有识别")) }
    }
    func testEmptyResponsePreservesReportedCostAndDistinctFailureKind() async {
        StubURLProtocol.handler = { _ in (200, Data(#"{"text":"  ","usage":{"cost":0.003}}"#.utf8)) }
        do { _ = try await client().transcribe(audio: Data(), model: "fake", key: "test-only-key"); XCTFail("Empty result") }
        catch {
            XCTAssertEqual((error as? SpeechFailure)?.kind, .noText)
            XCTAssertEqual((error as? SpeechFailure)?.cost, 0.003)
        }
    }
    func testHTTPFailuresHaveRecoveryPolicyWithoutPersistingPrivateBodies() async {
        for (status, kind, permits) in [(400, SpeechFailure.Kind.request, false), (402, .account, false), (429, .temporary, true), (503, .temporary, true)] {
            StubURLProtocol.handler = { _ in (status, Data("private speech and secret key".utf8)) }
            do { _ = try await client().transcribe(audio: Data(), model: "fake", key: "test-only-key"); XCTFail("HTTP error") }
            catch {
                XCTAssertEqual((error as? SpeechFailure)?.kind, kind)
                XCTAssertEqual((error as? SpeechFailure)?.status, status)
                XCTAssertEqual((error as? SpeechFailure)?.permitsRecovery, permits)
                XCTAssertFalse(error.localizedDescription.contains("private"))
            }
        }
    }
    func testMissingCostStaysUnknown() async throws {
        StubURLProtocol.handler = { _ in (200, Data(#"{"text":"测试文字"}"#.utf8)) }
        let result = try await client().transcribe(audio: Data(), model: "fake", key: "test-only-key")
        XCTAssertNil(result.cost)
    }
}
