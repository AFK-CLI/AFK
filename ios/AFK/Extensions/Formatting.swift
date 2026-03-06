import Foundation

extension Double {
    /// Formats a USD cost value: "$0.0042" for < $0.01, "$0.17" otherwise.
    var formattedCost: String {
        if self < 0.01 {
            return String(format: "$%.4f", self)
        }
        return String(format: "$%.2f", self)
    }
}

extension Int64 {
    /// Formats a token count: "1.5M", "25.3K", or raw number.
    var formattedTokens: String {
        if self >= 1_000_000 {
            return String(format: "%.1fM", Double(self) / 1_000_000.0)
        }
        if self >= 1_000 {
            return String(format: "%.1fK", Double(self) / 1_000.0)
        }
        return "\(self)"
    }
}
