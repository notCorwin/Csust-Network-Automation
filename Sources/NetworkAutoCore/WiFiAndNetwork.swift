import CoreWLAN
import Darwin
import Foundation
import HotspotCore
import Network
import ObjectiveC

public struct WiFiNetwork: Equatable, Sendable {
    public let interfaceName: String
    public let ssid: String?
    public let bssid: String?
    public let ip: String?

    public init(interfaceName: String, ssid: String?, bssid: String?, ip: String?) {
        self.interfaceName = interfaceName
        self.ssid = ssid
        self.bssid = bssid
        self.ip = ip
    }

    public var key: String {
        "\(interfaceName) / \(bssid ?? "未知 BSSID") / \(ip ?? "未分配 IPv4")"
    }
}

public func usableIPv4(_ value: String) -> Bool {
    let parts = value.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) else { return false }
    let octets = parts.compactMap { UInt8($0) }
    guard octets.count == 4 else { return false }
    if octets[0] == 0 || octets[0] >= 224 || octets[0] == 127 { return false }
    if octets[0] == 169 && octets[1] == 254 { return false }
    if octets[0] == 198 && (octets[1] == 18 || octets[1] == 19) { return false }
    return true
}

public func selectNetwork(
    _ networks: [WiFiNetwork],
    campusSSID: String = AppConstants.defaultCampusSSID
) -> WiFiNetwork? {
    networks.first { $0.ssid == campusSSID }
}

public func campusConnectionStatus(
    networks: [WiFiNetwork],
    permissionAuthorized: Bool,
    state: AppState,
    campusSSID: String = AppConstants.defaultCampusSSID
) -> String {
    guard permissionAuthorized else { return "需要定位权限" }
    guard let network = selectNetwork(networks, campusSSID: campusSSID) else { return "未连接" }
    guard state.network == network.key else { return state.checking ? "登录中" : "未登录" }
    switch state.phase {
    case .credentials: return state.checking ? "登录中" : "认证失败"
    case .configError: return state.checking ? "登录中" : "设置有误"
    case .waitingIP: return "等待分配 IP"
    case .online: return "已登录"
    case .retry: return state.checking ? "登录中" : "重试中（第 \(state.attempt) 次）"
    default: return state.checking ? "登录中" : "未登录"
    }
}

public func shouldFallbackForAuthentication(_ state: AppState, campus: WiFiNetwork?) -> Bool {
    guard !state.checking, let campus, state.network == campus.key else { return false }
    return state.phase == .credentials || state.phase == .configError || (state.phase == .retry && state.attempt >= 3)
}

public struct InterfaceIPv4Entry: Equatable, Sendable {
    public let interfaceName: String
    public let ip: String
    public let isUpAndRunning: Bool

    public init(interfaceName: String, ip: String, isUpAndRunning: Bool) {
        self.interfaceName = interfaceName
        self.ip = ip
        self.isUpAndRunning = isUpAndRunning
    }
}

/// Deterministically selects the primary usable IPv4 address per active interface,
/// preserving `getifaddrs` declaration order rather than hashing into an unordered dictionary.
public func selectPrimaryIPv4Addresses(from entries: [InterfaceIPv4Entry]) -> [String: String] {
    var result: [String: String] = [:]
    for entry in entries where entry.isUpAndRunning && usableIPv4(entry.ip) {
        if result[entry.interfaceName] == nil {
            result[entry.interfaceName] = entry.ip
        }
    }
    return result
}

