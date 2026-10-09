/// Resolves an accessibility focus path without treating every visible editor
/// as focused. The accessors also allow testing web-container graphs without
/// reading or controlling the user's applications.
struct FocusedInputTraversal<Node> {
    struct Result {
        let node: Node?
        let visited: Int
        let limitReached: Bool
    }

    let isInput: (Node) -> Bool
    let isFocused: (Node) -> Bool
    let focusedChild: (Node) -> Node?
    let children: (Node) -> [Node]
    let same: (Node, Node) -> Bool

    func resolve(_ root: Node, rootIsFocused: Bool = true, maximumNodes: Int = 64,
                 shouldContinue: () -> Bool = { true }) -> Result {
        var pending: [(node: Node, focusPath: Bool)] = [(root, rootIsFocused)]
        var visited: [Node] = []
        var cursor = 0
        var truncated = false
        while cursor < pending.count, visited.count < maximumNodes, shouldContinue() {
            let current = pending[cursor]; cursor += 1
            guard !visited.contains(where: { same($0, current.node) }) else { continue }
            visited.append(current.node)
            let ownsFocus = current.focusPath || isFocused(current.node)
            if ownsFocus, isInput(current.node) {
                return Result(node: current.node, visited: visited.count, limitReached: false)
            }
            // A focused element may itself be a web container. Follow that
            // focus chain before spending the bounded walk on page contents.
            if ownsFocus || same(current.node, root),
               let focused = focusedChild(current.node), !same(focused, current.node) {
                let alreadyVisited = visited.contains(where: { same($0, focused) })
                let examined = visited.count + (alreadyVisited ? 0 : 1)
                if examined <= maximumNodes, isInput(focused) {
                    return Result(node: focused, visited: examined, limitReached: false)
                }
                if !alreadyVisited { pending.insert((focused, true), at: cursor) }
            }
            let descendants = children(current.node)
            let capacity = max(0, maximumNodes - visited.count - (pending.count - cursor))
            if descendants.count > capacity { truncated = true }
            pending.append(contentsOf: descendants.prefix(capacity).map { ($0, false) })
        }
        return Result(node: nil, visited: visited.count,
                      limitReached: truncated || cursor < pending.count)
    }
}
