import SwiftUI

struct ConversationView: View {
    let sessionId: String
    let sessionStore: SessionStore
    var commandStore: CommandStore?
    @State private var showTools = true
    @State private var errorsOnly = false
    @State private var turns: [ConversationTurn] = []
    @State private var rebuildTask: Task<Void, Never>?

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
                    cachedAssistantContentBlocks: turn.cachedAssistantContentBlocks,
                    cachedUserContentBlocks: turn.cachedUserContentBlocks
                )
            }
        }

        return result
    }

    var body: some View {
        let currentTurns = filteredTurns

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
        .onChange(of: sessionEvents.count) { _, _ in
            rebuildTask?.cancel()
            rebuildTask = Task {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                rebuildTurns()
            }
        }

        // Compute aggregated task pairs across all turns and find the last turn with task activity
        let taskToolNames: Set<String> = ["TaskCreate", "TaskUpdate", "TaskList", "TaskGet"]
        let allTaskPairs = currentTurns.flatMap { $0.toolPairs.filter { taskToolNames.contains($0.toolName) } }
        let lastTaskTurnId: String? = currentTurns.last(where: { $0.toolPairs.contains { taskToolNames.contains($0.toolName) } })?.id

        if currentTurns.isEmpty {
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

            ForEach(currentTurns) { turn in
                let isLast = turn.id == currentTurns.last?.id
                let hasCommand = commandStore?.activeCommand(for: sessionId) != nil
                    || commandStore?.completedCommand(for: sessionId) != nil
                ConversationTurnView(
                    turn: turn,
                    sessionStore: sessionStore,
                    isActive: isLast && isSessionActive && !hasCommand,
                    accumulatedTaskPairs: turn.id == lastTaskTurnId ? allTaskPairs : nil
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
