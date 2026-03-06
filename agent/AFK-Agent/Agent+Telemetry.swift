//
//  Agent+Telemetry.swift
//  AFK-Agent
//

import Foundation
import OSLog

extension Agent {
    func setupOTLPReceiver() async {
        let receiver = OTLPReceiver()
        self.otlpReceiver = receiver

        await receiver.setOnMetrics { [weak self] metrics in
            guard let self, let client = await self.wsClient else { return }
            do {
                let msg = try MessageEncoder.sessionMetrics(
                    sessionId: metrics.sessionId,
                    model: metrics.model,
                    costUsd: metrics.costUsd,
                    inputTokens: metrics.inputTokens,
                    outputTokens: metrics.outputTokens,
                    cacheReadTokens: metrics.cacheReadTokens,
                    cacheCreationTokens: metrics.cacheCreationTokens,
                    durationMs: metrics.durationMs
                )
                try await client.send(msg)
                AppLogger.agent.info("Sent session metrics: session=\(metrics.sessionId.prefix(8), privacy: .public) cost=$\(metrics.costUsd, privacy: .public) model=\(metrics.model, privacy: .public)")
            } catch {
                AppLogger.agent.error("Failed to send session metrics: \(error.localizedDescription, privacy: .public)")
            }
        }

        do {
            try await receiver.start()
        } catch {
            AppLogger.agent.error("OTLP receiver failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }
}
