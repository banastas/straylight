import Darwin

/// The clock both RTT timestamps use. `SO_TIMESTAMP_MONOTONIC` stamps packets
/// with `mach_absolute_time()` (xnu `ip_savecontrol` and `ip6_savecontrol`),
/// which pauses during sleep, so sends are stamped from the same clock.
/// `mach_continuous_time()` would add the total sleep since boot to every RTT.
public enum MachClock {
    public static func now() -> UInt64 {
        mach_absolute_time()
    }

    private static let timebase: (numer: Double, denom: Double) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (Double(info.numer), Double(info.denom))
    }()

    /// Milliseconds from `start` to `end`; zero if `end` is earlier.
    public static func milliseconds(from start: UInt64, to end: UInt64) -> Double {
        guard end > start else { return 0 }
        return Double(end - start) * timebase.numer / timebase.denom / 1_000_000
    }

    public static func ticks(seconds: Double) -> UInt64 {
        UInt64(seconds * 1_000_000_000 * timebase.denom / timebase.numer)
    }

    /// Time the Mac has spent asleep since boot, in ticks. It grows only across
    /// a sleep, which is how a wake is noticed without AppKit.
    public static func sleepSinceBoot() -> UInt64 {
        // Absolute first: read the other way round, the two can come out a few
        // ticks apart in the wrong direction when the Mac has never slept.
        let absolute = mach_absolute_time()
        let continuous = mach_continuous_time()
        return continuous > absolute ? continuous - absolute : 0
    }
}
