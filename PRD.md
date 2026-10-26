# straylight: Product Requirements

| | |
|---|---|
| **Status** | Draft v0.1: not started |
| **Owner** | Bill Anastas |
| **Last updated** | 2026-10-25 |
| **Repo** | [banastas/straylight](https://github.com/banastas/straylight) |
| **Site / updates** | https://straylight.banast.as |
| **Siblings** | [flatline](https://github.com/banastas/flatline) (CPU, memory, network), freeside (drives) |

---

## 1. Summary

straylight is a menu bar network quality monitor for Apple Silicon Macs running macOS 27 or later. flatline shows how much traffic is moving. straylight shows how good the connection is: **latency**, **jitter**, and **packet loss**, measured to your router and to the internet side by side. That split answers the question everyone asks when a call starts stuttering: is it the Wi‑Fi, or the internet?

The name comes from Villa Straylight, the Tessier-Ashpool home at the end of Freeside in *Neuromancer*. It also fits stray light in a fiber and stray packets. It follows flatline's rules: narrow scope, Apple Silicon only, no root, and close to zero cost when idle.

## 2. Background

Speed tests measure throughput once. Most "the internet is bad" problems are latency spikes, jitter and loss that come and go. A speed test misses them, and video calls and remote sessions feel them straight away. `ping` in Terminal shows them, but you have to remember to run it, it watches one target, and it keeps no history. macOS's `networkQuality` is a one-off test that saturates the link. Tools like PingPlotter are large and paid.

straylight is an always-on, two-target trace in the menu bar, with enough history to see what happened during the call you just had.

## 3. Goals

1. **"Wi‑Fi or internet?" at a glance.** Router and internet are measured together, and the verdict says which one is the problem.
2. **Catch problems that come and go.** Keep a history of outages and spikes, with times, that you can export and send to an ISP.
3. **No root.** Unprivileged ICMP sockets; no helper, no setuid.
4. **Light on the network and the battery.** A few small packets a second at most, fewer on battery, none while the screen is locked (by default).
5. **Steady menu bar, flatline look.** Fixed width, monospaced digits, monochrome, phosphor accent in the popover.
6. **Ships and updates itself.** Developer ID signed, notarized, Sparkle updates from straylight.banast.as.

## 4. Non-goals

- Throughput and speed tests (flatline shows traffic; `networkQuality` exists)
- Hop-by-hop traceroute or mtr views in 1.0 (see §13)
- Per-app network usage
- Wi‑Fi scanning, channel planning, or showing the network name (SSID needs Location permission)
- Monitoring remote servers or websites for uptime; straylight is about your own connection
- Intel Macs, macOS earlier than 27, root privileges, privileged helpers, kernel extensions, private frameworks
- Mac App Store distribution or the sandbox

## 5. Users

- **Remote workers** on video calls and people working on remote machines (SSH, screen sharing, remote editing).
- **Anyone arguing with their ISP** who needs evidence: "the line drops most evenings around 8, here's the log."
- **Developers and power users** who already run flatline and want the quality half of the network picture.

## 6. Functional requirements

### 6.1 Targets

| Target | Default | Tells you about |
|---|---|---|
| **Router** | The primary interface's default gateway, found automatically | Your Wi‑Fi or local network |
| **Internet** | `1.1.1.1` | The path through your ISP to the internet |
| Custom (optional, up to 2) | none | e.g. a company VPN endpoint or a game server |

- **Gateway discovery**: SCDynamicStore `State:/Network/Global/IPv4` → `PrimaryInterface`, `Router` (and `State:/Network/Global/IPv6`). Watched with `SCDynamicStoreSetNotificationKeys`, so it updates on network changes without polling. `NWPathMonitor` supplies the interface type (Wi‑Fi, Ethernet, hotspot) and `isExpensive` / `isConstrained`.
- **VPN**: when the primary interface is a `utun`, the router target uses the physical interface's router (`State:/Network/Interface/<en>/IPv4` → `Router`), and the popover labels the internet path "via VPN". If the VPN blocks local traffic, the router shows "unreachable (VPN)", not loss.
- Hostnames are resolved once per network change, not once per probe.
- A router that never answers ping in its first 10 probes is marked "doesn't answer ping" and its card is hidden, rather than shown as 100 % loss.

### 6.2 Probing

| Item | Spec |
|---|---|
| Method | ICMP echo over unprivileged datagram sockets: `socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)` and `socket(AF_INET6, SOCK_DGRAM, IPPROTO_ICMPV6)`. This is the approach in Apple's SimplePing sample and needs no root. |
| Matching replies | The kernel may rewrite the ICMP identifier on datagram sockets, so replies are matched on sequence number plus a random 8-byte token in the payload |
| Timing | Send time from `mach_continuous_time()` just before `sendto`; receive time from the kernel via `SO_TIMESTAMP_MONOTONIC`, so a slow wake-up in the app doesn't inflate the RTT |
| Payload | 56 bytes, like `ping` |
| Rate | 1 probe per second per target on power; 1 per 5 s on battery (both configurable) |
| Timeout | No reply within 2 s counts as lost. A reply after the timeout is logged as late, not counted as received. |
| Fallback | If the internet target answers no ICMP for 10 probes while the router does, switch that target to TCP connect timing on port 443 (non-blocking `connect`, time to SYN-ACK, close immediately) and label it "TCP" |
| Network changes | Probes in flight when the path changes (Wi‑Fi ↔ Ethernet, VPN up/down, sleep/wake) are discarded, not counted as lost. Probing restarts after targets are re-resolved. |
| Pauses | No probes while the screen is locked or the display is asleep, unless "Keep monitoring while locked" is on (for overnight logging). With no network path, probing stops and the verdict is Offline. |

### 6.3 Metrics and verdict

Per target, from a ring buffer of recent probes:

| Value | Definition |
|---|---|
| RTT now | The latest reply |
| RTT median / p95 | Over the last 60 probes |
| Baseline | Minimum RTT since the last network change |
| Jitter | Mean absolute difference between consecutive RTTs over the last 60 probes (RFC 3550 style, unsmoothed), in ms |
| Loss | Lost ÷ sent over the last 60 probes, in % |

**Verdict**, shown in the popover header and summarized in the menu bar:

| Router | Internet | Verdict |
|---|---|---|
| OK | OK | **Good** |
| OK | Bad | **Internet problem**: the router is fine; the trouble is at the ISP or beyond |
| Bad | any | **Local network problem**: Wi‑Fi or the router |
| no path | no path | **Offline** |

Starting thresholds for "Bad" (to be tuned on real hardware in M3, since Wi‑Fi power saving makes router RTTs noisy):

| | Loss | Jitter | p95 RTT |
|---|---|---|---|
| Router | ≥ 2 % | > 10 ms | > 30 ms |
| Internet | ≥ 2 % | > 30 ms | > 150 ms |

A verdict has to hold for 10 s before it changes, so it doesn't flap.

**Events**:

- **Outage**: 3 or more consecutive lost probes to a target. Logged with start time, duration and target.
- **Spike**: RTT above 3 × the median for 3 or more consecutive probes. Logged with start time, duration and worst RTT.

### 6.4 History

- **Per-minute aggregates** per target (median RTT, p95, jitter, loss, and Wi‑Fi RSSI when on Wi‑Fi) for the last 24 hours. That's 1,440 rows per target, so it's small.
- **Event log** (outages and spikes) for the last 30 days.
- Both are stored in `~/Library/Application Support/straylight/`, written at most once a minute, so history survives restarts.
- **Export CSV** from the popover: aggregates and events for a chosen time range, for sending to an ISP.

### 6.5 Wi‑Fi context

When the primary interface is Wi‑Fi, CoreWLAN (`CWWiFiClient.shared().interface()`) supplies RSSI, noise, transmit rate and channel (band and width). The network name (SSID) and BSSID are not shown, because they need Location permission.

**Permissions check (M1):** confirm that RSSI, noise, rate and channel are available on macOS 27 without Location authorization. If they aren't, drop this section rather than ask for Location.

### 6.6 Menu bar

- A single `NSStatusItem`, monochrome in the menu bar's label color, fixed width.
- **Display styles**:
  - `text`: label stacked above value (`RTT` / `23ms`)
  - `trace`: an RTT trace of recent history. A lost probe drops the line to the baseline, so a dead connection literally flatlines.
  - `text+trace`
- **Target shown**: Internet (default), Router, or both as two short stacked traces.
- The verdict is shown as a mark, not a color: nothing when Good, `!` for a problem, `×` for Offline.
- Click opens the popover. Right-click or Control-click opens a small menu: Open, Pause for 1 hour, Settings, Check for Updates, Quit.
- VoiceOver reads a summary such as "Good. Internet 23 milliseconds, jitter 4, loss 0 percent. Router 3 milliseconds."

### 6.7 Popover

A single scrolling panel about 340 pt wide, built with SwiftUI.

1. **Header**: the verdict in words (e.g. "Internet problem: router is fine, 8 % loss to 1.1.1.1"), interface type, local IP, router IP, "via VPN" when relevant.
2. **Target cards** (Router, Internet, any custom targets): large RTT now; median, p95, baseline, jitter, loss; a 60-second trace with lost probes marked.
3. **History**: 1 h or 24 h chart of per-minute median and p95, with loss as bars under the baseline and RSSI as a faint line when on Wi‑Fi, so "loss went up when the signal dropped" is visible.
4. **Wi‑Fi card**: RSSI, noise, signal-to-noise, transmit rate, band and channel width.
5. **Events**: the last 10 outages and spikes, plus **Export CSV**.
6. **Footer**: settings gear, update indicator, Quit.

Traces and charts are drawn with SwiftUI `Canvas`, as in flatline. Popover views exist only while the popover is open.

### 6.8 Notifications (opt-in)

- **Outage**: when an outage to the internet target lasts 10 s, and again when it ends, with its duration.
- **Verdict changes** that hold for at least 30 s.

Both are off by default.

### 6.9 Settings

Shown in the popover (an inline settings panel, as in flatline), stored in `UserDefaults`:

| Setting | Options | Default |
|---|---|---|
| Probe interval on power | 0.5 s, 1 s, 2 s, 5 s | 1 s |
| Probe interval on battery | 1 s, 2 s, 5 s, 10 s | 5 s |
| Internet target | 1.1.1.1, 8.8.8.8, 9.9.9.9, custom host | 1.1.1.1 |
| Custom targets | up to 2 hosts | none |
| Menu bar target | Internet, Router, both | Internet |
| Display style | text, trace, text+trace | text+trace |
| Keep monitoring while locked | on / off | off |
| Event log retention | 7, 30, 90 days | 30 days |
| Notifications | Outages, Verdict changes | off |
| Accent color | phosphor green, cyan, magenta, amber, system | phosphor green |
| Launch at login | on / off (`SMAppService.mainApp`) | off, with a prompt on first run |
| Automatic updates | check automatically / download automatically | check automatically, daily |

### 6.10 Updates and website

Same setup as flatline:

- **Sparkle 2** via Swift Package Manager. Appcast at `https://straylight.banast.as/appcast.xml`, EdDSA-signed updates, notarized DMGs under `/releases/`, appcast generated by the release script with notes from `CHANGELOG.md`.
- A small static site in `site/`: landing page, screenshot, download button, requirements, release notes. The landing page and README say plainly that straylight sends small ping packets to the targets you choose (1.1.1.1 by default).

## 7. Technical design

### 7.1 Stack

- **Swift 6.4**, strict concurrency, Swift 6 language mode
- **SwiftUI** for all views; **AppKit** only for `NSStatusItem` / `NSPopover`
- **Observation** (`@Observable`) for the model
- **BSD sockets** for probing, **SystemConfiguration** and **Network** (`NWPathMonitor`) for paths, **CoreWLAN** for Wi‑Fi details
- Deployment target **macOS 27.0**, **arm64 only**
- No third-party dependencies other than **Sparkle**

### 7.2 Project layout

```
straylight/
├── project.yml              # XcodeGen spec → Straylight.xcodeproj (generated, git-ignored)
├── Packages/
│   └── StraylightKit/       # Unit-tested with `swift test`
│       ├── Sources/StraylightKit/
│       │   ├── ICMPProber.swift      # datagram sockets, send, receive, matching, timeouts
│       │   ├── TCPProber.swift       # port-443 connect-time fallback
│       │   ├── Targets.swift         # gateway discovery, VPN handling, path changes
│       │   ├── Stats.swift           # median, p95, jitter, loss, verdict, events
│       │   ├── History.swift         # per-minute aggregates, event log, CSV export
│       │   ├── WiFi.swift            # CoreWLAN details
│       │   ├── RingBuffer.swift      # from flatline (see §13)
│       │   └── Format.swift          # from flatline
│       └── Tests/StraylightKitTests/
├── App/
│   ├── StraylightApp.swift
│   ├── StatusItemController.swift
│   ├── MenuBarRenderer.swift
│   ├── Popover/…
│   ├── Settings/…
│   └── Resources/
├── scripts/                 # release.sh, bump-version.sh (adapted from flatline)
├── site/                    # straylight.banast.as
├── CHANGELOG.md
├── PRD.md
└── README.md
```

Tests cover the stats math against fixed RTT sequences, reply matching when the kernel rewrites identifiers, discarding probes across a simulated path change, and a real probe to `127.0.0.1`.

### 7.3 Probe loop

- One send timer with 10 % leeway sends to every target in the same wake-up.
- Replies arrive through a `DispatchSourceRead` on each socket (one IPv4, one IPv6), so nothing polls for replies.
- Timeouts are checked on the next send tick, not with a separate timer.
- All socket work runs on one serial queue. The `@Observable` snapshot on the main actor is updated at most once per tick.
- History is appended in memory and flushed to disk once a minute.

**Battery:** Wi‑Fi radios save power by sleeping between beacons, and a probe every second keeps waking them. That's why the battery default is 5 s and probing stops while the screen is locked. Energy impact on battery is measured in M7 against flatline.

### 7.4 Menu bar rendering

Same approach as flatline (its PRD §7.4): draw into one image per tick, put it in a `CALayer` inside the status button rather than `button.image`, use the menu bar's label color, and skip the redraw when nothing visible changed.

### 7.5 Security and distribution

- Hardened runtime on. Not sandboxed, for the same Sparkle reasons as flatline.
- Signed with **Developer ID Application (team `F87BNUZAVJ`)**, notarized with `notarytool`, ticket stapled.
- Bundle ID `as.banast.straylight`. `LSUIElement = YES` (no Dock icon).
- Network traffic is limited to probes to the configured targets and Sparkle checking the appcast. No telemetry or analytics. History stays on the Mac unless the user exports it.

## 8. Performance budgets

Measured on an M-series Mac, two targets, popover closed:

| Metric | Budget |
|---|---|
| Average CPU at a 1 s interval | < 0.1 % of one core |
| Resident memory | < 30 MB |
| Wake-ups | ≤ 1 timer wake-up plus one read event per target, per interval |
| Network | < 1 kbit/s each way per target at a 1 s interval |
| Energy Impact (Activity Monitor), on power | ≈ flatline's |
| History on disk | < 5 MB at 90 days of events |
| Popover open → first frame | < 50 ms |

Checked before each release with Instruments and with a tick profiler: run the binary with `STRAYLIGHT_PROFILE=1`, as with flatline.

## 9. Accuracy acceptance criteria

| Metric | Reference | Tolerance |
|---|---|---|
| Median RTT | `ping -c 60` to the same target at the same time | ± 0.5 ms or ± 5 %, whichever is larger |
| Loss | `ping -c 300` under Network Link Conditioner's 5 % loss profile | ± 2 points |
| Jitter | The §6.3 formula applied to `ping`'s per-reply times | ± 1 ms |
| Router | `route -n get default` | Exact |
| Network change | Switching Wi‑Fi ↔ Ethernet, joining a VPN, sleep/wake | Targets re-resolved and verdict updated within 3 s; no false outage logged |

## 10. Accessibility and localization

- VoiceOver labels on the status item and on every popover value; lost probes in traces are described in text ("3 lost in the last minute")
- The popover respects Reduce Motion (traces stop animating) and Increase Contrast
- Color is never the only signal: the verdict is always in words, and the menu bar uses marks
- English only for 1.0, with all strings in a String Catalog

## 11. Milestones

| # | Milestone | Done when |
|---|---|---|
| M0 | Scaffold | XcodeGen project builds an empty menu bar app; `swift test` runs |
| M1 | Prober | ICMP over IPv4 and IPv6, reply matching, timeouts, TCP fallback; RTT matches §9; Wi‑Fi permissions check done |
| M2 | Targets + paths | Gateway discovery, VPN handling, path changes with no false loss |
| M3 | Stats + verdict | Metrics, verdict, events; thresholds tuned on real Wi‑Fi and Ethernet |
| M4 | Menu bar | All styles, both-targets view, verdict marks, fixed width |
| M5 | Popover | Target cards, Wi‑Fi card, verdict header |
| M6 | History | Per-minute aggregates, event log, persistence, CSV export, notifications |
| M7 | Settings + battery | All §6.9 settings persist; battery interval and lock pause work; energy measured |
| M8 | Distribution | `scripts/release.sh` produces a signed, notarized, stapled DMG |
| M9 | Updates + site | Sparkle wired up; site deployed with appcast; an update tested end to end |
| M10 | 1.0 | §8 budgets and §9 criteria verified; README screenshots; tagged release |

## 12. Decisions

| Question | Decision (2026-10-25) |
|---|---|
| Name | **straylight** |
| Signing | Same Developer ID team as flatline (`F87BNUZAVJ`), notarized with `notarytool` |
| Hosting | **Cloudflare Pages** at straylight.banast.as, same as flatline |
| License | **MIT** |
| Menu bar colors | **Monochrome**, for the same reason as flatline |

## 13. Open questions

1. **Shared code with flatline and freeside**: copy `RingBuffer`, `Format`, the menu bar renderer and the release scripts, or extract a shared Swift package (working name `sprawl`)? Same question as in freeside's PRD; decide once for all three.
2. **Default internet target**: one target (1.1.1.1), or two from different providers (1.1.1.1 and 8.8.8.8) so one provider's bad day doesn't look like your ISP's? Two doubles the traffic.
3. **Hop-by-hop view**: an mtr-style view would show where along the path loss starts. It needs TTL-limited probes, and it's not yet confirmed that unprivileged ICMP datagram sockets receive Time Exceeded replies. Worth a spike after 1.0.
4. **DNS timing**: is resolver latency worth tracking? Caching makes it hard to measure honestly.
5. **On-demand capacity test**: a button that runs macOS's `networkQuality` and shows the result? It saturates the link for about 20 s, so on demand only.
6. **Flatline integration**: should flatline's network card show straylight's verdict when both are running, or should the apps stay fully separate?
7. **Repo visibility**: private until 1.0, or public from the start?
