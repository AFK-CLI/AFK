//
//  UsageCard.swift
//  AFK
//

import SwiftUI

struct UsageCard: View {
    let usage: ClaudeUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "gauge.with.needle")
                    .foregroundStyle(.secondary)
                Text("Claude Usage")
                    .font(.headline)
                Spacer()
                Text(subscriptionLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: .capsule)
            }

            UsageRow(
                label: "Session (5h)",
                percentage: usage.sessionPercentage,
                resetText: "Resets in \(usage.formattedResetTime(usage.sessionResetTime))",
                level: usage.sessionStatusLevel
            )

            UsageRow(
                label: "Weekly",
                percentage: usage.weeklyPercentage,
                resetText: "Resets in \(usage.formattedResetTime(usage.weeklyResetTime))",
                level: usage.weeklyStatusLevel
            )

            Divider()

            HStack(spacing: 24) {
                ModelStat(name: "Opus", percentage: usage.opusWeeklyPercentage)
                ModelStat(name: "Sonnet", percentage: usage.sonnetWeeklyPercentage)
                Spacer()
                if let deviceName = usage.deviceName {
                    Label(deviceName, systemImage: "laptopcomputer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .background(.regularMaterial, in: .rect(cornerRadius: 16))
    }

    private var subscriptionLabel: String {
        usage.subscriptionType
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "claude ", with: "")
            .capitalized
    }
}

private struct UsageRow: View {
    let label: String
    let percentage: Double
    let resetText: String
    let level: ClaudeUsage.StatusLevel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.subheadline)
                Spacer()
                Text("\(Int(percentage))%")
                    .font(.subheadline.bold())
                    .foregroundStyle(levelColor)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.quaternary)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(levelColor)
                        .frame(width: geo.size.width * min(percentage / 100, 1))
                }
            }
            .frame(height: 6)

            Text(resetText)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var levelColor: Color {
        switch level {
        case .good: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

private struct ModelStat: View {
    let name: String
    let percentage: Double

    var body: some View {
        VStack(spacing: 4) {
            Text("\(Int(percentage))%")
                .font(.subheadline.bold())
                .foregroundStyle(color)
            Text(name)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var color: Color {
        switch ClaudeUsage.statusLevel(for: percentage) {
        case .good: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }
}
