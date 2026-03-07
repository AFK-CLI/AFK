import SwiftUI

// MARK: - Models

struct AskQuestion: Codable, Identifiable {
    let question: String
    let header: String
    let options: [AskOption]
    let multiSelect: Bool?

    var id: String { question }
}

struct AskOption: Codable, Identifiable {
    let label: String
    let description: String?

    var id: String { label }
}

// MARK: - Card View

struct AskUserQuestionCard: View {
    let pair: ToolCallPair

    private var questions: [AskQuestion] {
        guard let summary = pair.toolInputSummary,
              let range = summary.range(of: "questions: ") else { return [] }
        let jsonStr = String(summary[range.upperBound...])
        guard let data = jsonStr.data(using: .utf8),
              let parsed = try? JSONDecoder().decode([AskQuestion].self, from: data) else {
            return []
        }
        return parsed
    }

    /// Extract the selected answer from toolResultSummary.
    /// When answered from iOS: "User answered from AFK mobile: <answer>"
    /// When answered from Mac terminal: the raw answer text (match against option labels)
    private var selectedAnswer: String? {
        guard let result = pair.toolResultSummary else { return nil }
        // iOS answer with known prefix
        if let range = result.range(of: "User answered from AFK mobile: ") {
            return String(result[range.upperBound...])
        }
        // Mac terminal answer: try matching result text against option labels
        let opts = questions.flatMap(\.options)
        if let match = opts.first(where: { result.contains($0.label) }) {
            return match.label
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "questionmark.bubble.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .frame(width: 24)

                Text("AskUserQuestion")
                    .font(.subheadline.monospaced())
                    .lineLimit(1)

                Spacer()

                statusView
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if questions.isEmpty {
                // Fallback to raw display
                if let summary = pair.toolInputSummary {
                    Divider().padding(.horizontal, 12)
                    Text(summary)
                        .font(.caption.monospaced())
                        .lineLimit(10)
                        .padding(12)
                }
            } else {
                Divider().padding(.horizontal, 12)

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(questions) { q in
                        AnsweredQuestionSection(question: q, selectedAnswer: selectedAnswer)
                    }
                }
                .padding(12)
            }
        }
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var statusView: some View {
        if pair.isError {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        } else if pair.isComplete {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            SymbolSpinner()
        }
    }
}

// MARK: - Question Overlay (interactive, for permission requests)

struct QuestionOverlay: View {
    let request: PermissionRequest
    let onAnswer: (String) -> Void

    @State private var answers: [String: String] = [:]

    private var questions: [AskQuestion] {
        guard let json = request.toolInput["questions"],
              let data = json.data(using: .utf8),
              let parsed = try? JSONDecoder().decode([AskQuestion].self, from: data) else {
            return []
        }
        return parsed
    }

    private var allAnswered: Bool {
        let qs = questions
        return !qs.isEmpty && qs.allSatisfy { answers[$0.id] != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: "questionmark.bubble.fill")
                    .foregroundStyle(.orange)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Question from Claude")
                        .font(.subheadline.weight(.semibold))
                    if questions.count > 1 {
                        Text("\(answers.count) of \(questions.count) answered")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Tap an option to answer")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                CountdownBadge(expiresAt: request.expiresAtDate)
            }

            if questions.isEmpty {
                // Fallback: show raw input
                Text(request.toolInputPreview)
                    .font(.caption.monospaced())
                    .lineLimit(5)
            } else {
                let qs = questions
                ForEach(qs) { q in
                    InteractiveQuestionSection(
                        question: q,
                        selectedOption: answers[q.id],
                        onSelect: { label in
                            answers[q.id] = label
                            // Single question: submit immediately
                            if qs.count == 1 {
                                onAnswer(label)
                            }
                        }
                    )
                }

                // Multi-question: show submit button when all answered
                if qs.count > 1 {
                    Button {
                        let combined = qs.compactMap { answers[$0.id] }.joined(separator: "; ")
                        onAnswer(combined)
                    } label: {
                        Text("Submit Answers")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(allAnswered ? Color.orange : Color.gray.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(allAnswered ? .white : .secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!allAnswered)
                }
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.15), radius: 12, y: -4)
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}

// MARK: - Question Sections

private struct QuestionSection: View {
    let question: AskQuestion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            questionHeader
            questionOptions(interactive: false, onAnswer: nil)
        }
    }

    private var questionHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(question.header.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.orange.opacity(0.15))
                .clipShape(Capsule())

            Text(question.question)
                .font(.subheadline.weight(.medium))
        }
    }

    @ViewBuilder
    private func questionOptions(interactive: Bool, onAnswer: ((String) -> Void)?) -> some View {
        ForEach(question.options) { option in
            if interactive {
                Button { onAnswer?(option.label) } label: {
                    optionRow(option)
                }
                .buttonStyle(.plain)
            } else {
                optionRow(option)
            }
        }
    }

    private func optionRow(_ option: AskOption) -> some View {
        HStack(spacing: 8) {
            Image(systemName: question.multiSelect == true ? "square" : "circle")
                .font(.caption)
                .foregroundStyle(.tertiary)

            VStack(alignment: .leading, spacing: 2) {
                Text(option.label)
                    .font(.subheadline.weight(.medium))
                if let desc = option.description, !desc.isEmpty {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(UIColor.tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct AnsweredQuestionSection: View {
    let question: AskQuestion
    let selectedAnswer: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(question.header.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.orange.opacity(0.15))
                .clipShape(Capsule())

            Text(question.question)
                .font(.subheadline.weight(.medium))

            ForEach(question.options) { option in
                let isSelected = option.label == selectedAnswer
                HStack(spacing: 8) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.caption)
                        .foregroundStyle(isSelected ? Color.green : Color.gray.opacity(0.4))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.label)
                            .font(.subheadline.weight(isSelected ? .semibold : .medium))
                        if let desc = option.description, !desc.isEmpty {
                            Text(desc)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isSelected ? Color.green.opacity(0.1) : Color(UIColor.tertiarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSelected ? Color.green.opacity(0.3) : .clear, lineWidth: 1)
                )
            }
        }
    }
}

private struct InteractiveQuestionSection: View {
    let question: AskQuestion
    let selectedOption: String?
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(question.header.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.orange.opacity(0.15))
                .clipShape(Capsule())

            Text(question.question)
                .font(.subheadline.weight(.medium))

            ForEach(question.options) { option in
                let isSelected = option.label == selectedOption
                Button { onSelect(option.label) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isSelected
                              ? (question.multiSelect == true ? "checkmark.square.fill" : "checkmark.circle.fill")
                              : (question.multiSelect == true ? "square" : "circle"))
                            .font(.caption)
                            .foregroundStyle(isSelected ? .green : .orange)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.label)
                                .font(.subheadline.weight(isSelected ? .semibold : .medium))
                            if let desc = option.description, !desc.isEmpty {
                                Text(desc)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if !isSelected {
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(isSelected ? Color.green.opacity(0.1) : Color(UIColor.tertiarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelected ? Color.green.opacity(0.3) : .clear, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}
