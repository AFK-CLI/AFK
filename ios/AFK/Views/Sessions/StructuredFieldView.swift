import SwiftUI

struct StructuredFieldView: View {
    let field: ToolInputField

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch field.style {
            case "path":
                pathView
            case "code":
                codeView
            case "badge":
                badgeView
            default:
                textView
            }
        }
    }

    // MARK: - Style renderers

    private var pathView: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(field.label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            Text(field.value)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var codeView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(field.label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            CodeSnippetView(code: field.value, language: nil)
        }
    }

    private var badgeView: some View {
        HStack(spacing: 6) {
            Text(field.label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            Text(field.value)
                .font(.caption2.monospaced().weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color(UIColor.systemGray5), in: Capsule())
        }
    }

    private var textView: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(field.label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            Text(field.value)
                .font(.caption)
                .lineLimit(5)
        }
    }
}
