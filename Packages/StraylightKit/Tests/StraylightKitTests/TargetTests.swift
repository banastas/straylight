import Darwin
import Testing
@testable import StraylightKit

@Suite struct NetworkPathTests {
    @Test func plainIPv4() {
        let path = NetworkPath(store: StoreSnapshot(
            primaryInterface: "en0", routerIPv4: "192.168.1.1",
            services: [.init(interface: "en0", routerIPv4: "192.168.1.1")]
        ))
        #expect(path.hasIPv4 && !path.hasIPv6 && !path.isVPN)
        #expect(path.physicalInterface == "en0")
        #expect(path.routerIPv4 == ProbeAddress("192.168.1.1"))
        #expect(path.routerIPv6 == nil)
    }

    @Test func vpnUsesThePhysicalServicesRouter() {
        let path = NetworkPath(store: StoreSnapshot(
            primaryInterface: "utun4", routerIPv4: "100.64.0.1",
            services: [
                .init(interface: "utun4", routerIPv4: "100.64.0.1"),
                .init(interface: "en1"),
                .init(interface: "en0", routerIPv4: "10.0.0.1"),
            ]
        ))
        #expect(path.isVPN)
        #expect(path.physicalInterface == "en0")
        #expect(path.routerIPv4 == ProbeAddress("10.0.0.1"))
    }

    @Test func ipv6OnlyGetsAScopedLinkLocalRouter() {
        let path = NetworkPath(store: StoreSnapshot(
            hasGlobalIPv6: true, primaryInterfaceIPv6: "lo0", routerIPv6: "fe80::1"
        ))
        #expect(!path.hasIPv4 && path.hasIPv6)
        #expect(path.primaryInterface == "lo0")
        #expect(path.routerIPv6 == ProbeAddress("fe80::1%lo0"))
        #expect(path.routerIPv6?.scopeID == if_nametoindex("lo0"))
    }

    @Test func noPrimaryInterfaceMeansNoRouter() {
        let path = NetworkPath(store: StoreSnapshot())
        #expect(!path.hasIPv4 && !path.hasIPv6)
        #expect(path.routerIPv4 == nil && path.primaryInterface == nil)
    }
}

@Suite struct TargetPlanTests {
    func path(ipv4: Bool = true, ipv6: Bool = false) -> NetworkPath {
        var path = NetworkPath()
        path.isSatisfied = true
        path.hasIPv4 = ipv4
        path.hasIPv6 = ipv6
        path.routerIPv4 = ipv4 ? ProbeAddress("192.168.1.1") : nil
        path.routerIPv6 = ipv6 ? ProbeAddress("fe80::1%lo0") : nil
        return path
    }

    func noResolve(_ host: String) -> [ProbeAddress] { [] }

    @Test func ipv4Defaults() {
        let targets = TargetPlan.targets(for: path(), settings: TargetSettings(), resolve: noResolve)
        #expect(targets.map(\.role) == [.router, .internet(0), .internet(1)])
        #expect(targets.map(\.address.description) == ["192.168.1.1", "1.1.1.1", "8.8.8.8"])
    }

    @Test func dualStackAddsThePrimaryHostOverIPv6() {
        let targets = TargetPlan.targets(for: path(ipv6: true), settings: TargetSettings(), resolve: noResolve)
        #expect(targets.map(\.role) == [.router, .internet(0), .internet(1), .internetIPv6])
        #expect(targets.last?.address.description == "2606:4700:4700::1111")

        var settings = TargetSettings()
        settings.probeIPv6 = false
        #expect(!TargetPlan.targets(for: path(ipv6: true), settings: settings, resolve: noResolve).map(\.role).contains(.internetIPv6))
    }

    @Test func ipv6OnlyUsesIPv6Throughout() {
        let targets = TargetPlan.targets(for: path(ipv4: false, ipv6: true), settings: TargetSettings(), resolve: noResolve)
        #expect(targets.map(\.role) == [.router, .internet(0), .internet(1)])
        #expect(targets.map(\.address.description) == ["fe80::1%lo0", "2606:4700:4700::1111", "2001:4860:4860::8888"])
    }

    @Test func secondaryHostCanBeOff() {
        var settings = TargetSettings()
        settings.internetHosts = ["9.9.9.9"]
        #expect(TargetPlan.targets(for: path(), settings: settings, resolve: noResolve).map(\.role) == [.router, .internet(0)])
    }

    @Test func customHostsResolveAndFallBackToTheOtherFamily() {
        var settings = TargetSettings()
        settings.customHosts = ["vpn.example.com", "v6only.example.com", "unknown.example.com"]
        let resolve: (String) -> [ProbeAddress] = { host in
            switch host {
            case "vpn.example.com": [ProbeAddress("2001:db8::1")!, ProbeAddress("203.0.113.7")!]
            case "v6only.example.com": [ProbeAddress("2001:db8::2")!]
            default: []
            }
        }
        let targets = TargetPlan.targets(for: path(ipv6: true), settings: settings, resolve: resolve)
        let custom = targets.filter { if case .custom = $0.role { true } else { false } }
        #expect(custom.map(\.address.description) == ["203.0.113.7", "2001:db8::2"])

        // Without IPv6 on the network, an IPv6-only host is left out.
        #expect(TargetPlan.targets(for: path(), settings: settings, resolve: resolve).filter { $0.role == .custom(1) }.isEmpty)
    }

