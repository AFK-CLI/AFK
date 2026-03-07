//
//  Agent+ControlState.swift
//  AFK-Agent
//

import Foundation
import OSLog

extension Agent {

    func broadcastControlState() async {
        guard let client = wsClient, let deviceId = enrolledDeviceId else { return }
        let remoteApproval = !StatusBarController.isHookBypassed
        if let msg = try? MessageEncoder.controlState(deviceID: deviceId, remoteApproval: remoteApproval, autoPlanExit: false) {
            try? await client.send(msg)
            AppLogger.agent.info("Broadcast control state: remoteApproval=\(remoteApproval, privacy: .public)")
        }
    }
}