public func interfaceIPv4Addresses() -> [String: String] {
    var entries: [InterfaceIPv4Entry] = []
    var addressPointer: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&addressPointer) == 0, let first = addressPointer else { return [:] }
    defer { freeifaddrs(first) }

    var current: UnsafeMutablePointer<ifaddrs>? = first
    while let pointer = current {
        defer { current = pointer.pointee.ifa_next }
        guard let address = pointer.pointee.ifa_addr,
              address.pointee.sa_family == sa_family_t(AF_INET) else { continue }
        let flags = pointer.pointee.ifa_flags
        let isUpAndRunning = (flags & UInt32(IFF_UP | IFF_RUNNING)) == UInt32(IFF_UP | IFF_RUNNING)
        var ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard let text = buffer.withUnsafeMutableBufferPointer({ bufferPointer in
            inet_ntop(AF_INET, &ipv4, bufferPointer.baseAddress, socklen_t(INET_ADDRSTRLEN))
        }) else { continue }
        entries.append(InterfaceIPv4Entry(
            interfaceName: String(cString: pointer.pointee.ifa_name),
            ip: String(cString: text),
            isUpAndRunning: isUpAndRunning
        ))
    }
    return selectPrimaryIPv4Addresses(from: entries)
}

public final class WiFiMonitor: NSObject, CWEventDelegate, @unchecked Sendable {
    private let client = CWWiFiClient.shared()
    private let lock = NSLock()
    private var monitoring = false
    public var onChange: (@Sendable () -> Void)?

    public override init() {
        super.init()
    }

    public func start() {
        lock.lock()
        monitoring = true
        lock.unlock()
        registerEvents()
        onChange?()
    }

    public func stop() {
        lock.lock()
        monitoring = false
        lock.unlock()
        _ = try? client.stopMonitoringAllEvents()
    }

    private func registerEvents() {
        client.delegate = self
        for event in [CWEventType.ssidDidChange, .bssidDidChange, .linkDidChange, .powerDidChange] {
            _ = try? client.startMonitoringEvent(with: event)
        }
    }

    private func scheduleResubscribe() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let active = self.monitoring
            self.lock.unlock()
            guard active else { return }
            self.registerEvents()
            self.onChange?()
        }
    }

    public func networks() -> [WiFiNetwork] {
        let addresses = interfaceIPv4Addresses()
        var result: [WiFiNetwork] = []
        for interface in client.interfaces() ?? [] {
            guard let name = interface.interfaceName else { continue }
            result.append(WiFiNetwork(
                interfaceName: name,
                ssid: interface.ssid(),
                bssid: interface.bssid(),
                ip: addresses[name]
            ))
        }
        return result
    }

    /// CoreWLAN does not expose this flag publicly. Treat an unavailable or
    /// ambiguous saved profile as unknown and never use it to control Wi-Fi.
    public static func personalHotspotProfile(
        networks: [WiFiNetwork],
        campusSSID: String = AppConstants.defaultCampusSSID
    ) -> Bool? {
        let client = CWWiFiClient()
        let selector = NSSelectorFromString("isPersonalHotspot")
        let linked = networks.filter { $0.ssid != nil || $0.bssid != nil || $0.ip != nil }
        guard linked.count == 1 else { return nil }
        var results: [Bool] = []
        for network in linked {
            guard let ssid = network.ssid, ssid != campusSSID, network.bssid != nil,
                  let interface = client.interface(withName: network.interfaceName),
                  let profiles = interface.configuration()?.networkProfiles else { continue }
            let matching = profiles.compactMap { $0 as? CWNetworkProfile }.filter { $0.ssid == ssid }
            guard matching.count == 1, let profile = matching.first,
                  profile.responds(to: selector),
                  let method = class_getInstanceMethod(type(of: profile), selector),
                  method_getNumberOfArguments(method) == 2 else { continue }
            let returnType = method_copyReturnType(method)
            defer { free(returnType) }
            let encoding = String(cString: returnType)
            if encoding == "B" {
                typealias BoolGetter = @convention(c) (AnyObject, Selector) -> Bool
                let getter = unsafeBitCast(method_getImplementation(method), to: BoolGetter.self)
                results.append(getter(profile, selector))
            } else if encoding == "c" {
                typealias CharGetter = @convention(c) (AnyObject, Selector) -> Int8
                let getter = unsafeBitCast(method_getImplementation(method), to: CharGetter.self)
                results.append(getter(profile, selector) != 0)
            }
        }
        guard results.count == 1 else { return nil }
        return results[0]
    }

    public func ssidDidChangeForWiFiInterface(withName interfaceName: String) { onChange?() }
    public func bssidDidChangeForWiFiInterface(withName interfaceName: String) { onChange?() }
    public func linkDidChangeForWiFiInterface(withName interfaceName: String) { onChange?() }
    public func powerStateDidChangeForWiFiInterface(withName interfaceName: String) { onChange?() }

    public func clientConnectionInterrupted() { scheduleResubscribe(); onChange?() }
    public func clientConnectionInvalidated() { scheduleResubscribe(); onChange?() }
}

