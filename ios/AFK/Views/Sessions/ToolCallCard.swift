import SwiftUI

struct ToolCallCard: View {
    let pair: ToolCallPair

    var body: some View {
        HStack(spacing: 10) {
            // Provider-first icon with legacy fallback
            Image(systemName: resolvedIcon)
                .font(.subheadline)
                .foregroundStyle(resolvedColor)
                .frame(width: 24)

            // Provider-first label with legacy fallback
            Text(resolvedLabel)
                .font(.subheadline)
                .lineLimit(1)

            Spacer()

            // Status indicator
            statusView
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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
}
