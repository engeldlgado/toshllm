import Foundation

struct QueuedChatMessage: Identifiable, Equatable {
    let conversationID: UUID
    var text: String
    var attachments: [ChatAttachment]
    var imageURIs: [String]
    var id: UUID { conversationID }
}