public struct PathSignature: Equatable, Sendable {
    public let satisfied: Bool
    public let usesWiFi: Bool
    public let usesEthernet: Bool
    public let isExpensive: Bool
    public let interfaces: [String]
    public let gateways: [String]

    public init(satisfied: Bool, usesWiFi: Bool, usesEthernet: Bool, isExpensive: Bool,
                interfaces: [String], gateways: [String]) {
        self.satisfied = satisfied
        self.usesWiFi = usesWiFi
        self.usesEthernet = usesEthernet
        self.isExpensive = isExpensive
        self.interfaces = interfaces
        self.gateways = gateways
    }

    public init(_ path: NWPath) {
        self.satisfied = path.status == .satisfied
        self.usesWiFi = path.usesInterfaceType(.wifi)
        self.usesEthernet = path.usesInterfaceType(.wiredEthernet)
        self.isExpensive = path.isExpensive
        self.interfaces = path.availableInterfaces.map(\.name).sorted()
        self.gateways = path.gateways.map(\.debugDescription).sorted()
    }
}

public func shouldPauseCampusSearchForHotspot(enabled: Bool, phase: HotspotPhase) -> Bool {
    guard enabled else { return false }
    switch phase {
    case .browsing, .activating, .joining, .confirming, .retrying:
        return true
    case .disabled, .suspended, .waitingForNetwork, .networkAvailable, .failed:
        return false
    }
}

public func fallbackCooldownSeconds(consecutiveFallbacks: Int) -> Int {
    let exponent = min(max(0, consecutiveFallbacks - 1), 3)
    return min(120 * (1 << exponent), 600)
}

public func campusCandidateEligible(rssi: Int, replacingHotspot: Bool) -> Bool {
    replacingHotspot ? rssi >= -72 : true
}

/// Only a link established by this coordinator may be replaced by campus Wi-Fi.
public func maySelectCampus(networks: [WiFiNetwork], permissionAuthorized: Bool, ownedHotspotSSID: String?) -> Bool {
    guard permissionAuthorized else { return false }
    return networks.allSatisfy { network in
        if let ssid = network.ssid { return ssid == ownedHotspotSSID }
        return network.bssid == nil && network.ip == nil
    }
}

public func verifiedHotspotSSID(_ ssid: String?, bssid: String?, networks: [WiFiNetwork]) -> String? {
    guard let ssid, let bssid, networks.contains(where: { $0.ssid == ssid && $0.bssid == bssid }) else { return nil }
    return ssid
}

public struct ConfirmedHotspot: Codable, Equatable, Sendable {
    public let ssid: String
    public let bssid: String
    public let confirmedAt: Date

    public init(ssid: String, bssid: String, confirmedAt: Date) {
        self.ssid = ssid
        self.bssid = bssid
        self.confirmedAt = confirmedAt
    }
}

