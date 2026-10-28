import Dispatch
import Network
import SystemConfiguration

/// The network as straylight needs it: which interface carries traffic, the
/// router to probe, which address families work, and whether a VPN is in the
/// way (PRD §6.1).
public struct NetworkPath: Equatable, Sendable {
    public enum Kind: Sendable {
        case wifi, ethernet, cellular, other
    }

    /// False when there's no usable route at all (the Offline verdict).
    public var isSatisfied = false
    /// The interface the default route uses, such as `en0` or `utun4`.
    public var primaryInterface: String?
    /// The interface under a VPN; the same as `primaryInterface` without one.
    public var physicalInterface: String?
    public var kind = Kind.other
    public var isVPN = false
    public var hasIPv4 = false
    public var hasIPv6 = false
    public var routerIPv4: ProbeAddress?
    /// Usually link-local, scoped to the physical interface.
    public var routerIPv6: ProbeAddress?
    /// For example an iPhone hotspot.
    public var isExpensive = false
    /// Low Data Mode.
    public var isConstrained = false

    public init() {}
}

/// What straylight reads from the SystemConfiguration dynamic store, as plain
/// values so the rules in `NetworkPath.init(store:)` can be tested.
struct StoreSnapshot: Equatable {
    struct Service: Equatable {
        var interface: String
        var routerIPv4: String?
        var routerIPv6: String?
    }

    /// `State:/Network/Global/IPv4` → `PrimaryInterface` and `Router`.
    var primaryInterface: String?
    var routerIPv4: String?
    /// `State:/Network/Global/IPv6`, present only when IPv6 routes beyond the link.
    var hasGlobalIPv6 = false
    var primaryInterfaceIPv6: String?
    var routerIPv6: String?
    /// `State:/Network/Service/*/IPv4` and `/IPv6`, in the user's service order.
    var services: [Service] = []
}

extension NetworkPath {
    static func isTunnel(_ interface: String) -> Bool {
        ["utun", "ipsec", "ppp", "tun", "tap"].contains { interface.hasPrefix($0) }
    }

    /// Builds the store's half of a path. When a VPN is the primary interface,
    /// the router comes from the first non-tunnel service in service order
    /// that has one (PRD §6.1).
    init(store: StoreSnapshot) {
        self.init()
        hasIPv4 = store.primaryInterface != nil
        hasIPv6 = store.hasGlobalIPv6
        primaryInterface = store.primaryInterface ?? store.primaryInterfaceIPv6
        guard let primaryInterface else { return }

        isVPN = Self.isTunnel(primaryInterface)
        if isVPN {
            let physical = store.services.first { !Self.isTunnel($0.interface) && ($0.routerIPv4 != nil || $0.routerIPv6 != nil) }
            physicalInterface = physical?.interface
            routerIPv4 = physical?.routerIPv4.flatMap { ProbeAddress($0) }
            routerIPv6 = physical.flatMap { service in service.routerIPv6.flatMap { Self.scoped($0, to: service.interface) } }
        } else {
            physicalInterface = primaryInterface
            routerIPv4 = store.routerIPv4.flatMap { ProbeAddress($0) }
            let interface = store.primaryInterfaceIPv6 ?? primaryInterface
            routerIPv6 = store.routerIPv6.flatMap { Self.scoped($0, to: interface) }
        }
    }

    /// Link-local routers need the interface to be reachable.
    static func scoped(_ router: String, to interface: String) -> ProbeAddress? {
        if router.lowercased().hasPrefix("fe80:"), !router.contains("%") {
            return ProbeAddress(router + "%" + interface)
        }
        return ProbeAddress(router)
    }
}

/// Watches the dynamic store and `NWPathMonitor` and reports a new
/// `NetworkPath` whenever it changes, without polling. Changes arrive in
/// bursts, so reads wait 0.5 s for things to settle.
///
/// Runs on `queue`, and `onChange` is called on it.
public final class PathMonitor: @unchecked Sendable {
    private let queue: DispatchQueue
    private let onChange: @Sendable (NetworkPath) -> Void
    private var store: SCDynamicStore?
    private let pathMonitor = NWPathMonitor()
    private var nwPath: Network.NWPath?
    private var pendingRead: DispatchWorkItem?
    private var lastPath: NetworkPath?

    public init(queue: DispatchQueue, onChange: @escaping @Sendable (NetworkPath) -> Void) {
        self.queue = queue
        self.onChange = onChange
    }

