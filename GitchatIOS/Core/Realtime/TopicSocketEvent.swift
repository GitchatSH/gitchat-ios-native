import Foundation

enum TopicSocketEvent {
    case created(parentId: String, topic: Topic)
    case updated(parentId: String, topicId: String, changes: TopicUpdateChanges)
    case archived(parentId: String, topicId: String)
    case pinned(parentId: String, topicId: String, pinOrder: Int)
    case unpinned(parentId: String, topicId: String)
    case settingsUpdated(parentId: String, topicsEnabled: Bool)
    case message(parentId: String, topicId: String, message: Message)

    /// Decode a Socket.IO payload (already unwrapped from the outer envelope) into a typed event.
    /// Returns nil for events outside v1 scope (closed, reopened, deleted, unarchived) and for
    /// malformed payloads.
    static func from(eventName: String, payload: [String: Any]) -> TopicSocketEvent? {
        let parentId = payload["parentId"] as? String
                    ?? payload["conversationId"] as? String   // ext naming variant

        switch eventName {
        case "topic:created":
            guard let parentId,
                  let topicDict = payload["topic"] as? [String: Any],
                  let topic = decodeTopic(topicDict) else { return nil }
            return .created(parentId: parentId, topic: topic)

        case "topic:updated":
            guard let parentId,
                  let topicId = payload["topicId"] as? String else { return nil }
            let changes = TopicUpdateChanges(
                name: payload["name"] as? String,
                iconEmoji: payload["iconEmoji"] as? String,
                colorToken: payload["colorToken"] as? String
            )
            return .updated(parentId: parentId, topicId: topicId, changes: changes)

        case "topic:archived":
            guard let parentId,
                  let topicId = payload["topicId"] as? String else { return nil }
            return .archived(parentId: parentId, topicId: topicId)

        case "topic:pinned":
            guard let parentId,
                  let topicId = payload["topicId"] as? String,
                  let order = payload["pinOrder"] as? Int else { return nil }
            return .pinned(parentId: parentId, topicId: topicId, pinOrder: order)

        case "topic:unpinned":
            guard let parentId,
                  let topicId = payload["topicId"] as? String else { return nil }
            return .unpinned(parentId: parentId, topicId: topicId)

        case "topic:settings-updated":
            guard let parentId,
                  let enabled = payload["topicsEnabled"] as? Bool else { return nil }
            return .settingsUpdated(parentId: parentId, topicsEnabled: enabled)

        case "topic:message":
            guard let parentId,
                  let topicId = payload["topicId"] as? String,
                  let msgDict = payload["message"] as? [String: Any],
                  let msg = decodeMessage(msgDict) else { return nil }
            return .message(parentId: parentId, topicId: topicId, message: msg)

        default:
            return nil   // closed / reopened / deleted / unarchived deferred to v2
        }
    }

    private static func decodeTopic(_ dict: [String: Any]) -> Topic? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? JSONDecoder().decode(Topic.self, from: data)
    }

    private static func decodeMessage(_ dict: [String: Any]) -> Message? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? JSONDecoder().decode(Message.self, from: data)
    }
}

struct TopicUpdateChanges: Hashable {
    let name: String?
    let iconEmoji: String?
    let colorToken: String?
}
