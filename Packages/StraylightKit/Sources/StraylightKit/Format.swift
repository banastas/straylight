// Copied from flatline's FlatlineKit (PRD §13), keeping only what straylight
// uses. Byte and rate formatting stayed behind.

import Foundation

public enum Format {
    /// `0.234` → `"23%"`
    public static func percent(_ fraction: Double) -> String {
        "\(Int((max(0, min(1, fraction)) * 100).rounded()))%"
    }

    /// `"3d 4h"`, `"4h 12m"`, `"12m"`
    public static func duration(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let (days, hours, mins) = (minutes / 1440, (minutes / 60) % 24, minutes % 60)
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(mins)m" }
        return "\(mins)m"
    }
}

extension String {
    /// Right-aligns the string in a field of `width` characters.
    public func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