    public func start() {
        var context = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        store = SCDynamicStoreCreate(nil, "straylight" as CFString, { _, _, info in
            guard let info else { return }
            Unmanaged<PathMonitor>.fromOpaque(info).takeUnretainedValue().scheduleRead()
        }, &context)
        if let store {
            let keys = ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6", "Setup:/Network/Global/IPv4"]
            let patterns = ["State:/Network/Service/[^/]+/IPv4", "State:/Network/Service/[^/]+/IPv6"]
            SCDynamicStoreSetNotificationKeys(store, keys as CFArray, patterns as CFArray)
            SCDynamicStoreSetDispatchQueue(store, queue)
        }

        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            nwPath = path
            scheduleRead()
        }
        pathMonitor.start(queue: queue)
    }

    public func stop() {
        if let store { SCDynamicStoreSetDispatchQueue(store, nil) }
        store = nil
        pathMonitor.cancel()
        pendingRead?.cancel()
    }

    deinit {
        if let store { SCDynamicStoreSetDispatchQueue(store, nil) }
        pathMonitor.cancel()
    }

    private func scheduleRead() {
        pendingRead?.cancel()
        let read = DispatchWorkItem { [weak self] in self?.read() }
        pendingRead = read
        queue.asyncAfter(deadline: .now() + 0.5, execute: read)
    }

    private func read() {
        guard let store else { return }
        let path = Self.path(store: Self.snapshot(store), nwPath: nwPath)
        guard path != lastPath else { return }
        lastPath = path
        onChange(path)
    }

    /// One read without watching, for tools and tests. Blocks for up to a second
    /// waiting for `NWPathMonitor`'s first answer.
    public static func current() -> NetworkPath {
        let queue = DispatchQueue(label: "straylight.path.current")
        let monitor = NWPathMonitor()
        let ready = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var nwPath: Network.NWPath?
        monitor.pathUpdateHandler = { path in
            if nwPath == nil { nwPath = path; ready.signal() }
        }
        monitor.start(queue: queue)
        _ = ready.wait(timeout: .now() + 1)
        monitor.cancel()
        let store = SCDynamicStoreCreate(nil, "straylight" as CFString, nil, nil)
        return queue.sync { path(store: store.map(snapshot) ?? StoreSnapshot(), nwPath: nwPath) }
    }

    static func path(store: StoreSnapshot, nwPath: Network.NWPath?) -> NetworkPath {
        var path = NetworkPath(store: store)
        guard let nwPath else { return path }
        path.isSatisfied = nwPath.status == .satisfied && (path.hasIPv4 || path.hasIPv6)
        path.isExpensive = nwPath.isExpensive
        path.isConstrained = nwPath.isConstrained
        let physical = nwPath.availableInterfaces.first { $0.name == path.physicalInterface }
        path.kind = switch physical?.type {
        case .wifi: .wifi
        case .wiredEthernet: .ethernet
        case .cellular: .cellular
        default: .other
        }
        return path
    }

    static func snapshot(_ store: SCDynamicStore) -> StoreSnapshot {
        func dictionary(_ key: String) -> [String: Any]? {
            SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any]
        }
        var snapshot = StoreSnapshot()
        if let global = dictionary("State:/Network/Global/IPv4") {
            snapshot.primaryInterface = global["PrimaryInterface"] as? String
            snapshot.routerIPv4 = global["Router"] as? String
        }
        if let global = dictionary("State:/Network/Global/IPv6") {
            snapshot.hasGlobalIPv6 = true
            snapshot.primaryInterfaceIPv6 = global["PrimaryInterface"] as? String
            snapshot.routerIPv6 = global["Router"] as? String
        }

        let patterns = ["State:/Network/Service/[^/]+/IPv4", "State:/Network/Service/[^/]+/IPv6"]
        let entries = SCDynamicStoreCopyMultiple(store, nil, patterns as CFArray) as? [String: Any] ?? [:]
        var services: [String: StoreSnapshot.Service] = [:]
        for (key, value) in entries {
            let parts = key.split(separator: "/")
            guard parts.count == 5, let entity = value as? [String: Any], let interface = entity["InterfaceName"] as? String else { continue }
            let id = String(parts[3])
            var service = services[id] ?? .init(interface: interface)
            if parts[4] == "IPv4" { service.routerIPv4 = entity["Router"] as? String } else { service.routerIPv6 = entity["Router"] as? String }
            services[id] = service
        }
        let order = dictionary("Setup:/Network/Global/IPv4")?["ServiceOrder"] as? [String] ?? []
        let ordered = order.compactMap { services[$0] }
        let unordered = services.filter { !order.contains($0.key) }.sorted { $0.key < $1.key }.map(\.value)
        snapshot.services = ordered + unordered
        return snapshot
    }
}
