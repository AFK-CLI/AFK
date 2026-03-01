import SwiftUI

struct SlashCommand: Identifiable {
    let id = UUID()
    let command: String
    let label: String
    let icon: String
    let description: String
}

struct SlashCommandMenu: View {
    let commands: [SlashCommand]
    let onSelect: (SlashCommand) -> Void

    static let availableCommands: [SlashCommand] = [
        SlashCommand(command: "/status", label: "Status", icon: "info.circle", description: "Show session status"),
        SlashCommand(command: "/cost", label: "Cost", icon: "dollarsign.circle", description: "Show cost breakdown"),
        SlashCommand(command: "/compact", label: "Compact", icon: "arrow.down.right.and.arrow.up.left", description: "Compact conversation"),
        SlashCommand(command: "/help", label: "Help", icon: "questionmark.circle", description: "Show available commands"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(commands) { command in
                Button {
                    onSelect(command)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: command.icon)
                            .foregroundStyle(.blue)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(command.command)
                                .font(.subheadline.monospaced().weight(.medium))
                            Text(command.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if command.id != commands.last?.id {
                    Divider().padding(.leading, 46)
                }
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.1), radius: 8, y: -2)
    }
}
