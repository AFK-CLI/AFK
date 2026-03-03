import SwiftUI

struct AgentFeedbackView: View {
    let onSubmit: (String, String) -> Void
    let onCancel: () -> Void

    @State private var category = "general"
    @State private var message = ""

    private let categories = [
        ("bug_report", "Bug Report"),
        ("feature_request", "Feature Request"),
        ("general", "General")
    ]

    var body: some View {
        VStack(spacing: 16) {
            Text("Send Feedback")
                .font(.title2.bold())
                .foregroundStyle(.white)

            Picker("Category", selection: $category) {
                ForEach(categories, id: \.0) { value, label in
                    Text(label).tag(value)
                }
            }
            .pickerStyle(.segmented)

            ZStack(alignment: .topLeading) {
                TextEditor(text: $message)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(Color.white.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                if message.isEmpty {
                    Text("Describe your feedback...")
                        .foregroundStyle(.white.opacity(0.3))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 150)

            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Submit") {
                    onSubmit(category, message.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: NSColor(red: 0.043, green: 0.102, blue: 0.18, alpha: 1)))
    }
}
