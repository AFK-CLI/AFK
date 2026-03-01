import SwiftUI

struct AgentControlMenu: View {
    let deviceId: String
    let sessionStore: SessionStore

    private var state: AgentControlState {
        sessionStore.agentControl(for: deviceId)
    }

    private var iconColor: Color {
        state.remoteApproval ? .green : .secondary
    }

    var body: some View {
        Menu {
            Toggle("Remote Approval", isOn: Binding(
                get: { state.remoteApproval },
                set: { enabled in
                    Task { await sessionStore.setAgentRemoteApproval(deviceId: deviceId, enabled: enabled) }
                }
            ))

            Toggle("Auto Plan Exit", isOn: Binding(
                get: { state.autoPlanExit },
                set: { enabled in
                    Task { await sessionStore.setAgentAutoPlanExit(deviceId: deviceId, enabled: enabled) }
                }
            ))
        } label: {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundStyle(iconColor)
        }
    }
}
