//
//  Agent+ControlState.swift
//  AFK-Agent
//

import Foundation

extension Agent {

    func broadcastControlState() async {
        guard let client = wsClient, let deviceId = enrolledDeviceId else { return }
        let remoteApproval = !StatusBarController.isHookBypassed
        let autoPlanExit = StatusBarController.isPlanAutoExitEnabled
        if let msg = try? MessageEncoder.controlState(deviceID: deviceId, remoteApproval: remoteApproval, autoPlanExit: autoPlanExit) {
            try? await client.send(msg)
            print("[Agent] Broadcast control state: remoteApproval=\(remoteApproval) autoPlanExit=\(autoPlanExit)")
        }
    }
}
