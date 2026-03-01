import SwiftUI

extension Color {
    /// Creates a Color from a hex string (e.g. "#FF5733" or "#AAFF5733").
    /// Supports 6-digit (#RRGGBB) and 8-digit (#AARRGGBB) formats.
    /// Falls back to gray for malformed input.
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0
        guard Scanner(string: cleaned).scanHexInt64(&rgb) else {
            self = .gray
            return
        }

        switch cleaned.count {
        case 6:
            let r = Double((rgb >> 16) & 0xFF) / 255.0
            let g = Double((rgb >> 8) & 0xFF) / 255.0
            let b = Double(rgb & 0xFF) / 255.0
            self.init(red: r, green: g, blue: b)
        case 8:
            let a = Double((rgb >> 24) & 0xFF) / 255.0
            let r = Double((rgb >> 16) & 0xFF) / 255.0
            let g = Double((rgb >> 8) & 0xFF) / 255.0
            let b = Double(rgb & 0xFF) / 255.0
            self.init(red: r, green: g, blue: b, opacity: a)
        default:
            self = .gray
        }
    }
}
