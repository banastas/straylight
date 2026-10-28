# straylight

A small menu bar app for Apple Silicon Macs that shows how good your connection is: **latency**, **jitter**, and **packet loss**, to your router and to the internet, side by side.

> Is it the Wi‑Fi, or the internet? straylight answers that at a glance.

straylight is a sibling to [flatline](https://github.com/banastas/flatline). flatline shows how much traffic is moving; straylight shows its quality. It follows the same rules: one narrow job, Apple Silicon and macOS 27 only, no root helper, and close to zero cost when idle.

**Status:** in development. The measuring, history and menu bar work; the popover and settings come next. See the [PRD](PRD.md).

## Features (planned for 1.0)

- **Router and internet measured together**, with a plain verdict: Good, Internet problem, Internet down, Local network problem, or Offline
- **Two internet hosts from different providers**, so one provider's bad day doesn't look like your ISP's
- **Latency** (now, median, p95), **jitter**, and **loss** per target, with a 60-second trace. A lost ping drops the trace flat.
- **History**: per-minute stats for 7 days, hourly stats and a log of outages and spikes for 30 days (up to 90), with **CSV export** to send to your ISP
- **Wi‑Fi context**: signal strength, noise and transmit rate, so you can see when loss follows a weak signal
- Optional custom targets, such as a VPN endpoint or a game server
- Optional notifications for outages
- Fixed-width, monochrome menu bar; terminal-style popover with a phosphor accent
- Launch at login, automatic updates via [Sparkle](https://sparkle-project.org)
- No telemetry, no root helper, no kernel extensions

## Network traffic

straylight sends small ping packets (56 bytes) to the targets you choose: your router, `1.1.1.1` and `8.8.8.8` by default, plus `1.1.1.1` over IPv6 on networks that have it. That's one per target per second on power and one every 5 seconds on battery, briefly once a second after a network change or a lost ping. It stops while the screen is locked unless you turn on overnight monitoring. If a network blocks ping, it times a normal HTTPS connection instead. History stays on your Mac unless you export it.

## Requirements

- macOS 27 or later
- Apple Silicon (M1 or newer)

## Install

Not released yet. When it is, downloads will be at **[straylight.banast.as](https://straylight.banast.as)**.

## Building from source

Requires Xcode 27+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
xcodegen generate
open Straylight.xcodeproj
```

Unit tests run without Xcode:

```bash
swift test --package-path Packages/StraylightKit
```

`straylight-probe` is a development tool for checking the probes against `ping`; it isn't part of the app:

```bash
swift run --package-path Packages/StraylightKit -c release straylight-probe -c 60 1.1.1.1
```

`--monitor 120` runs the whole measuring pipeline for two minutes and prints the verdict and each target's stats after every round. Add `--history file.sqlite` to record history there, and `--export file.sqlite 30` prints the CSV for the last 30 minutes. Its source lists the other options.

Debug builds are ad-hoc signed and run on any Mac. Release builds are signed with the maintainer's Developer ID.

## License

MIT. The license file will be added with the first code.