    @Test func noTargetsWithoutAPath() {
        var offline = path()
        offline.isSatisfied = false
        #expect(TargetPlan.targets(for: offline, settings: TargetSettings(), resolve: noResolve).isEmpty)
    }
}

@Suite struct TargetTrackerTests {
    let router = Target(role: .router, host: "router", address: ProbeAddress("192.168.1.1")!)
    let internet = Target(role: .internet(0), host: "1.1.1.1", address: ProbeAddress("1.1.1.1")!)
    let custom = Target(role: .custom(0), host: "game", address: ProbeAddress("203.0.113.7")!)

    /// Runs warm-up with one probe a second and returns the status it ends in.
    func warmUp(_ target: Target, isVPN: Bool = false, routerAnswered: Bool = true, icmp: Bool, tcp: Bool) -> (TargetStatus, sentTCP: Bool) {
        var tracker = TargetTracker(target: target, isVPN: isVPN, now: 0)
        var sentTCP = false
        for second in 0..<10 {
            let sends = tracker.sends(now: Double(second), interval: 1, routerAnswered: routerAnswered, sinceLastCheck: 0)
            if sends.icmp { _ = tracker.recordICMP(replied: icmp) }
            if sends.tcp {
                sentTCP = true
                tracker.recordTCP(replied: tcp)
            }
        }
        _ = tracker.finishWarmUpIfDue(now: 10)
        return (tracker.status, sentTCP)
    }

    @Test func answeringTargetsUseICMP() {
        #expect(warmUp(router, icmp: true, tcp: false) == (.icmp, false))
        #expect(warmUp(internet, icmp: true, tcp: false) == (.icmp, false))
    }

    @Test func silentRouterIsHiddenOrBlockedByVPN() {
        #expect(warmUp(router, icmp: false, tcp: false).0 == .doesntAnswerPing)
        #expect(warmUp(router, isVPN: true, icmp: false, tcp: false).0 == .unreachableVPN)
    }

    @Test func internetHostSwitchesToTCPOnlyWhenTCPWorks() {
        #expect(warmUp(internet, icmp: false, tcp: true) == (.tcp, true))
        // ICMP and TCP both failing is an outage, not blocked ICMP.
        #expect(warmUp(internet, icmp: false, tcp: false) == (.icmp, true))
    }

    @Test func noTCPCheckWhileTheRouterIsSilentOrForCustomTargets() {
        #expect(warmUp(internet, routerAnswered: false, icmp: false, tcp: true) == (.icmp, false))
        #expect(warmUp(custom, icmp: false, tcp: true) == (.icmp, false))
    }

    @Test func warmUpLastsTenSeconds() {
        var tracker = TargetTracker(target: internet, isVPN: false, now: 100)
        _ = tracker.recordICMP(replied: true)
        #expect(tracker.finishWarmUpIfDue(now: 109.9) == nil)
        #expect(tracker.finishWarmUpIfDue(now: 110) == .icmp)
        #expect(tracker.finishWarmUpIfDue(now: 111) == nil)
    }

    @Test func tcpModeRetriesICMPEachMinuteAndLeavesAfterThreeReplies() {
        var tracker = TargetTracker(target: internet, isVPN: false, now: 0)
        tracker.recordTCP(replied: true)
        _ = tracker.finishWarmUpIfDue(now: 10)
        #expect(tracker.status == .tcp)
        #expect(tracker.sends(now: 20, interval: 1, routerAnswered: true, sinceLastCheck: 10) == .init(icmp: false, tcp: true, icmpIsCheck: true))
        #expect(tracker.sends(now: 70, interval: 1, routerAnswered: true, sinceLastCheck: 60).icmp)

        #expect(tracker.recordICMP(replied: true) == nil)
        #expect(tracker.recordICMP(replied: false) == nil)
        #expect(tracker.recordICMP(replied: true) == nil)
        #expect(tracker.recordICMP(replied: true) == nil)
        #expect(tracker.recordICMP(replied: true) == .icmp)
    }

    @Test func silentRouterComesBackOnAnyReply() {
        var tracker = TargetTracker(target: router, isVPN: false, now: 0)
        _ = tracker.finishWarmUpIfDue(now: 10)
        #expect(tracker.status == .doesntAnswerPing)
        #expect(tracker.sends(now: 30, interval: 1, routerAnswered: false, sinceLastCheck: 20) == .init(icmpIsCheck: true))
        #expect(tracker.recordICMP(replied: true) == .icmp)
    }
}
