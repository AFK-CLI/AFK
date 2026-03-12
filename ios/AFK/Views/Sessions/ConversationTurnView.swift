import SwiftUI

struct ConversationTurnView: View {
    let turn: ConversationTurn
    var sessionStore: SessionStore?
    var isActive: Bool = false
    /// All task tool pairs accumulated across the session up to this turn.
    /// Only the last turn with task activity should receive a non-nil value.
    var accumulatedTaskPairs: [ToolCallPair]?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // User message bubble
            if let userText = turn.userSnippet, !userText.isEmpty {
                UserMessageBubble(text: userText)
            }

            // User-attached images (screenshots pasted to Claude Code)
            if let images = turn.userImages, !images.isEmpty {
                ForEach(images) { img in
                    ToolResultImageView(image: img)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, 8)
                }
            } else if turn.hasEncryptedUserImages {
                EncryptedImagePlaceholder()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 8)
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

            // Aggregated task progress card (shown only on the last turn with task activity)
            if let allTaskPairs = accumulatedTaskPairs, !allTaskPairs.isEmpty {
                TaskProgressCard(pairs: allTaskPairs)
            }

            // Non-task tool cards
            ForEach(nonTaskPairs) { pair in
                if pair.toolName == "AskUserQuestion" {
                    // Only show the card after the tool completes;
                    // while in-progress, the QuestionOverlay handles interaction
                    if pair.isComplete {
                        AskUserQuestionCard(pair: pair)
                    }
                } else if pair.toolName == "TodoWrite" {
                    TodoWriteCard(pair: pair)
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

    private static let taskToolNames: Set<String> = ["TaskCreate", "TaskUpdate", "TaskList", "TaskGet"]

    private var nonTaskPairs: [ToolCallPair] {
        turn.toolPairs.filter { !Self.taskToolNames.contains($0.toolName) }
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
