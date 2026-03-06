import SwiftUI

struct ConversationTurnView: View {
    let turn: ConversationTurn
    var sessionStore: SessionStore?
    var isActive: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // User message bubble
            if let userText = turn.userSnippet, !userText.isEmpty {
                UserMessageBubble(text: userText)
            }

            // Teammate/task cards from user messages
            if let userBlocks = turn.userContentBlocks {
                ForEach(userBlocks) { block in
                    switch block {
                    case .text:
                        EmptyView()
                    case .taskNotification(let data):
                        TaskNotificationCard(data: data)
                    case .teammateMessage(let data):
                        if !data.shouldHide {
                            TeammateMessageCard(data: data)
                        }
                    }
                }
            }

            // Assistant content (text interleaved with task/teammate cards)
            if let blocks = turn.assistantContentBlocks {
                ForEach(blocks) { block in
                    switch block {
                    case .text(let text):
                        AssistantMessageBubble(text: text)
                    case .taskNotification(let data):
                        TaskNotificationCard(data: data)
                    case .teammateMessage(let data):
                        if !data.shouldHide {
                            TeammateMessageCard(data: data)
                        }
                    }
                }
            } else if isActive {
                ThinkingIndicator()
            }

            // Rich tool cards
            ForEach(turn.toolPairs) { pair in
                if pair.toolName == "AskUserQuestion" {
                    // Only show the card after the tool completes;
                    // while in-progress, the QuestionOverlay handles interaction
                    if pair.isComplete {
                        AskUserQuestionCard(pair: pair)
                    }
                } else {
                    RichToolCallCard(pair: pair)
                }
            }

            // Non-tool lifecycle events (permission banners, errors)
            ForEach(nonToolEvents) { event in
                eventView(for: event)
            }
        }
    }

    private var nonToolEvents: [SessionEvent] {
        turn.events.filter { event in
            switch event.eventType {
            case "tool_started", "tool_finished", "turn_started", "usage_update", "assistant_responding":
                return false
            default:
                return true
            }
        }
    }

    @ViewBuilder
    private func eventView(for event: SessionEvent) -> some View {
        switch event.eventType {
        case "permission_needed":
            // Passive notification only — the PermissionOverlay at the bottom
            // of SessionDetailView handles approve/deny interaction.
            PermissionBanner(event: event)
        case "error_raised":
            ErrorBanner(event: event)
        default:
            SessionLifecycleBanner(event: event)
        }
    }
}
