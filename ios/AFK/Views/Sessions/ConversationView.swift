import SwiftUI

struct ConversationView: View {
    let sessionId: String
    let sessionStore: SessionStore
    var commandStore: CommandStore?
    @State private var showTools = true
    @State private var errorsOnly = false
    @State private var turns: [ConversationTurn] = []

    private var sessionEvents: [SessionEvent] {
        sessionStore.events[sessionId] ?? []
    }

    private var session: Session? {
        sessionStore.sessions.first { $0.id == sessionId }
    }

    private var isSessionActive: Bool {
        session?.status == .running
    }

    private var filteredTurns: [ConversationTurn] {
        var result = turns

        if errorsOnly {
            result = result.filter { turn in
                turn.toolPairs.contains { $0.isError } ||
                turn.events.contains { $0.eventType == "error_raised" }
            }
        }

        if !showTools {
            result = result.map { turn in
                ConversationTurn(
                    id: turn.id,
                    turnIndex: turn.turnIndex,
                    events: turn.events,
                    toolPairs: [],
                    cachedAssistantContentBlocks: turn.cachedAssistantContentBlocks
                )
            }
        }

        return result
    }

    var body: some View {
        // Filter bar — .task/.onChange here drive turn cache updates
        HStack(spacing: 12) {
            Toggle("Tools", isOn: $showTools)
                .toggleStyle(.button)
                .buttonStyle(.bordered)
                .controlSize(.small)

            Toggle("Errors Only", isOn: $errorsOnly)
                .toggleStyle(.button)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)

            Spacer()
        }
        .padding(.horizontal)
        .task { rebuildTurns() }
        .onChange(of: sessionEvents.count) { _, _ in rebuildTurns() }

        if filteredTurns.isEmpty {
            if sessionStore.events[sessionId] == nil {
                SkeletonLoadingView()
            } else {
                ContentUnavailableView("No Events Yet", systemImage: "clock")
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            }
        } else {
            // "Load More" at the TOP for older events
            if sessionStore.eventPagination[sessionId]?.hasMore == true {
                Button {
                    Task { await sessionStore.loadMoreEvents(for: sessionId) }
                } label: {
                    HStack {
                        Text("Load Older")
                        if sessionStore.eventPagination[sessionId]?.isLoading == true {
                            SymbolSpinner()
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
                .padding(.horizontal)
            }

            ForEach(Array(filteredTurns.enumerated()), id: \.element.id) { index, turn in
                let isLast = index == filteredTurns.count - 1
                let hasCommand = commandStore?.activeCommand(for: sessionId) != nil
                    || commandStore?.completedCommand(for: sessionId) != nil
                ConversationTurnView(
                    turn: turn,
                    sessionStore: sessionStore,
                    isActive: isLast && isSessionActive && !hasCommand
                )
                .id(turn.id)
            }
            .padding(.horizontal)
        }
    }

    private func rebuildTurns() {
        turns = TurnBuilder.buildTurns(from: sessionEvents)
    }
}
