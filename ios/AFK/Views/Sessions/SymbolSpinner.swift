import SwiftUI

/// Shared clock that drives all SymbolSpinner instances at 5 fps.
/// One timer instead of N per-instance timers eliminates cascading re-renders.
@Observable
final class SpinnerClock {
    static let shared = SpinnerClock()

    private(set) var tick: UInt64 = 0
    @ObservationIgnored private var timer: Timer?

    private init() {
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.tick &+= 1
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}

/// A compact cycling-symbol spinner that matches the ThinkingIndicator style.
/// Drop-in replacement for `ProgressView().controlSize(.small)`.
struct SymbolSpinner: View {
    var color: Color = .orange
    var size: CGFloat = 14

    private static let frames: [String] = ["·", "✻", "✽", "✶", "✳", "✢"]

    var body: some View {
        let index = Int(SpinnerClock.shared.tick % UInt64(Self.frames.count))
        Text(Self.frames[index])
            .font(.system(size: size, weight: .medium, design: .monospaced))
            .foregroundStyle(color)
    }
}