public final class HotspotIdentityCache: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "confirmedHotspot.v1"
    private let lifetime: TimeInterval = 30 * 24 * 60 * 60
    private let lock = NSLock()
    private var saved: ConfirmedHotspot?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key) {
            saved = try? JSONDecoder().decode(ConfirmedHotspot.self, from: data)
        }
    }

    public func remember(ssid: String, bssid: String, now: Date = Date()) {
        let identity = ConfirmedHotspot(ssid: ssid, bssid: bssid, confirmedAt: now)
        guard !ssid.isEmpty, !bssid.isEmpty, let data = try? JSONEncoder().encode(identity) else { return }
        lock.lock()
        saved = identity
        defaults.set(data, forKey: key)
        lock.unlock()
    }

    public func matching(networks: [WiFiNetwork], now: Date = Date()) -> ConfirmedHotspot? {
        lock.lock()
        defer { lock.unlock() }
        guard let saved else { return nil }
        guard !saved.ssid.isEmpty, !saved.bssid.isEmpty,
              now >= saved.confirmedAt, now.timeIntervalSince(saved.confirmedAt) < lifetime else {
            self.saved = nil
            defaults.removeObject(forKey: key)
            return nil
        }
        guard networks.contains(where: { $0.ssid == saved.ssid && $0.bssid == saved.bssid && $0.ip != nil }) else { return nil }
        return saved
    }
}

public enum WiFiControlIssue: Equatable, Sendable {
    case occupied, unavailable
}

public func hotspotRecognition(profile: Bool?, cachedMatch: Bool, pathExpensive: Bool = false) -> Bool? {
    if let profile { return profile }
    if cachedMatch { return true }
    if pathExpensive { return true }
    return nil
}

public func acceptsHotspotProfileResult(
    token: UInt,
    currentToken: UInt,
    authorized: Bool,
    queried: [WiFiNetwork],
    current: [WiFiNetwork]
) -> Bool {
    token == currentToken && authorized && queried == current
}

public func personalHotspotStatus(
    networks: [WiFiNetwork],
    permissionAuthorized: Bool,
    ownedSSID: String?,
    ownedBSSID: String?,
    sleeping: Bool,
    controlIssue: WiFiControlIssue?,
    phase: HotspotPhase,
    recognizedHotspot: Bool? = nil,
    campusSSID: String = AppConstants.defaultCampusSSID
) -> String {
    if sleeping { return "已暂停" }
    guard permissionAuthorized else { return "需要定位权限" }
    if verifiedHotspotSSID(ownedSSID, bssid: ownedBSSID, networks: networks) != nil { return "已连接" }
    if recognizedHotspot == true { return "已连接" }
    if controlIssue == .occupied { return "其他应用占用" }
    if controlIssue == .unavailable { return "控制权获取失败" }
    switch phase {
    case .activating, .joining, .confirming: return "连接中"
    case .browsing: return "查找中"
    case .retrying: return "暂不可用，重试中"
    case .failed: return "暂不可用"
    case .waitingForNetwork: return "准备中"
    case .suspended: return "已暂停"
    case .disabled, .networkAvailable: break
    }
    if recognizedHotspot == false { return "未连接" }
    if networks.contains(where: { ($0.ssid != nil && $0.ssid != campusSSID) || ($0.ssid == nil && $0.bssid != nil) }) {
        return "无法识别"
    }
    return "未连接"
}

public enum CampusSearchResult: Equatable, Sendable {
    case connected
    case absent
    case associationFailed
    case failed(String)
    case cancelled
}

@MainActor
public final class WiFiRecovery {
    private var inFlightTask: Task<Void, Never>?
    private var nextAttempt = ContinuousClock.now
    private var cancellation = CancellationSignal()
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    public var onResult: ((CampusSearchResult) -> Void)?
    public var canRequest: Bool { inFlightTask == nil && ContinuousClock.now >= nextAttempt }

    public init() {}

    public func cancel() {
        cancellation.cancel()
        inFlightTask?.cancel()
    }

