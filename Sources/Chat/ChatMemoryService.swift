import Foundation

/// A stretch of transcript left out of the request history. The messages stay in
/// the conversation and on disk.
struct ArchivedBlock: Identifiable, Codable, Equatable {
    var id = UUID()
    /// Half-open range of message indices, `from ..< to`.
    var from: Int
    var to: Int
    /// Why the model set it aside, shown in the transcript and returned by recall.
    var note: String
    var date = Date.now

    func covers(_ index: Int) -> Bool { index >= from && index < to }
}

/// The model's own context tools. Plain OpenAI functions, so an external client
/// sees them like any other tool.
enum ChatMemoryService {
    static let listName    = "memory_list"
    static let archiveName = "memory_archive"
    static let recallName  = "memory_recall"

    static let toolNames = [listName, archiveName, recallName]

    /// On unless the user turned them off; the key is absent for everyone who
    /// never opened the setting.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: SettingsKeys.memoryToolsEnabled) as? Bool ?? true
    }

    /// Characters of a message shown in a listing or a recall hit. Enough to
    /// recognise a topic without spending the context the archive just freed.
    static let previewCharacters = 200
    static let maximumRecallCharacters = 6_000

    static let tools: [BuiltinToolInfo] = [
        try! BuiltinToolInfo(
            displayName: "List conversation memory",
            name: listName,
            writesData: false,
            definition: [
                "type": "function",
                "function": [
                    "name": listName,
                    "description": "List the turns of this conversation with their index, so a range can be archived. Also reports which ranges are already archived.",
                    "parameters": ["type": "object", "properties": [:] as [String: Any]]
                ]
            ]),
        try! BuiltinToolInfo(
            displayName: "Archive part of the conversation",
            name: archiveName,
            writesData: false,
            definition: [
                "type": "function",
                "function": [
                    "name": archiveName,
                    "description": "Set a range of turns aside so it stops being sent with every request, freeing context. The turns stay in the transcript and can be brought back with memory_recall. Use it when a topic is finished.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "from_index": ["type": "number", "description": "First turn index to archive, from memory_list"],
                            "to_index": ["type": "number", "description": "Last turn index to archive, inclusive"],
                            "note": ["type": "string", "description": "Short description of what this range was about, used to find it later"]
                        ],
                        "required": ["from_index", "to_index", "note"]
                    ]
                ]
            ]),
        try! BuiltinToolInfo(
            displayName: "Recall archived conversation",
            name: recallName,
            writesData: false,
            definition: [
                "type": "function",
                "function": [
                    "name": recallName,
                    "description": "Search the archived parts of this conversation and return the matching turns verbatim. Use it when an earlier topic becomes relevant again.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "query": ["type": "string", "description": "Words to look for in the archived turns"],
                            "max_results": ["type": "number", "description": "How many turns to return, default 4"]
                        ],
                        "required": ["query"]
                    ]
                ]
            ])
    ]

    // MARK: pure helpers, so the behaviour is testable without a store

    /// Indices the request history must skip: everything an archived block covers.
    static func archivedIndices(_ blocks: [ArchivedBlock]?) -> Set<Int> {
        guard let blocks else { return [] }
        var set = Set<Int>()
        for b in blocks where b.to > b.from { set.formUnion(b.from..<b.to) }
        return set
    }

    /// Rewrites the blocks after the transcript shrinks: the indices now belong to
    /// different messages.
    static func clamped(_ blocks: [ArchivedBlock]?, toCount count: Int) -> [ArchivedBlock]? {
        guard let blocks else { return nil }
        let kept = blocks.compactMap { b -> ArchivedBlock? in
            guard b.from < count else { return nil }
            var b = b
            b.to = min(b.to, count)
            return b.to > b.from ? b : nil
        }
        return kept.isEmpty ? nil : kept
    }

    /// The last exchange is never archivable: putting away the turn being answered
    /// would strand the reply.
    static func validate(from: Int, to: Int, messageCount: Int, summarized: Int) -> (from: Int, to: Int)? {
        let lower = max(from, summarized)
        let upper = min(to + 1, max(0, messageCount - 2))
        guard lower >= 0, upper > lower, upper <= messageCount else { return nil }
        return (lower, upper)
    }

    static func preview(_ text: String) -> String {
        let flat = text.replacing("\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count <= previewCharacters
            ? flat : String(flat.prefix(previewCharacters)) + "…"
    }

    /// Turns whose text contains every word of the query, most recent first.
    static func matches(query: String, in blocks: [ArchivedBlock], texts: [Int: String],
                        limit: Int) -> [Int] {
        // localizedStandardContains is what a person expects from a search box:
        // case- and diacritic-insensitive, and correct outside English.
        let words = query.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !words.isEmpty else { return [] }
        var hits: [Int] = []
        for index in archivedIndices(blocks).sorted(by: >) {
            guard let text = texts[index] else { continue }
            if words.allSatisfy({ text.localizedStandardContains($0) }) { hits.append(index) }
            if hits.count >= limit { break }
        }
        return hits.sorted()
    }
}
