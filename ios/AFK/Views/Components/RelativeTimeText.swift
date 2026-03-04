import SwiftUI

/// Shared clock that ticks every 60 seconds, driving all relative time labels.
/// Using a single timer instead of per-view `Text(date, style: .relative)` timers
/// reduces idle CPU from ~2% to near zero.
@Observable
final class RelativeTimeClock {
    static let shared = RelativeTimeClock()

    private(set) var tick: UInt64 = 0
    @ObservationIgnored private var timer: Timer?

    @ObservationIgnored
    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private init() {
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.tick &+= 1
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    static func format(_ date: Date) -> String {
        formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// Displays a relative timestamp (e.g. "5 min. ago") that updates every 60 seconds
/// via a single shared timer, replacing per-view `Text(date, style: .relative)`.
struct RelativeTimeText: View {
    let date: Date

    var body: some View {
        let _ = RelativeTimeClock.shared.tick
        Text(RelativeTimeClock.format(date))
    }
}
