import Foundation

struct PendingAgentContinuation: Identifiable, Equatable {
    let conversationID: UUID
    var id: UUID { conversationID }
}
