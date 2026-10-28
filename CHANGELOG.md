# Changelog

## 0.1.0 (unreleased)

The first release.

- Router and internet measured side by side, with a plain verdict: Good, Internet problem, Internet down, Local network problem or Offline
- Two internet hosts from different providers, plus IPv6 on dual-stack networks, with a TCP fallback for hosts that block ping
- Latency now, median and p95, jitter and loss per target, with a 60-second trace
- History: per-minute stats for 7 days, hourly for up to 90, minute states for sleep, lock and pauses, and CSV export of measurements and outages
- Wi‑Fi signal, noise and transmit rate next to the measurements
- Fixed-width menu bar with text, a trace or both; pause for an hour from the right-click menu
- Probes every 5 seconds on battery, in Low Power Mode and on Low Data or hotspot networks; stops while the screen is locked
- Optional notifications for outages and verdict changes
- Copy diagnostics for bug reports; no telemetry
