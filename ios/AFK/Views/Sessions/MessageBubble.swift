import SwiftUI

struct UserMessageBubble: View {
    let text: String
    @State private var showFull = false

    private var isTruncatable: Bool {
        text.count > 300 || text.components(separatedBy: "\n").count > 8
    }

    var body: some View {
        HStack {
            Spacer(minLength: 60)
            VStack(alignment: .trailing, spacing: 4) {
                Text(text)
                    .font(.body)
                    .lineLimit(isTruncatable ? 8 : nil)

                if isTruncatable {
                    Text("Show more...")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
            }
            .padding(12)
            .background(Color.blue.opacity(0.15))
            .foregroundStyle(.primary)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .onTapGesture {
                if isTruncatable { showFull = true }
            }
        }
        .sheet(isPresented: $showFull) {
            FullMessageSheet(text: text)
        }
    }
}

struct AssistantMessageBubble: View {
    let text: String
    @State private var showFull = false

    private var isTruncatable: Bool {
        text.count > 300 || text.components(separatedBy: "\n").count > 8
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            MarkdownText(text: text, maxBlocks: isTruncatable ? 4 : nil)

            if isTruncatable {
                Text("Show more...")
                    .font(.caption)
                    .foregroundStyle(.blue)
                    .onTapGesture { showFull = true }
            }
        }
        .sheet(isPresented: $showFull) {
            FullMessageSheet(text: text)
        }
    }
}

struct FullMessageSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                MarkdownText(text: text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("Full Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        UIPasteboard.general.string = text
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                }
            }
        }
        .presentationDragIndicator(.visible)
    }
}

struct ThinkingIndicator: View {
    var body: some View {
        HStack {
            HStack(spacing: 6) {
                SymbolSpinner(size: 18)
                Text("Thinking…")
                    .font(.subheadline)
                    .foregroundStyle(.orange.opacity(0.7))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.orange.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            Spacer(minLength: 60)
        }
    }
}
