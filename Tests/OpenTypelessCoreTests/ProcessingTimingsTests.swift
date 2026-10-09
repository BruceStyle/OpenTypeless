import Foundation
import XCTest
@testable import OpenTypelessCore

final class ProcessingTimingsTests: XCTestCase {
    func testPreviousHistoryWithoutDeliveryMilestonesStillDecodes() throws {
        let data = Data(#"{"recognition":2,"rewriting":1,"insertion":1.3,"total":4.3}"#.utf8)
        let timing = try JSONDecoder().decode(ProcessingTimings.self, from: data)
        XCTAssertEqual(timing.total, 4.3)
        XCTAssertNil(timing.textReady)
        XCTAssertNil(timing.pastePosted)
    }

    func testPreviewDoesNotInventPasteTimestampAndMilestonesSurvivePersistence() throws {
        for posted: Double? in [nil, 3.02] {
            let timing = ProcessingTimings(recognition: 2, rewriting: 1, insertion: 0.3, total: 3.3,
                                           textReady: 3, pastePosted: posted)
            let decoded = try JSONDecoder().decode(ProcessingTimings.self, from: JSONEncoder().encode(timing))
            XCTAssertEqual(decoded.textReady, 3)
            XCTAssertEqual(decoded.pastePosted, posted)
        }
    }
}
