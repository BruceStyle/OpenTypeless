import XCTest
@testable import OpenTypeless

final class FocusedInputTraversalTests: XCTestCase {
    private struct Node {
        var input = false
        var focused = false
        var focus: Int?
        var children: [Int] = []
    }
    private func traversal(_ nodes: [Int: Node]) -> FocusedInputTraversal<Int> {
        .init(isInput: { nodes[$0]?.input == true },
              isFocused: { nodes[$0]?.focused == true },
              focusedChild: { nodes[$0]?.focus },
              children: { nodes[$0]?.children ?? [] }, same: ==)
    }
    func testDirectSystemFocusDoesNotRequireDuplicateFocusedFlag() {
        XCTAssertEqual(traversal([0: Node(input: true)]).resolve(0).node, 0)
    }
    func testNestedFocusContainersLeadToEditorOutsideChildLists() {
        let graph = [0: Node(focus: 1), 1: Node(focus: 2), 2: Node(input: true)]
        XCTAssertEqual(traversal(graph).resolve(0).node, 2)
    }
    func testExplicitFocusChainTakesPriorityOverLongConversationContents() {
        var graph = [0: Node(focus: 1, children: Array(10..<200)),
                     1: Node(focus: 2), 2: Node(input: true)]
        for index in 10..<200 { graph[index] = Node() }
        let result = traversal(graph).resolve(0)
        XCTAssertEqual(result.node, 2)
        XCTAssertEqual(result.visited, 3)
    }
    func testVisibleUnfocusedTextFieldsAreNeverChosen() {
        let graph = [0: Node(children: [1, 2]), 1: Node(input: true), 2: Node(input: true)]
        XCTAssertNil(traversal(graph).resolve(0).node)
    }
    func testFocusedDescendantWinsOverAnotherVisibleCaret() {
        let graph = [0: Node(children: [1, 2]),
                     1: Node(input: true), 2: Node(input: true, focused: true)]
        XCTAssertEqual(traversal(graph).resolve(0).node, 2)
    }
    func testCyclesDoNotPreventReachingFocusedSibling() {
        let graph = [0: Node(focus: 1, children: [2]),
                     1: Node(focus: 0, children: [1]), 2: Node(input: true, focused: true)]
        XCTAssertEqual(traversal(graph).resolve(0).node, 2)
    }
    func testUnfocusedSearchStaysBoundedAndReportsTruncation() {
        var graph = [0: Node(children: Array(1...100))]
        for index in 1...100 { graph[index] = Node() }
        let result = traversal(graph).resolve(0, maximumNodes: 16)
        XCTAssertNil(result.node)
        XCTAssertEqual(result.visited, 16)
        XCTAssertTrue(result.limitReached)
    }
    func testWindowFallbackRequiresExplicitlyFocusedEditor() {
        let graph = [0: Node(children: [1, 2]), 1: Node(input: true),
                     2: Node(input: true, focused: true)]
        XCTAssertEqual(traversal(graph).resolve(0, rootIsFocused: false).node, 2)
        XCTAssertNil(traversal([0: Node(input: true)]).resolve(0, rootIsFocused: false).node)
    }
    func testFocusWindowCanResolveEditorPastTheOldSixtyFourNodeLimit() {
        var graph = [0: Node(children: Array(1...100))]
        for index in 1..<100 { graph[index] = Node() }
        graph[100] = Node(input: true, focused: true)
        XCTAssertEqual(traversal(graph).resolve(0, rootIsFocused: false, maximumNodes: 512).node, 100)
    }
    func testTimeBudgetStopsTreeWalkWithoutSelectingAnUnfocusedField() {
        let graph = [0: Node(children: [1]), 1: Node(input: true, focused: true)]
        var checks = 0
        let result = traversal(graph).resolve(0, shouldContinue: { checks += 1; return checks <= 1 })
        XCTAssertNil(result.node)
        XCTAssertEqual(result.visited, 1)
        XCTAssertTrue(result.limitReached)
    }
    func testUnfocusedPaneRememberingAnOldCaretCannotStealWindowFallback() {
        let graph = [0: Node(children: [1, 2]), 1: Node(focus: 3),
                     2: Node(input: true, focused: true), 3: Node(input: true)]
        XCTAssertEqual(traversal(graph).resolve(0, rootIsFocused: false).node, 2)
    }
    func testExplicitFocusCanConfirmAnEditorPreviouslySeenAsUnfocused() {
        let graph = [0: Node(children: [1, 2]), 1: Node(input: true),
                     2: Node(focused: true, focus: 1)]
        XCTAssertEqual(traversal(graph).resolve(0, rootIsFocused: false).node, 1)
    }
}
