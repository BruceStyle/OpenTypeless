import Foundation

public enum WritingMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case faithful, transcript, structured
    public var id: String { rawValue }
    public var title: String {
        switch self { case .faithful: return "忠实整理"; case .transcript: return "仅转写"; case .structured: return "结构化指令" }
    }
    public var detail: String {
        switch self {
        case .faithful: return "去掉口头语与重复，保留每一个要求。"
        case .transcript: return "保留识别原稿，不调用文字整理模型。"
        case .structured: return "将已有要求组织为段落或列表，不添加新需求。"
        }
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var transcriptionModel = "openai/gpt-4o-mini-transcribe"
    /// Empty means no additional model is called for a slow response.
    public var transcriptionFallbackModel = ""
    public var rewriteModel = "google/gemini-3.1-flash-lite"
    public var mode: WritingMode = .faithful
    public var shortcut = "fn"
    public var autoPaste = true
    public var saveHistory = true
    public var historyDays = 30
    /// Legacy vocabulary, retained for decoding and migrated to the unified
    /// dictionary on launch. New installations learn words from user edits.
    public var dictionary = ""
    public var learnFromCorrections = false
    /// Request-only context, populated from the learned dictionary. Deliberately
    /// omitted from CodingKeys so settings and recovery drafts do not retain it.
    public var spellingCorrections: [SpellingCorrection] = []
    public var diagnosticAudioUntil: Date?
    public var microphoneUID: String?
    public var overlayAppearance: OverlayAppearance = .system
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case transcriptionModel, rewriteModel, mode, shortcut, autoPaste, saveHistory, historyDays, dictionary
        case diagnosticAudioUntil, microphoneUID, overlayAppearance, transcriptionFallbackModel
        case learnFromCorrections
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        transcriptionModel = try values.decode(String.self, forKey: .transcriptionModel)
        transcriptionFallbackModel = try values.decodeIfPresent(String.self, forKey: .transcriptionFallbackModel) ?? ""
        rewriteModel = try values.decode(String.self, forKey: .rewriteModel)
        mode = try values.decode(WritingMode.self, forKey: .mode)
        shortcut = try values.decode(String.self, forKey: .shortcut)
        autoPaste = try values.decode(Bool.self, forKey: .autoPaste)
        saveHistory = try values.decode(Bool.self, forKey: .saveHistory)
        historyDays = try values.decode(Int.self, forKey: .historyDays)
        dictionary = try values.decode(String.self, forKey: .dictionary)
        learnFromCorrections = try values.decodeIfPresent(Bool.self, forKey: .learnFromCorrections) ?? false
        diagnosticAudioUntil = try values.decodeIfPresent(Date.self, forKey: .diagnosticAudioUntil)
        microphoneUID = try values.decodeIfPresent(String.self, forKey: .microphoneUID)
        // Settings and recovery drafts written before this preference existed
        // must retain their models, microphone, shortcuts and privacy choices.
        overlayAppearance = (try? values.decode(OverlayAppearance.self, forKey: .overlayAppearance)) ?? .system
    }
    public var keepsDiagnosticAudio: Bool { saveHistory && (diagnosticAudioUntil ?? .distantPast) > Date() }
    public var effectiveTranscriptionFallbackModel: String? {
        let fallback = transcriptionFallbackModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let primary = transcriptionModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty || fallback == primary ? nil : fallback
    }
    public var vocabulary: [String] {
        var seen = Set<String>()
        return dictionary.split(whereSeparator: \.isNewline).map {
            String($0.trimmingCharacters(in: .whitespaces).prefix(100))
        }.filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(100).map { $0 }
    }
}

public struct ModelDescriptor: Decodable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let supportedParameters: [String]?
    enum CodingKeys: String, CodingKey { case id, name; case supportedParameters = "supported_parameters" }
    public init(id: String, name: String, supportedParameters: [String]? = nil) {
        self.id = id; self.name = name; self.supportedParameters = supportedParameters
    }
}

public struct InferenceResult: Codable, Sendable {
    public let text: String
    public let cost: Double?
    public init(text: String, cost: Double?) { self.text = text; self.cost = cost }
}

public struct ProcessingTimings: Codable, Sendable {
    public let recognition: Double
    public let rewriting: Double
    public let insertion: Double
    public let total: Double
    /// Seconds from stopping to the final text being available / Cmd-V posted.
    /// Posting a paste does not prove the target has rendered it.
    public let textReady: Double?
    public let pastePosted: Double?
    public init(recognition: Double, rewriting: Double, insertion: Double, total: Double,
                textReady: Double? = nil, pastePosted: Double? = nil) {
        self.recognition = recognition; self.rewriting = rewriting; self.insertion = insertion; self.total = total
        self.textReady = textReady; self.pastePosted = pastePosted
    }
}

public struct HistoryEntry: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var date = Date()
    public var rawText: String
    public var text: String
    public var mode: WritingMode
    public var seconds: Double
    public var cost: Double?
    public var transcriptionModel: String
    public var rewriteModel: String?
    public var delivery: String
    public var timings: ProcessingTimings?
    public var recognition: RecognitionStatistics?
    public init(rawText: String, text: String, mode: WritingMode, seconds: Double, cost: Double?, transcriptionModel: String, rewriteModel: String?, delivery: String) {
        self.rawText = rawText; self.text = text; self.mode = mode; self.seconds = seconds
        self.cost = cost; self.transcriptionModel = transcriptionModel; self.rewriteModel = rewriteModel; self.delivery = delivery
    }
}

public struct RecognitionStatistics: Codable, Sendable {
    public var requests: Int
    public var recoveryRequests: Int
    public var failedRequests: Int
    public var cancelledRequests: Int
    public var unknownCostRequests: Int
    public var knownCost: Double
    public var acceptedSource: String?
    public var slowBackupRequests: Int?
    public var modelFallbackRequests: Int?
    public var acceptedModels: [String]?
    public init(requests: Int, recoveryRequests: Int, failedRequests: Int, cancelledRequests: Int,
                unknownCostRequests: Int, knownCost: Double, acceptedSource: String?, slowBackupRequests: Int = 0,
                modelFallbackRequests: Int = 0, acceptedModels: [String]? = nil) {
        self.requests = requests; self.recoveryRequests = recoveryRequests; self.failedRequests = failedRequests
        self.cancelledRequests = cancelledRequests; self.unknownCostRequests = unknownCostRequests
        self.knownCost = knownCost; self.acceptedSource = acceptedSource
        self.slowBackupRequests = slowBackupRequests
        self.modelFallbackRequests = modelFallbackRequests; self.acceptedModels = acceptedModels
    }
}

public enum AppError: LocalizedError {
    case message(String)
    public var errorDescription: String? { switch self { case .message(let text): return text } }
}

public enum CostTotal {
    // Missing usage is unknown, never free. Preserve that distinction in history.
    public static func sum(_ costs: [Double?]) -> Double? {
        guard !costs.isEmpty, costs.allSatisfy({ $0 != nil }) else { return nil }
        return costs.compactMap { $0 }.reduce(0, +)
    }
}
