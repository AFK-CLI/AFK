import SwiftUI

struct RichToolCallCard: View {
    let pair: ToolCallPair
    @State private var isExpanded = false

    private var contextLine: String? {
        // Primary: agent-computed description (no parsing needed)
        if let desc = pair.toolDescription, desc != pair.toolName {
            return desc
        }
        // Fallback: parse on-device if agent didn't provide a description
        return ToolContextParser.contextLine(toolName: pair.toolName, toolInputSummary: pair.toolInputSummary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: resolvedIcon)
                        .font(.subheadline)
                        .foregroundStyle(resolvedColor)
                        .frame(width: 24)

                    Text(resolvedLabel)
                        .font(.subheadline)
                        .lineLimit(1)

                    Spacer()

                    statusView

                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)

            // Expandable content
            if isExpanded {
                Divider()
                    .padding(.horizontal, 12)

                VStack(alignment: .leading, spacing: 8) {
                    // Structured fields (provider-first), fallback to legacy summary
                    if let fields = pair.toolInputFields, !fields.isEmpty {
                        ForEach(fields) { field in
                            StructuredFieldView(field: field)
                        }
                    } else if let input = pair.toolInputSummary {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Input")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            if looksLikeCode(input) {
                                CodeSnippetView(code: input, language: nil)
                            } else {
                                Text(input)
                                    .font(.caption.monospaced())
                                    .lineLimit(10)
                            }
                        }
                    }

                    if let result = pair.toolResultSummary {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Result")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            if looksLikeCode(result) {
                                CodeSnippetView(code: result, language: nil)
                            } else {
                                Text(result)
                                    .font(.caption.monospaced())
                                    .lineLimit(10)
                            }
                        }
                    }

                    if let images = pair.toolResultImages, !images.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(images) { img in
                                ToolResultImageView(image: img)
                            }
                        }
                    }

                    if pair.toolInputFields == nil && pair.toolInputSummary == nil && pair.toolResultSummary == nil && (pair.toolResultImages ?? []).isEmpty {
                        Text("No content available")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(12)
            }
        }
        .background(backgroundColor, in: RoundedRectangle(cornerRadius: 8))
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

    // MARK: - Provider-first display resolution

    private var resolvedIcon: String {
        pair.toolIcon ?? legacyCategoryIcon
    }

    private var resolvedColor: Color {
        if let hex = pair.toolIconColor {
            return Color(hex: hex)
        }
        return legacyCategoryColor
    }

    private var resolvedLabel: String {
        pair.toolDescription ?? pair.toolName
    }

    // MARK: - Legacy fallbacks

    private var legacyCategoryIcon: String {
        switch pair.toolCategory {
        case "question":   "questionmark.bubble.fill"
        case "plan_enter": "map.fill"
        case "plan_exit":  "map.fill"
        case "task":       "checklist"
        default:           "wrench.fill"
        }
    }

    private var legacyCategoryColor: Color {
        switch pair.toolCategory {
        case "question":                .orange
        case "plan_enter", "plan_exit": .purple
        case "task":                    .blue
        default:
            pair.isError ? .red : .gray
        }
    }

    private var backgroundColor: Color {
        if pair.isError {
            return Color.red.opacity(0.08)
        }
        return Color(UIColor.secondarySystemGroupedBackground)
    }

    private func looksLikeCode(_ text: String) -> Bool {
        text.contains("\n") || text.hasPrefix("```") || text.hasPrefix("func ") || text.hasPrefix("def ") || text.hasPrefix("class ") || text.hasPrefix("{") || text.hasPrefix("[")
    }
}
