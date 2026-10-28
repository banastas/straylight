/// What the menu bar shows, kept apart from drawing so it can be tested (PRD §6.6).
public enum MenuBarText {
    /// The widest value, which sets the status item's fixed width.
    public static let widestRTT = "999ms"

    /// `5.4ms`, `23ms`, `999ms`, `1.2s`, `—` without a value. Never wider than `999ms`.
    public static func rtt(_ milliseconds: Double?) -> String {
        guard let milliseconds, milliseconds.isFinite, milliseconds >= 0 else { return "—" }
        if milliseconds < 9.95 { return String(format: "%.1fms", milliseconds) }
        if milliseconds < 999.5 { return "\(Int(milliseconds.rounded()))ms" }
        let seconds = milliseconds / 1000
        return seconds < 9.95 ? String(format: "%.1fs", seconds) : "\(Int(seconds.rounded()))s"
    }

    /// The verdict mark: nothing when Good or measuring, `!` for a problem,
    /// `×` for down or Offline, `‖` while paused.
    public static func mark(for verdict: Verdict, paused: Bool) -> String {
        if paused { return "‖" }
        switch verdict {
        case .good, .measuring: return ""
        case .internetProblem, .localProblem, .connectionProblem, .internetUnmeasured: return "!"
        case .internetDown, .localDown, .connectionDown, .offline: return "×"
        }
    }

    /// Trace heights in 0...1, oldest first. A lost probe (nil) sits on the
    /// baseline, so a dead connection flatlines. Replies scale to the highest
    /// RTT shown, but never below `floor` ms, so small jitter stays small.
    /// Heights are rounded to 1/32 so sub-pixel changes don't force a redraw.
    public static func trace(_ rtts: [Double?], floor: Double) -> [Double] {
        let peak = max(floor, rtts.compactMap { $0 }.max() ?? 0)
        return rtts.map { rtt in
            guard let rtt else { return 0 }
            return (min(1, rtt / peak) * 32).rounded() / 32
        }
    }
}
