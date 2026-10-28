# straylight: Product Requirements

| | |
|---|---|
| **Status** | Draft v0.2: not started |
| **Owner** | Bill Anastas |
| **Last updated** | 2026-10-26 |
| **Repo** | [banastas/straylight](https://github.com/banastas/straylight) |
| **Site / updates** | https://straylight.banast.as |
| **Siblings** | [flatline](https://github.com/banastas/flatline) (CPU, memory, network), freeside (drives) |

---

## 1. Summary

straylight is a menu bar network quality monitor for Apple Silicon Macs running macOS 27 or later. flatline shows how much traffic is moving. straylight shows how good the connection is: **latency**, **jitter**, and **packet loss**, measured to your router and to the internet side by side. That split answers the question everyone asks when a call starts stuttering: is it the Wi‑Fi, or the internet?

The name comes from Villa Straylight, the Tessier-Ashpool home at the end of Freeside in *Neuromancer*. It also fits stray light in a fiber and stray packets. It follows flatline's rules: narrow scope, Apple Silicon only, no root, and close to zero cost when idle.

## 2. Background

Speed tests measure throughput once. Most "the internet is bad" problems are latency spikes, jitter and loss that come and go. A speed test misses them, and video calls and remote sessions feel them straight away. `ping` in Terminal shows them, but you have to remember to run it, it watches one target, and it keeps no history. macOS's `networkQuality` is a one-off test that saturates the link. Tools like PingPlotter are large and paid.

straylight is an always-on trace to the router and the internet in the menu bar, with enough history to see what happened during the call you just had, or every evening this week.

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
| **Internet** | Two hosts from different providers: `1.1.1.1` (primary) and `8.8.8.8` (secondary) | The path through your ISP to the internet |
| Custom (optional, up to 2) | none | e.g. a company VPN endpoint or a game server |

- **Gateway discovery**: SCDynamicStore `State:/Network/Global/IPv4` → `PrimaryInterface`, `Router` (and `State:/Network/Global/IPv6`). Watched with `SCDynamicStoreSetNotificationKeys`, so it updates on network changes without polling. `NWPathMonitor` supplies the interface type (Wi‑Fi, Ethernet, hotspot) and `isExpensive` / `isConstrained`.
- **Two internet hosts**: the internet counts as OK when either host is OK, so one provider's bad day doesn't look like your ISP's. When one host is Bad and the other is OK, the internet card says so ("1.1.1.1 slow, 8.8.8.8 fine: likely Cloudflare, not your ISP"). The menu bar shows the primary host. The secondary host can be turned off in Settings.
- **IPv4 and IPv6**: the router and the internet hosts are probed over IPv4 when the network has IPv4. On a dual-stack network, the primary internet host is also probed over IPv6 (`2606:4700:4700::1111` for 1.1.1.1, `2001:4860:4860::8888` for 8.8.8.8), shown as its own row in the internet card. The verdict uses IPv4; when IPv6 is Bad or Down and IPv4 is OK, the header adds "IPv6 problem". On an IPv6-only network, every target is probed over IPv6 and the router is the link-local `Router` from `State:/Network/Global/IPv6`, probed with the primary interface's scope ID.
- **VPN**: when the primary interface is a `utun`, the router target uses the physical interface's router (`State:/Network/Interface/<en>/IPv4` → `Router`), and the popover labels the internet path "via VPN". If the VPN blocks local traffic, the router shows "unreachable (VPN)", not loss.
- Hostnames are resolved once per network change, not once per probe.
- **Warm-up**: for the first 10 s after a network change, every target is probed once a second, whatever the power source, so baselines and the checks below settle quickly.
- A router that answers no ping during warm-up is marked "doesn't answer ping" and its card is hidden, rather than shown as 100 % loss.
- **Answered locally**: if an internet host's median RTT is at or below the router's baseline, something on the local network is answering for it (some captive portals and older routers intercept 1.1.1.1). That host is marked "answered locally" and left out of the verdict.

### 6.2 Probing

| Item | Spec |
|---|---|
| Method | ICMP echo over unprivileged datagram sockets: `socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)` and `socket(AF_INET6, SOCK_DGRAM, IPPROTO_ICMPV6)`. This is the approach in Apple's SimplePing sample and needs no root. In xnu these are raw sockets with the privilege check removed: the app computes the IPv4 checksum (the kernel computes ICMPv6's), `IP_STRIPHDR` drops the IPv4 header on receive, and `ICMP6_FILTER` limits the IPv6 socket to echo replies. |
| Matching replies | The IPv4 socket sees every ICMP packet for the Mac, including replies to other apps' pings. Replies are matched on sequence number, a random 8-byte token in the payload, and source address. xnu doesn't rewrite the identifier, but matching doesn't rely on it. |
| Timing | Send time from `mach_absolute_time()` just before `sendto`; receive time from the kernel via `SO_TIMESTAMP_MONOTONIC`, so a slow wake-up in the app doesn't inflate the RTT. Both use the same clock: xnu stamps `SO_TIMESTAMP_MONOTONIC` with `mach_absolute_time()` (`ip_savecontrol`, `ip6_savecontrol`), which pauses during sleep. Pairing it with `mach_continuous_time()` would have added the total sleep since boot to every RTT. |
| Payload | 56 bytes, like `ping` |
| Rate | 1 probe per second per target on power; 1 per 5 s on battery (both configurable). The battery rate also applies in Low Power Mode and when the path is constrained (Low Data Mode) or expensive (e.g. an iPhone hotspot). Warm-up (§6.1) and fast recheck (below) temporarily probe at 1 s. |
| Fast recheck | When a probe is lost and the interval is longer than 1 s, that target is probed every second until 3 replies in a row arrive, then returns to its normal rate. Outages are caught at the same speed on battery as on power. |
| Timeout | No reply within 2 s counts as lost. A reply after the timeout is logged as late, not counted as received. |
| Fallback | During warm-up, if an internet host answers no ICMP while the router does, straylight tries a TCP connect to that host on port 443 (non-blocking `connect`, time to SYN-ACK, close immediately). Only if TCP succeeds does that host switch to TCP connect timing, labeled "TCP". ICMP failing on its own never triggers the switch: with TCP failing too, it's an outage. In TCP mode, one ICMP probe is still sent per minute; after 3 ICMP replies in a row, the host switches back. |
| Network changes | Probes in flight when the path changes (Wi‑Fi ↔ Ethernet, VPN up/down, sleep/wake) are discarded, not counted as lost. Probing restarts with warm-up after targets are re-resolved. A wake is noticed without AppKit: the gap between `mach_continuous_time()` and `mach_absolute_time()` grows only across a sleep. |
| Pauses | No probes while the screen is locked or the display is asleep, unless "Keep monitoring while locked" is on (for overnight logging). No probes while paused from the menu (§6.6). With no network path, probing stops and the verdict is Offline. |

### 6.3 Metrics and verdict

Per target, from a ring buffer of recent probes. The **window** is the last 60 s or the last 20 probes, whichever is longer: 60 probes at 1 s, 20 probes (100 s) at 5 s. On battery the window is longer, so the verdict reacts more slowly to gradual degradation; fast recheck keeps outage detection quick.

| Value | Definition |
|---|---|
| RTT now | The latest reply |
| RTT median / p95 | Over the window, nearest-rank. Over 60 samples, p95 is the 57th (the 4th-highest); over 20, the 19th (the 2nd-highest). |
| Baseline | Minimum RTT since the last network change |
| Jitter | Mean of \|RTTᵢ − RTTᵢ₋₁\| over consecutive replies in the window, in ms (mean IPDV, unsmoothed; RFC 3550's smoothed jitter isn't used). A pair is skipped when a lost probe falls between the two replies. |
| Loss | Lost ÷ sent over the window, in %. Lost and sent counts are also kept. |

Each target is **OK**, **Bad** (any threshold below crossed), or **Down** (an outage in progress, see Events). The internet state combines its two hosts: OK if either is OK, Down if both are Down, Bad otherwise. Hosts marked "answered locally" don't count. A target's statistics start over whenever the protocol it's measured with changes (a switch to or from TCP, or a silent router that starts answering), so the ICMP losses from the warm-up of a host that ends up in TCP mode don't linger. A host that stays on ICMP keeps its warm-up samples. Every target is Measuring during warm-up and until its first probe finishes after a fresh start.

**Verdict**, shown in the popover header and summarized in the menu bar:

| Router | Internet | Verdict |
|---|---|---|
| OK | OK | **Good** |
| Bad or Down | OK | **Good**. The router card notes "slow to answer ping; traffic through it is fine". Many routers deprioritize ping to themselves, so router-only trouble isn't a local problem. |
| OK | Bad | **Internet problem**: the router is fine; the trouble is at the ISP or beyond |
| OK | Down | **Internet down**: the router is fine, but nothing gets past it |
| Bad | Bad or Down | **Local network problem**: Wi‑Fi or the router |
| Down | Down | **Local network down**: can't reach the router |
| doesn't answer ping, or unreachable (VPN) | OK / Bad / Down | **Good** / **Connection problem** / **Connection down**. The header says the router can't be measured, so local and internet can't be told apart. |
| any | no internet host counts (every one answered locally, or none resolved) | **Can't measure the internet** |
| no path | no path | **Offline** |

Custom targets have their own cards, events and history, and never affect the verdict.

Starting thresholds for "Bad" (to be tuned in M7 against a week of real Wi‑Fi and Ethernet history, since Wi‑Fi power saving makes router RTTs noisy). Loss is a count so it means the same thing at every probe rate:

| | Loss | Jitter | p95 RTT |
|---|---|---|---|
| Router | ≥ 2 lost in the window | > 10 ms | > 30 ms |
| Internet host | ≥ 2 lost in the window | > 30 ms | > 150 ms |

A verdict has to hold for 10 s before it changes, so it doesn't flap. The exceptions: the first verdict after a network change and Offline show at once, and a target briefly measuring again (a host switching to TCP) keeps the verdict that's shown.

**Events**:

- **Outage**: no reply from a target for at least 5 s, with at least 3 consecutive probes lost. Logged with start time, duration and target. The target is Down while the outage lasts. The start is when the first lost probe was sent and the end is when the first probe to get a reply was sent. Losses during warm-up count, but an outage is only declared once warm-up is over, so a host that switches to TCP never logs one. A network change ends an outage in progress at the time of the change.
- **Spike**: RTT above both 3 × the window median and the median + 20 ms, for 3 or more consecutive replies. The median excludes the spike's own samples and needs at least 5 replies outside them. A rise that fills the window ends the spike: it's the new normal. Lost probes neither extend nor end a spike. Logged with start time, duration and worst RTT; the spike ends when the first normal reply's probe was sent.

### 6.4 History

- **Per-minute aggregates** per target for the last 7 days, then **hourly rollups** for the rest of the history retention period (30 days by default; 7, 30 or 90 in Settings). Each row has sent, lost and late counts, median RTT, p95, jitter, and Wi‑Fi RSSI when on Wi‑Fi (the median of the samples in that minute or hour). Probes count in the minute they were sent in, so a late reply lands in the right minute. An hour's median is the median of its minutes' medians, its p95 the p95 of their p95s, and its jitter their mean weighted by replies; these are approximations, since the per-probe RTTs aren't kept.
- A host that switches to TCP during warm-up doesn't record its warm-up ICMP losses, the same rule as the stats (§6.3).
- **Every minute has a state**: measured, paused, locked, asleep, offline, or not running (the app wasn't open). Gaps are never shown or exported as outages, and ISP evidence isn't missing without explanation. A minute with any measurement is measured; otherwise it takes the last state set during it. Sleep is noticed from the clock gap (§6.2) and marks the minutes it covered. Not running is never stored: it's any minute with no row. An hour is measured if any of its minutes was, and otherwise takes the most common state.
- **Event log** (outages and spikes) for the history retention period.
- Stored in an SQLite database (the system `libsqlite3`) at `~/Library/Application Support/straylight/history.sqlite`, written at most once a minute, so history survives restarts. A minute is written 40 s after it ends, once no late reply can still land in it (2 s timeout plus the 30 s late window); everything, including the minute in progress, is written on quit. A minute written twice (a restart within it) adds up its counts. Rollups and pruning run once an hour.
- **Export CSV** from the popover: aggregates or events for a chosen time range, for sending to an ISP. Timestamps are ISO 8601 with the local UTC offset.
  - Aggregates: `start, period_s, state, target, address, protocol, sent, lost, late, loss_pct, median_ms, p95_ms, jitter_ms, rssi_dbm`. `period_s` is 60, or 3600 for hourly rows. Every minute (or hour, beyond the 7 days of detail) in the range has at least one row; one without measurements has only its state and RSSI. The range ends at the current minute. `target` is the host as configured, or `router`.
  - Events: `start, end, duration_s, type, target, address, worst_rtt_ms`
  - The Mac's own IP addresses aren't included. Target addresses, including the router's, are.

### 6.5 Wi‑Fi context

When the primary interface is Wi‑Fi, CoreWLAN (`CWWiFiClient.shared().interface()`) supplies RSSI, noise, transmit rate and channel (band and width), sampled every 5 s on a probe tick. The network name (SSID) and BSSID are not shown, because they need Location permission.

**Permissions check (M1, 2026-10-28): passed.** On macOS 27.2, the app bundle without Location authorization gets RSSI, noise, transmit rate and channel (number, band, width) from CoreWLAN. SSID and BSSID come back nil, as expected.

### 6.6 Menu bar

- A single `NSStatusItem`, monochrome in the menu bar's label color, fixed width. The width fits the widest value: `999ms`. Longer RTTs are shown in seconds (`1.2s`). `—` while warming up or with no data.
- **Display styles**:
  - `text`: label stacked above value (`RTT` / `23ms`; the label reads `TCP` in TCP mode)
  - `trace`: an RTT trace of recent history. A lost probe drops the line to the baseline, so a dead connection literally flatlines.
  - `text+trace`
- **Target shown**: Internet (default), Router, or both as two short stacked traces.
- The verdict is shown as a mark, not a color: nothing when Good, `!` for a problem, `×` for down or Offline, `‖` while paused.
- Click opens the popover. Right-click or Control-click opens a small menu: Open, Pause for 1 hour, Settings, Check for Updates, Quit.
- **Pause for 1 hour** stops all probes. The trace freezes and dims, the mark shows `‖`, and the menu item becomes "Resume". Probing restarts after an hour, on Resume, or on Quit and relaunch. Paused minutes are recorded as paused.
- VoiceOver reads a summary such as "Good. Internet 23 milliseconds, jitter 4, loss 0 percent. Router 3 milliseconds."

### 6.7 Popover

A single scrolling panel about 340 pt wide, built with SwiftUI.

1. **Header**: the verdict in words (e.g. "Internet problem: router is fine, 8 % loss to 1.1.1.1 and 8.8.8.8"), interface type, local IP, router IP, "via VPN" and "IPv6 problem" when relevant.
2. **Target cards** (Router, Internet, any custom targets): large RTT now; median, p95, baseline, jitter, loss; a 60-second trace with lost probes marked. The internet card has a row per host (and the IPv6 row), and labels hosts in TCP mode or answered locally.
3. **History**: 1 h, 24 h or 7 d chart of median and p95, with loss as bars under the baseline, RSSI as a faint line when on Wi‑Fi, so "loss went up when the signal dropped" is visible, and paused/locked/asleep gaps shaded and labeled.
4. **Wi‑Fi card**: RSSI, noise, signal-to-noise, transmit rate, band and channel width.
5. **Events**: the last 10 outages and spikes, plus **Export CSV**.
6. **Footer**: settings gear, Copy diagnostics, update indicator, Quit.

**States**: while warming up, the cards show `—` and "Measuring…". While paused, the header reads "Paused until 14:32" with a Resume button. When Offline, the cards are replaced by "No network" and the time it went offline. A hidden router leaves a one-line note in its place: "Router doesn't answer ping".

Traces and charts are drawn with SwiftUI `Canvas`, as in flatline. Popover views exist only while the popover is open.

### 6.8 First run

On first launch the popover opens once with a short note: what straylight sends and where (small pings to your router, 1.1.1.1 and 8.8.8.8), how to change the targets, and the Launch at login prompt. Notification permission is requested only when the user turns a notification on.

### 6.9 Notifications (opt-in)

- **Outage**: when an outage to the internet lasts 10 s, and again when it ends, with its duration.
- **Verdict changes** that hold for at least 30 s.

Both are off by default.

### 6.10 Settings

Shown in the popover (an inline settings panel, as in flatline), stored in `UserDefaults`:

| Setting | Options | Default |
|---|---|---|
| Probe interval on power | 0.5 s, 1 s, 2 s, 5 s | 1 s |
| Probe interval on battery, Low Power Mode, Low Data Mode, or expensive paths | 1 s, 2 s, 5 s, 10 s | 5 s |
| Internet hosts | Primary and secondary: 1.1.1.1, 8.8.8.8, 9.9.9.9, custom host; secondary can be off | 1.1.1.1 and 8.8.8.8 |
| Probe IPv6 on dual-stack networks | on / off | on |
| Custom targets | up to 2 hosts | none |
| Menu bar target | Internet, Router, both | Internet |
| Display style | text, trace, text+trace | text+trace |
| Keep monitoring while locked | on / off | off |
| History retention | 7, 30, 90 days (per-minute detail is kept for 7) | 30 days |
| Notifications | Outages, Verdict changes | off |
| Accent color | phosphor green, cyan, magenta, amber, system | phosphor green |
| Launch at login | on / off (`SMAppService.mainApp`) | off, with a prompt on first run |
| Automatic updates | check automatically / download automatically | check automatically, daily |

### 6.11 Diagnostics

There's no telemetry, so bug reports rely on what the user can copy:

- Logging through `os_log` with subsystem `as.banast.straylight` and categories `probe`, `targets`, `stats`, `history`.
- **Copy diagnostics** in the popover footer copies app and macOS versions, settings, the current targets with their addresses, protocols and states, the last 50 events and the last 10 minutes of log lines to the clipboard. Nothing is sent anywhere.

### 6.12 Updates and website

Same setup as flatline:

- **Sparkle 2** via Swift Package Manager. Appcast at `https://straylight.banast.as/appcast.xml`, EdDSA-signed updates, notarized DMGs under `/releases/`, appcast generated by the release script with notes from `CHANGELOG.md`.
- A small static site in `site/`: landing page, screenshot, download button, requirements, release notes. The landing page and README say plainly that straylight sends small ping packets to the targets you choose (your router, 1.1.1.1 and 8.8.8.8 by default).

## 7. Technical design

### 7.1 Stack

- **Swift 6.4**, strict concurrency, Swift 6 language mode
- **SwiftUI** for all views; **AppKit** only for `NSStatusItem` / `NSPopover`
- **Observation** (`@Observable`) for the model
- **BSD sockets** for probing, **SystemConfiguration** and **Network** (`NWPathMonitor`) for paths, **CoreWLAN** for Wi‑Fi details, the system **SQLite** library for history
- Deployment target **macOS 27.0**, **arm64 only**
- No third-party dependencies other than **Sparkle**

### 7.2 Project layout

```
straylight/
├── project.yml              # XcodeGen spec → Straylight.xcodeproj (generated, git-ignored)
├── Packages/
│   └── StraylightKit/       # Unit-tested with `swift test`
│       ├── Sources/StraylightKit/
│       │   ├── ICMPProber.swift      # datagram sockets, send, receive, kernel timestamps
│       │   ├── ICMPPacket.swift      # echo request and reply encoding, checksum
│       │   ├── ProbeResult.swift     # outcomes, reply matching, timeouts, late replies
│       │   ├── ProbeAddress.swift    # numeric IPv4/IPv6 addresses with scope, resolution
│       │   ├── MachClock.swift       # the clock both RTT timestamps use
│       │   ├── TCPProber.swift       # port-443 connect-time fallback
│       │   ├── PathMonitor.swift     # gateway discovery, IPv6, VPN handling (SCDynamicStore + NWPathMonitor)
│       │   ├── Targets.swift         # target planning, warm-up and TCP fallback rules
│       │   ├── ProbeEngine.swift     # the probe loop: path changes, wake, warm-up, results
│       │   ├── Stats.swift           # median, p95, jitter, loss, target states, verdict, events
│       │   ├── Monitor.swift         # engine results → stats, answered locally, snapshots, events
│       │   ├── History.swift         # SQLite store, per-minute and hourly aggregates, event log, CSV export
│       │   ├── Database.swift        # a small wrapper over the system SQLite library
│       │   ├── WiFi.swift            # CoreWLAN details
│       │   ├── Diagnostics.swift     # os_log categories, Copy diagnostics
│       │   ├── RingBuffer.swift      # from flatline (see §13)
│       │   └── Format.swift          # from flatline
│       ├── Sources/straylight-probe/ # dev CLI for checking probes against ping; not shipped
│       └── Tests/StraylightKitTests/
├── App/
│   ├── StraylightApp.swift
│   ├── DevChecks.swift          # STRAYLIGHT_DEV_LOG: Wi‑Fi and timer checks inside the app
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

Tests cover:

- the stats math against fixed RTT sequences, including jitter across losses
- every row of the §6.3 verdict table, two-host combining and "answered locally"
- reply matching when the kernel rewrites identifiers
- the fallback: ICMP blocked with TCP working switches to TCP; ICMP and TCP both failing is an outage and doesn't switch
- discarding probes across a simulated path change
- history minute states and the CSV columns
- a real probe to `127.0.0.1`

### 7.3 Probe loop

- One send timer with 10 % leeway sends to every target due in the same wake-up. Its interval drops to 1 s during warm-up or while any target is in fast recheck.
- Replies arrive through a `DispatchSourceRead` on each socket (one IPv4, one IPv6), so nothing polls for replies.
- Timeouts are checked on the next send tick, not with a separate timer.
- All socket work runs on one serial queue. The `@Observable` snapshot on the main actor is updated at most once per tick: `Monitor` publishes one 0.25 s after each round of probes, once most replies are in, and one after each network change.
- Each target keeps its own due time, so on 1 s ticks (warm-up, or another target in fast recheck) a 5 s target is still probed every 5 s. A fast recheck carries on past the end of warm-up.
- History is appended in memory and flushed to disk once a minute.
- **App Nap** could stretch the send timer. RTTs wouldn't be affected, because both timestamps are taken at the socket, but probe spacing would. M1 checked this (2026-10-28): over 10 minutes in the background, a 1 s timer with 10 % leeway fired 600 times, 958–1074 ms apart (median 1000.0 ms, p99 1039 ms), never past the leeway. No `ProcessInfo` activity is needed. Recheck on battery in M7.

**Battery:** Wi‑Fi radios save power by sleeping between beacons, and a probe every second keeps waking them. That's why the battery default is 5 s and probing stops while the screen is locked. Energy impact on battery is measured in M7 against flatline.

### 7.4 Menu bar rendering

Same approach as flatline (its PRD §7.4): draw into one image per tick, put it in a `CALayer` inside the status button rather than `button.image`, use the menu bar's label color, and skip the redraw when nothing visible changed.

### 7.5 Security and distribution

- Hardened runtime on. Not sandboxed, for the same Sparkle reasons as flatline.
- Signed with **Developer ID Application (team `F87BNUZAVJ`)**, notarized with `notarytool`, ticket stapled.
- Bundle ID `as.banast.straylight`. `LSUIElement = YES` (no Dock icon).
- Network traffic is limited to probes to the configured targets and Sparkle checking the appcast. No telemetry or analytics. History and diagnostics stay on the Mac unless the user exports or copies them.

## 8. Performance budgets

Measured on an M-series Mac with the default targets (router, two internet hosts, plus IPv6 on a dual-stack network), popover closed:

| Metric | Budget |
|---|---|
| Average CPU at a 1 s interval | < 0.1 % of one core |
| Resident memory | < 30 MB |
| Wake-ups | ≤ 1 timer wake-up plus one read event per reply, per interval |
| Network | < 1 kbit/s each way per target at a 1 s interval |
| Energy Impact (Activity Monitor), on power | ≈ flatline's |
| History on disk | < 10 MB at 90-day retention |
| Popover open → first frame | < 50 ms |

Checked before each release with Instruments and with a tick profiler: run the binary with `STRAYLIGHT_PROFILE=1`, as with flatline.

## 9. Accuracy acceptance criteria

| Metric | Reference | Tolerance |
|---|---|---|
| Median RTT | `ping -c 60` to the same target at the same time | ± 0.5 ms or ± 5 %, whichever is larger |
| Median RTT after sleep/wake | Same as above, run after the Mac has slept at least once | Same tolerance (catches mismatched clocks) |
| Loss | `ping -c 300` under Network Link Conditioner's 5 % loss profile | ± 2 points |
| Jitter | The §6.3 formula applied to `ping`'s per-reply times | ± 1 ms |
| Router | `route -n get default` | Exact |
| Network change | Switching Wi‑Fi ↔ Ethernet, joining a VPN, sleep/wake | Targets re-resolved and verdict updated within 3 s after warm-up; no false outage logged |
| Outage on battery | Unplug the router's WAN cable for 30 s on battery | Outage logged with start and end within one probe interval of the real ones; verdict Internet down; no switch to TCP |
| ICMP blocked | Block outbound ICMP to the internet hosts with `pf` | Hosts switch to TCP during warm-up; verdict stays Good |

**M1 results (2026-10-28, M2 Pro Mac mini on Ethernet, macOS 27.2).** `straylight-probe` and `ping` ran side by side at 1 s:

| Target | Median: straylight / ping | Jitter: straylight / ping | Result |
|---|---|---|---|
| Router (192.168.20.1) | 0.405 / 0.415 ms | 0.142 / 0.106 ms | Pass |
| 8.8.8.8 | 5.37 / 5.59 ms | | Pass |
| 9.9.9.9 | 7.51 / 7.52 ms | | Pass |
| 1.1.1.1 | 5.85–6.78 / 6.64–7.25 ms over 4 runs | 1.38 / 1.35 ms | Median **fails**: 0.5–0.9 ms lower than ping every run, even with each tool running alone |

The minimums to 1.1.1.1 agree within 0.02 ms, and `ping` times the same way straylight does (a stamp just before `sendto`, a kernel timestamp on receive, no traffic class by default). The difference looks like Cloudflare's path treating the two tools' packets differently, not a timing error, but the cause hasn't been found. Recheck in M2 with two internet hosts. Not yet run: the after-sleep check (this Mac hadn't slept since boot, so the two clocks were still equal) and the loss check (needs Network Link Conditioner).

**M2 results (2026-10-28, same Mac).** The router from the dynamic store matched `route -n get default` exactly (192.168.20.1 on en7). `straylight-probe --watch` showed warm-up end at 10 s with every target on ICMP. With amazon.com, which drops ping but accepts HTTPS, as the primary host, the TCP check succeeded during warm-up and the host switched to TCP timing (about 68 ms) with no ICMP results reported after the switch. Not yet tried, because they need hands on the network: Wi‑Fi ↔ Ethernet switching, a VPN as the primary interface (this Mac has a non-primary `utun4`), an IPv6-only network, and sleep/wake.

**M3 results (2026-10-28, same Mac).** `straylight-probe --monitor` ran the stats and verdict live:

- At 1 s, the verdict went from Measuring to Good at 10.9 s and held for 80 s. Windows held 60 probes. Medians: router 0.42 ms, 1.1.1.1 6.79 ms, 8.8.8.8 5.55 ms, no loss.
- At 5 s, rounds came every 5.0 s after warm-up and windows held 20 probes.
- With a never-answering second host (192.0.2.1), that host was Down from the end of warm-up, probed every second (fast recheck), and the verdict stayed Good on 1.1.1.1. With both hosts unreachable, the verdict was Internet down at 10.9 s and the TCP check didn't switch either host.

Not yet run: a real outage (unplugging the router's WAN) and the loss check.

**M4 results (2026-10-28, same Mac).** `straylight-probe --monitor 150 --history` recorded 2.5 minutes, and `--export` produced the CSV. The first minute had 25 probes per target, warm-up included (the run started 25 s before its end), the next two had 60, and the minutes before the run were exported as `not_running`. Rollups, retention, minute states, sleep marking, restarts within a minute and both CSV formats are covered by unit tests against an in-memory database. Not yet tried on a real sleep. The app doesn't record history yet: it gets the monitor in M5.

## 10. Accessibility and localization

- VoiceOver labels on the status item and on every popover value; lost probes in traces are described in text ("3 lost in the last minute")
- The popover respects Reduce Motion (traces stop animating) and Increase Contrast
- Color is never the only signal: the verdict is always in words, and the menu bar uses marks
- English only for 1.0, with all strings in a String Catalog

## 11. Milestones

| # | Milestone | Done when |
|---|---|---|
| M0 | Scaffold | XcodeGen project builds an empty menu bar app; `swift test` runs; String Catalog in place |
| M1 | Prober | ICMP over IPv4 and IPv6, reply matching, timeouts, TCP fallback; RTT matches §9, including after sleep/wake; Wi‑Fi permissions check and App Nap check done |
| M2 | Targets + paths | Gateway discovery, IPv6 and link-local router, two internet hosts, VPN handling, warm-up, fallback decision, path changes with no false loss |
| M3 | Stats + verdict | Metrics, target states, "answered locally", verdict, events, fast recheck; every verdict row unit-tested; starting thresholds in place |
| M4 | History | SQLite store, per-minute and hourly aggregates, minute states, event log, retention, CSV export |
| M5 | Menu bar | All styles, both-targets view, verdict marks, pause, fixed width; VoiceOver summary |
| M6 | Popover | Target cards, Wi‑Fi card, verdict header, history chart, all §6.7 states, first run, Copy diagnostics; VoiceOver labels, Reduce Motion, Increase Contrast |
| M7 | Settings, battery, tuning | All §6.10 settings persist; notifications; battery, Low Power and Low Data rates and lock pause work; energy measured; thresholds tuned against a week of real Wi‑Fi and Ethernet history |
| M8 | Distribution | `scripts/release.sh` produces a signed, notarized, stapled DMG |
| M9 | Updates + site | Sparkle wired up; site deployed with appcast; an update tested end to end |
| M10 | 1.0 | §8 budgets and §9 criteria verified; README screenshots; tagged release |

## 12. Decisions

| Question | Decision |
|---|---|
| Name | **straylight** (2026-10-25) |
| Signing | Same Developer ID team as flatline (`F87BNUZAVJ`), notarized with `notarytool` (2026-10-25) |
| Hosting | **Cloudflare Pages** at straylight.banast.as, same as flatline (2026-10-25) |
| License | **MIT** (2026-10-25) |
| Menu bar colors | **Monochrome**, for the same reason as flatline (2026-10-25) |
| Default internet target | **Two hosts from different providers**, 1.1.1.1 and 8.8.8.8; the internet is OK if either is. The extra traffic is under 1 kbit/s. (2026-10-26) |
| IPv6 | **IPv4 drives the verdict**; on dual-stack networks the primary host is also probed over IPv6 and problems are noted; IPv6-only networks use IPv6 throughout (2026-10-26) |
| Router-only trouble | **Not a local problem** while the internet is OK, because routers often deprioritize ping to themselves (2026-10-26) |
| History storage | **SQLite** (system library); per-minute for 7 days, hourly up to the retention period (2026-10-26) |

## 13. Open questions

1. **Shared code with flatline and freeside**: copy `RingBuffer`, `Format`, the menu bar renderer and the release scripts, or extract a shared Swift package (working name `sprawl`)? Same question as in freeside's PRD; decide once for all three.
2. **Hop-by-hop view**: an mtr-style view would show where along the path loss starts. It needs TTL-limited probes. M1 showed this works without root over IPv4: the datagram socket accepts `IP_TTL`, and a TTL 1 probe got a Time Exceeded reply from the router (`straylight-probe --ttl 1`). IPv6 (`IPV6_UNICAST_HOPS`) is untested. Worth a spike after 1.0.
3. **DNS timing**: is resolver latency worth tracking? Caching makes it hard to measure honestly.
4. **On-demand capacity test**: a button that runs macOS's `networkQuality` and shows the result? It saturates the link for about 20 s, so on demand only.
5. **Flatline integration**: should flatline's network card show straylight's verdict when both are running, or should the apps stay fully separate?
6. **Repo visibility**: private until 1.0, or public from the start?
