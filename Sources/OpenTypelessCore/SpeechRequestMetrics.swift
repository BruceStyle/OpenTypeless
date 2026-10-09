import Foundation
import OSLog

/// Request timing only. Never log URLs, headers, audio, prompts, or responses.
final class SpeechRequestMetrics: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let kind: String
    private let uploadBytes: Int
    private let logger = Logger(subsystem: "com.opentypeless.mac", category: "Network")

    init(kind: String, uploadBytes: Int) {
        self.kind = kind; self.uploadBytes = uploadBytes
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        var connection = 0.0, upload = 0.0, responseWait = 0.0
        var reused = 0
        for transaction in metrics.transactionMetrics {
            connection += Self.elapsed(transaction.connectStartDate, transaction.connectEndDate)
            upload += Self.elapsed(transaction.requestStartDate, transaction.requestEndDate)
            responseWait += Self.elapsed(transaction.requestEndDate, transaction.responseStartDate)
            if transaction.isReusedConnection { reused += 1 }
        }
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        logger.info("Speech request; kind=\(self.kind, privacy: .public), uploadBytes=\(self.uploadBytes, privacy: .public), total=\(metrics.taskInterval.duration, privacy: .public), connection=\(connection, privacy: .public), upload=\(upload, privacy: .public), responseWait=\(responseWait, privacy: .public), reusedConnections=\(reused, privacy: .public), status=\(status, privacy: .public)")
    }

    private static func elapsed(_ start: Date?, _ end: Date?) -> Double {
        guard let start, let end else { return 0 }
        return max(0, end.timeIntervalSince(start))
    }
}