    public func waitUntilIdle() async {
        if inFlightTask == nil { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    public func request(
        snapshot: EngineSnapshot,
        ownedHotspotSSID: String?,
        campusSSID: String = AppConstants.defaultCampusSSID
    ) {
        let current = snapshot.read()
        guard inFlightTask == nil, ContinuousClock.now >= nextAttempt,
              maySelectCampus(networks: current.networks, permissionAuthorized: current.permissionAuthorized,
                              ownedHotspotSSID: ownedHotspotSSID) else { return }
        cancellation = CancellationSignal()
        let cancellation = cancellation
        let generation = current.generation
        let stillNeeded: @Sendable () -> Bool = {
            let current = snapshot.read()
            return !cancellation.isCancelled() && !Task.isCancelled && current.generation == generation && maySelectCampus(
                networks: current.networks, permissionAuthorized: current.permissionAuthorized,
                ownedHotspotSSID: ownedHotspotSSID)
        }
        inFlightTask = Task { @MainActor [weak self] in
            let result = await Self.connect(
                ownedHotspotSSID: ownedHotspotSSID,
                campusSSID: campusSSID,
                stillNeeded: stillNeeded
            )
            guard let self else { return }
            self.inFlightTask = nil
            let waiters = self.idleWaiters
            self.idleWaiters.removeAll()
            waiters.forEach { $0.resume() }
            self.nextAttempt = cancellation.isCancelled()
                ? .now
                : .now.advanced(by: .seconds(ownedHotspotSSID != nil ? 90 : 15))
            guard !cancellation.isCancelled() else { return }
            self.onResult?(result)
        }
    }

    nonisolated private static func connect(
        ownedHotspotSSID: String?,
        campusSSID: String,
        stillNeeded: @escaping @Sendable () -> Bool
    ) async -> CampusSearchResult {
        await Task.detached(priority: .utility) {
            guard stillNeeded() else { return CampusSearchResult.cancelled }
            let client = CWWiFiClient()
            let interfaces = client.interfaces() ?? []
            guard !interfaces.isEmpty else { return .failed("未找到 Wi-Fi 接口，请检查系统网络设置。") }
            func mayReplaceLinks() -> Bool {
                interfaces.allSatisfy { interface in
                    if let ssid = interface.ssid() { return ssid == ownedHotspotSSID }
                    return interface.bssid() == nil
                }
            }
            var scanned = false
            var scanFailure = false
            var associationFailure = false
            for interface in interfaces {
                guard stillNeeded(), mayReplaceLinks() else { return .cancelled }
                do {
                    if !interface.powerOn() {
                        try interface.setPower(true)
                        for _ in 0..<15 {
                            guard stillNeeded(), mayReplaceLinks() else { return .cancelled }
                            try? await Task.sleep(for: .milliseconds(100))
                        }
                    }
                    guard stillNeeded(), mayReplaceLinks() else { return .cancelled }
                    let replacingHotspot = ownedHotspotSSID != nil
                    let candidates = try interface.scanForNetworks(withSSID: Data(campusSSID.utf8))
                        .filter {
                            $0.ssid == campusSSID
                                && $0.supportsSecurity(.none)
                                && !$0.ibss
                                && campusCandidateEligible(rssi: $0.rssiValue, replacingHotspot: replacingHotspot)
                        }
                        .sorted { $0.rssiValue > $1.rssiValue }
                    scanned = true
                    for network in candidates {
                        guard stillNeeded(), mayReplaceLinks() else { return .cancelled }
                        do {
                            try interface.associate(to: network, password: nil)
                            return .connected
                        } catch {
                            associationFailure = true
                        }
                    }
                } catch {
                    scanFailure = true
                }
            }
            guard stillNeeded() else { return .cancelled }
            if associationFailure { return .associationFailed }
            if scanFailure || !scanned { return .failed("扫描校园 Wi-Fi 失败；请检查系统 Wi-Fi 设置与定位权限。") }
            return .absent
        }.value
    }
}
