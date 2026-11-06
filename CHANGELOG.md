# Changelog

## 1.0.2 (2026-11-05)

- A new app icon, in the look it now shares with the other banast.as apps

## 1.0.1 (2026-11-04)

- A "sound" setting under Notifications turns off the sound of the outage alert

## 1.0.0 (2026-11-04)

The first stable release, checked on real hardware against ping, blocked ICMP, packet loss, sleep and a simulated outage.

- After waking from sleep, straylight no longer shows "Local network problem" for about a minute: probes lost before the network came back up no longer count

## 0.1.1 (2026-10-28)

- The menu bar item is 10 points narrower: with a trace, the verdict mark sits beside the latency instead of in its own column
- The popover reopens in about 25 ms instead of 75: it's kept for a minute after closing
- The popover opens at its full height instead of growing on its first frame

## 0.1.0 (2026-10-28)

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
