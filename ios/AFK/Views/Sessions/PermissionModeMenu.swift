import SwiftUI

struct PermissionModeMenu: View {
    let currentMode: String
    let onChange: (String) -> Void

    private var icon: String {
        switch currentMode {
        case "acceptEdits": return "pencil.circle"
        case "plan": return "eye.circle"
        case "autoApprove": return "bolt.shield"
        case "wwud": return "brain"
        default: return "shield.lefthalf.filled"
        }
    }

    private var iconColor: Color {
        switch currentMode {
        case "acceptEdits": return .orange
        case "plan": return .blue
        case "autoApprove": return .green
        case "wwud": return .purple
        default: return .secondary
        }
    }

    var body: some View {
        Menu {
            Button {
                onChange("ask")
            } label: {
                Label("Ask", systemImage: "shield.lefthalf.filled")
                if currentMode == "ask" { Image(systemName: "checkmark") }
            }

            Button {
                onChange("acceptEdits")
            } label: {
                Label("Accept Edits", systemImage: "pencil.circle")
                if currentMode == "acceptEdits" { Image(systemName: "checkmark") }
            }

            Button {
                onChange("plan")
            } label: {
                Label("Plan Mode", systemImage: "eye.circle")
                if currentMode == "plan" { Image(systemName: "checkmark") }
            }

            Button {
                onChange("autoApprove")
            } label: {
                Label("Auto-Approve", systemImage: "bolt.shield")
                if currentMode == "autoApprove" { Image(systemName: "checkmark") }
            }

            Divider()

            Button {
                onChange("wwud")
            } label: {
                Label("Smart Mode", systemImage: "brain")
                if currentMode == "wwud" { Image(systemName: "checkmark") }
            }
        } label: {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
        }
    }
}
