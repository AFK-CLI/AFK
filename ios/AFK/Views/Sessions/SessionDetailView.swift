import SwiftUI

struct SessionDetailView: View {
    let sessionId: String
    let sessionStore: SessionStore
    let commandStore: CommandStore
    let apiClient: APIClient
    var taskStore: TaskStore?
    var todoStore: TodoStore?
    @State private var showPlanSheet = false
    @State private var showSessionInfo = false
    @State private var showTodoPopover = false

    private var session: Session? {
        sessionStore.sessions.first { $0.id == sessionId }
    }

    private var isPromptDisabled: Bool {
        commandStore.activeCommand(for: sessionId) != nil
    }

    var body: some View {
        ScrollView {
            content
        }
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
        .background(Color(UIColor.systemGroupedBackground))
        .overlay(alignment: .bottomTrailing) {
            if let taskStore {
                FloatingTaskButton(sessionId: sessionId, taskStore: taskStore)
                    .padding(.trailing, 16)
                    .padding(.bottom, 8)
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                // Queue waiting indicator (before E2EE is ready)
                if let queued = sessionStore.queuedPermissions.first(where: { $0.sessionId == sessionId && !$0.isExpired }) {
                    HStack(spacing: 10) {
                        ProgressView()
                            .tint(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Permission request pending")
                                .font(.subheadline.weight(.medium))
                            Text("Waiting for secure connection...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        CountdownBadge(expiresAt: queued.expiresAtDate)
                    }
                    .padding(12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)
                    .padding(.bottom, 4)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Permission overlay (appears above prompt composer)
                if let permRequest = sessionStore.pendingPermission(for: sessionId) {
                    if permRequest.toolName == "ExitPlanMode" {
                        // Plan approval — compact banner that opens the full plan sheet
                        planReviewBanner(request: permRequest)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else if permRequest.toolName == "AskUserQuestion" {
                        // Interactive question — show options the user can tap
                        QuestionOverlay(
                            request: permRequest,
                            onAnswer: { answer in
                                Task { await sessionStore.sendPermissionResponse(nonce: permRequest.nonce, action: "answer:\(answer)") }
                            }
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else {
                        PermissionOverlay(
                            request: permRequest,
                            onApprove: {
                                Task { await sessionStore.sendPermissionResponse(nonce: permRequest.nonce, action: "allow") }
                            },
                            onDeny: {
                                Task { await sessionStore.sendPermissionResponse(nonce: permRequest.nonce, action: "deny") }
                            }
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }

                PromptComposer(
                    sessionId: sessionId,
                    commandStore: commandStore,
                    apiClient: apiClient,
                    isDisabled: isPromptDisabled
                )
            }
            .animation(.spring(duration: 0.3), value: sessionStore.pendingPermission(for: sessionId)?.nonce)
        }
        .navigationTitle(session?.projectName ?? "Session")
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let session {
                    PermissionModeMenu(
                        currentMode: sessionStore.permissionMode(for: session.deviceId),
                        onChange: { mode in
                            Task { await sessionStore.setPermissionMode(deviceId: session.deviceId, mode: mode) }
                        }
                    )
                }
                if todoStore != nil, session?.projectId != nil {
                    Button {
                        showTodoPopover = true
                    } label: {
                        Image(systemName: "checklist")
                    }
                    .popover(isPresented: $showTodoPopover) {
                        if let todoStore, let projectId = session?.projectId {
                            TodoPopoverView(projectId: projectId, todoStore: todoStore)
                        }
                    }
                }
                Button {
                    showSessionInfo = true
                } label: {
                    Image(systemName: "info.circle")
                }
            }
        }
        .refreshable {
            await sessionStore.loadEvents(for: sessionId)
        }
        .task {
            sessionStore.viewingSessionIds.insert(sessionId)
            await sessionStore.loadEvents(for: sessionId)
        }
        .onDisappear {
            sessionStore.viewingSessionIds.remove(sessionId)
        }
        .onChange(of: sessionStore.pendingPermission(for: sessionId)?.nonce) { oldNonce, newNonce in
            if newNonce != nil {
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.warning)
                // Auto-present plan sheet for ExitPlanMode
                if sessionStore.pendingPermission(for: sessionId)?.toolName == "ExitPlanMode" {
                    showPlanSheet = true
                }
            }
            // Dismiss plan sheet when permission resolves/expires
            if oldNonce != nil && newNonce == nil {
                showPlanSheet = false
            }
        }
        .sheet(isPresented: $showPlanSheet) {
            if let permRequest = sessionStore.pendingPermission(for: sessionId),
               permRequest.toolName == "ExitPlanMode" {
                PlanApprovalSheet(
                    request: permRequest,
                    onAction: { planAction in
                        let action: String
                        switch planAction {
                        case .acceptClearAutoAccept: action = "plan:accept-clear-auto"
                        case .acceptAutoAccept:      action = "plan:accept-auto"
                        case .acceptManual:          action = "plan:accept-manual"
                        case .feedback(let text):    action = "plan:feedback:\(text)"
                        case .reject:                action = "plan:reject"
                        }
                        Task { await sessionStore.sendPermissionResponse(nonce: permRequest.nonce, action: action) }
                    }
                )
                .interactiveDismissDisabled()
            }
        }
        .sheet(isPresented: $showSessionInfo) {
            if let session {
                let siblings = sessionStore.sessions.filter {
                    $0.projectName == session.projectName && $0.id != session.id
                }
                SessionInfoSheet(session: session, siblingsSessions: siblings)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ConversationView(sessionId: sessionId, sessionStore: sessionStore, commandStore: commandStore)

            if let activeCmd = commandStore.activeCommand(for: sessionId) {
                StreamingOutputView(
                    commandState: activeCmd,
                    onStop: {
                        Task {
                            try? await apiClient.cancelCommand(sessionId: sessionId, commandId: activeCmd.id)
                        }
                    },
                    onDismiss: { commandStore.clearCommand(sessionId: sessionId) }
                )
                .padding(.horizontal)
            }

            if let completedCmd = commandStore.completedCommand(for: sessionId) {
                StreamingOutputView(
                    commandState: completedCmd,
                    onStop: {},
                    onDismiss: { commandStore.clearCommand(sessionId: sessionId) },
                    onRetry: completedCmd.prompt != nil ? {
                        retryCommand(prompt: completedCmd.prompt!)
                    } : nil
                )
                .padding(.horizontal)
            }
        }
        .padding(.vertical)
    }

    private func retryCommand(prompt: String) {
        commandStore.clearCommand(sessionId: sessionId)
        Task {
            do {
                let response = try await apiClient.continueSession(sessionId: sessionId, prompt: prompt)
                commandStore.startCommand(id: response.commandId, sessionId: sessionId, prompt: prompt)
            } catch {
                print("[SessionDetail] Retry failed: \(error)")
            }
        }
    }

    @ViewBuilder
    private func planReviewBanner(request: PermissionRequest) -> some View {
        Button { showPlanSheet = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.title3)
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Plan Ready for Review")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("Tap to review and approve")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                CountdownBadge(expiresAt: request.expiresAtDate)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.15), radius: 12, y: -4)
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}
