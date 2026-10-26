# straylight

A small menu bar app for Apple Silicon Macs that shows how good your connection is: **latency**, **jitter**, and **packet loss**, to your router and to the internet, side by side.

> Is it the Wi‑Fi, or the internet? straylight answers that at a glance.

straylight is a sibling to [flatline](https://github.com/banastas/flatline). flatline shows how much traffic is moving; straylight shows its quality. It follows the same rules: one narrow job, Apple Silicon and macOS 27 only, no root helper, and close to zero cost when idle.

**Status:** planning. Nothing is built yet. See the [PRD](PRD.md).

## Features (planned for 1.0)

- **Router and internet measured together**, with a plain verdict: Good, Internet problem, Local network problem, or Offline
- **Latency** (now, median, p95), **jitter**, and **loss** per target, with a 60-second trace. A lost ping drops the trace flat.
- **History**: per-minute stats for the last 24 hours and a 30-day log of outages and spikes, with **CSV export** to send to your ISP
- **Wi‑Fi context**: signal strength, noise and transmit rate, so you can see when loss follows a weak signal
- Optional custom targets, such as a VPN endpoint or a game server
- Optional notifications for outages
- Fixed-width, monochrome menu bar; terminal-style popover with a phosphor accent
- Launch at login, automatic updates via [Sparkle](https://sparkle-project.org)
- No telemetry, no root helper, no kernel extensions

## Network traffic

straylight sends small ping packets (56 bytes) to the targets you choose: your router and `1.1.1.1` by default. That's one per target per second on power and one every 5 seconds on battery. It stops while the screen is locked unless you turn on overnight monitoring. If a network blocks ping, it times a normal HTTPS connection instead. History stays on your Mac unless you export it.

## Requirements

- macOS 27 or later
- Apple Silicon (M1 or newer)

## Install

Not released yet. When it is, downloads will be at **[straylight.banast.as](https://straylight.banast.as)**.

## License

MIT. The license file will be added with the first code.
