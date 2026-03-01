import Combine
import SwiftUI

/// A compact cycling-symbol spinner that matches the ThinkingIndicator style.
/// Drop-in replacement for `ProgressView().controlSize(.small)`.
struct SymbolSpinner: View {
    var color: Color = .orange
    var size: CGFloat = 14

    private static let frames: [String] = ["·", "✻", "✽", "✶", "✳", "✢"]
    @State private var frameIndex = 0

    private let timer = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(Self.frames[frameIndex])
            .font(.system(size: size, weight: .medium, design: .monospaced))
            .foregroundStyle(color)
            .onReceive(timer) { _ in
                frameIndex = (frameIndex + 1) % Self.frames.count
            }
    }
}
