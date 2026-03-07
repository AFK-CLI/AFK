import SwiftUI

struct PlanApprovalSheet: View {
    let request: PermissionRequest
    let onAction: (PlanAction) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var feedbackText = ""
    @FocusState private var feedbackFocused: Bool

    enum PlanAction {
        case acceptClearAutoAccept
        case acceptAutoAccept
        case acceptManual
        case feedback(String)
        case reject
    }

    private var planContent: String {
        // ExitPlanMode passes plan in toolInput — try known keys, fall back to all values
        if let plan = request.toolInput["plan"], !plan.isEmpty, plan != "null" {
            return plan
        }
        // Concatenate all non-empty, non-null values
        return request.toolInput
            .filter { $0.key != "allowedPrompts" && !$0.value.isEmpty && $0.value != "null" }
            .map { $0.value }
            .joined(separator: "\n\n")
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Plan content
                ScrollView {
                    Text(planContent)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }

                // Bottom action area
                VStack(spacing: 0) {
                    Divider()

                    VStack(spacing: 10) {
                        // Approve options
                        Button {
                            onAction(.acceptAutoAccept)
                            dismiss()
                        } label: {
                            Label("Approve & auto-accept edits", systemImage: "checkmark.circle.fill")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)

                        Button {
                            onAction(.acceptManual)
                            dismiss()
                        } label: {
                            Label("Approve, manually approve edits", systemImage: "hand.raised.circle")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)

                        // Feedback row
                        HStack(spacing: 8) {
                            TextField("Tell Claude what to change...", text: $feedbackText)
                                .textFieldStyle(.roundedBorder)
                                .font(.subheadline)
                                .focused($feedbackFocused)
                                .submitLabel(.send)
                                .onSubmit { sendFeedback() }

                            Button {
                                sendFeedback()
                            } label: {
                                Image(systemName: "paperplane.fill")
                                    .font(.body)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.purple)
                            .disabled(feedbackText.trimmingCharacters(in: .whitespaces).isEmpty)
                        }

                        // Reject button
                        Button(role: .destructive) {
                            onAction(.reject)
                            dismiss()
                        } label: {
                            Label("Reject Plan", systemImage: "xmark.circle.fill")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding()
                    .background(.ultraThinMaterial)
                }
            }
            .navigationTitle("Plan Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    CountdownBadge(expiresAt: request.expiresAtDate)
                }
            }
        }
    }

    private func sendFeedback() {
        let text = feedbackText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        onAction(.feedback(text))
        dismiss()
    }
}
