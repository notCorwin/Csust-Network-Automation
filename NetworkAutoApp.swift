import HotspotCore
import AppKit
import Combine
import CoreLocation
import CoreWLAN
import CryptoKit
import Darwin
import Foundation
import Network
import ObjectiveC
import ServiceManagement
import Symbols
import UserNotifications

private let appDisplayName = "Csust-Network-Automation"
private let campusSSID = "CSUST-Student"
private let campusLoginURL = URL(string: "https://login.csust.edu.cn:802/eportal/portal/login")!
private let loginRequestTimeoutSecs: TimeInterval = 15
private let configDefaultsKey = "config.v1"
private let stateDefaultsKey = "state.v1"
private let settingsWindowIdentifier = "com.nowaywastaken.networkauto.settings"

struct AppError: Error, LocalizedError, Sendable, Equatable {
    let message: String

    var errorDescription: String? { message }
}

struct AppConfig: Codable, Equatable, Sendable {
    var username: String
    var password: String

    static let `default` = AppConfig(
        username: "",
        password: ""
    )

    private enum CodingKeys: String, CodingKey { case username, password }

    init(
        username: String,
        password: String
    ) {
        self.username = username
        self.password = password
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        password = try container.decodeIfPresent(String.self, forKey: .password) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(username, forKey: .username)
        try container.encode(password, forKey: .password)
    }

    func validationError() -> String? {
        if username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty {
            return "账号或密码为空，请在设置中补充。"
        }

        return nil
    }
}

struct AppPaths: Sendable {
    let data: URL
    let legacyConfig: URL
    let legacyState: URL
    let logs: URL

    init(fileManager: FileManager = .default) {
        let home = fileManager.homeDirectoryForCurrentUser
        data = home.appendingPathComponent("Library/Application Support/csust-auto-login", isDirectory: true)
        legacyConfig = data.appendingPathComponent("config.json")
        legacyState = data.appendingPathComponent("state.json")
        logs = home.appendingPathComponent("Library/Logs/csust-auto-login", isDirectory: true)
    }

    init(data: URL, legacyConfig: URL, legacyState: URL, logs: URL) {
        self.data = data
        self.legacyConfig = legacyConfig
        self.legacyState = legacyState
        self.logs = logs
    }
}

private func ensurePrivateDirectory(_ url: URL) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
}

enum AppInstanceLockError: Error, LocalizedError {
    case alreadyRunning
    case openFailed(String)
    case lockFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning: return "Csust-Network-Automation 已经在运行。"
        case .openFailed(let message): return "无法打开运行锁：\(message)"
        case .lockFailed(let message): return "无法取得运行锁：\(message)"
        }
    }
}

final class AppInstanceLock: @unchecked Sendable {
    let descriptor: Int32

    init(path: URL) throws {
        // Retry if the lock file was unlinked or replaced between open() and flock().
        for _ in 0..<3 {
            let descriptor = Darwin.open(path.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
            guard descriptor >= 0 else {
                throw AppInstanceLockError.openFailed(String(cString: strerror(errno)))
            }
            var info = stat()
            guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid() else {
                close(descriptor)
                throw AppInstanceLockError.lockFailed("运行锁文件类型或权限无效")
            }
            if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
                let error = errno
                close(descriptor)
                if error == EWOULDBLOCK || error == EAGAIN {
                    throw AppInstanceLockError.alreadyRunning
                }
                throw AppInstanceLockError.lockFailed(String(cString: strerror(error)))
            }
            var pathInfo = stat()
            if lstat(path.path, &pathInfo) == 0,
               pathInfo.st_dev == info.st_dev,
               pathInfo.st_ino == info.st_ino {
                self.descriptor = descriptor
                return
            }
            close(descriptor)
        }
        throw AppInstanceLockError.lockFailed("运行锁状态不稳定")
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

final class CancellationSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func isCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

}

final class EngineSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var networks: [WiFiNetwork] = []
    private var permissionAuthorized = false
    private var internetConnected = false
    private var generation: UInt64 = 0

    func update(networks: [WiFiNetwork], permissionAuthorized: Bool) {
        lock.lock()
        if self.networks != networks {
            internetConnected = false
            generation &+= 1
        }
        self.networks = networks
        self.permissionAuthorized = permissionAuthorized
        lock.unlock()
    }

    func updateConnectivity(_ connected: Bool) {
        lock.lock()
        internetConnected = connected
        lock.unlock()
    }

    func invalidateNetwork() {
        lock.lock()
        generation &+= 1
        internetConnected = false
        lock.unlock()
    }

    func read() -> (networks: [WiFiNetwork], permissionAuthorized: Bool, internetConnected: Bool, generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        return (networks, permissionAuthorized, internetConnected, generation)
    }
}

final class AppStore: @unchecked Sendable {
    private let defaults: UserDefaults
    let paths: AppPaths
    private let lock = NSLock()
    private var storedConfig: AppConfig
    private var configError: String?
    private var passwordFallbackURL: URL { paths.data.appendingPathComponent("password") }

    init(
        defaults: UserDefaults = .standard,
        paths: AppPaths = AppPaths()
    ) {
        self.defaults = defaults
        self.paths = paths
        let legacyPasswordURL = paths.data.appendingPathComponent("password")

        var loadedConfig: AppConfig
        if let data = defaults.data(forKey: configDefaultsKey) {
            do {
                loadedConfig = try JSONDecoder().decode(AppConfig.self, from: data)
                configError = nil
            } catch {
                loadedConfig = .default
                configError = "配置格式错误，无法读取已保存设置。"
            }
        } else if let data = try? Data(contentsOf: paths.legacyConfig) {
            do {
                loadedConfig = try JSONDecoder().decode(AppConfig.self, from: data)
                configError = nil
            } catch {
                loadedConfig = .default
                configError = "旧配置格式错误，无法完成迁移。"
            }
        } else {
            loadedConfig = .default
            configError = nil
        }

        if configError == nil, loadedConfig.password.isEmpty,
           let data = try? Data(contentsOf: legacyPasswordURL),
           let password = String(data: data, encoding: .utf8),
           !password.isEmpty {
            loadedConfig.password = password
        }
        storedConfig = loadedConfig
        if configError == nil, let encoded = try? JSONEncoder().encode(loadedConfig) {
            defaults.set(encoded, forKey: configDefaultsKey)
            try? FileManager.default.removeItem(at: paths.legacyConfig)
            try? FileManager.default.removeItem(at: passwordFallbackURL)
        }
    }

    func config() -> Result<AppConfig, AppError> {
        lock.lock()
        defer { lock.unlock() }
        if let configError {
            return .failure(AppError(message: configError))
        }
        return .success(storedConfig)
    }

    func effectiveConfig() -> Result<AppConfig, AppError> {
        switch config() {
        case .failure(let error): return .failure(error)
        case .success(let config):
            if let error = config.validationError() {
                return .failure(AppError(message: error))
            }
            return .success(config)
        }
    }

    func saveConfig(_ config: AppConfig) throws {
        guard config.validationError() == nil else {
            throw StoreError.invalidConfig
        }
        let encoded = try JSONEncoder().encode(config)
        lock.lock()
        defer { lock.unlock() }
        storedConfig = config
        configError = nil
        defaults.set(encoded, forKey: configDefaultsKey)
        try? FileManager.default.removeItem(at: passwordFallbackURL)
    }

    func loadState() -> AppState {
        lock.lock()
        defer { lock.unlock() }
        if let data = defaults.data(forKey: stateDefaultsKey),
           var state = try? JSONDecoder().decode(AppState.self, from: data) {
            state.checking = false
            return state
        }
        if let data = try? Data(contentsOf: paths.legacyState),
           var state = try? JSONDecoder().decode(AppState.self, from: data) {
            state.checking = false
            if let encoded = try? JSONEncoder().encode(state) {
                defaults.set(encoded, forKey: stateDefaultsKey)
            }
            return state
        }
        return AppState()
    }

    func saveState(_ state: AppState) {
        lock.lock()
        defer { lock.unlock() }
        if let encoded = try? JSONEncoder().encode(state) {
            defaults.set(encoded, forKey: stateDefaultsKey)
        }
    }

    enum StoreError: LocalizedError {
        case invalidConfig

        var errorDescription: String? {
            switch self {
            case .invalidConfig: return "配置校验失败。"
            }
        }
    }
}

struct AppState: Codable, Equatable, Sendable {
    var phase = ""
    var detail = ""
    var network = ""
    var route = ""
    var checkedAt: Int64 = 0
    var checking = false
    var lastSuccess: Int64?
    var failureSince: Int64?
    var notified = false
    var credentialsBlocked = false
    var configKey = ""
    var attempt: UInt32 = 0

    private enum CodingKeys: String, CodingKey {
        case phase, detail, network, route
        case checkedAt = "checked_at"
        case checking
        case lastSuccess = "last_success"
        case failureSince = "failure_since"
        case notified
        case credentialsBlocked = "credentials_blocked"
        case configKey = "config_key"
        case attempt
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        phase = try container.decodeIfPresent(String.self, forKey: .phase) ?? ""
        detail = try container.decodeIfPresent(String.self, forKey: .detail) ?? ""
        network = try container.decodeIfPresent(String.self, forKey: .network) ?? ""
        route = try container.decodeIfPresent(String.self, forKey: .route) ?? ""
        checkedAt = try container.decodeIfPresent(Int64.self, forKey: .checkedAt) ?? 0
        checking = try container.decodeIfPresent(Bool.self, forKey: .checking) ?? false
        lastSuccess = try container.decodeIfPresent(Int64.self, forKey: .lastSuccess)
        failureSince = try container.decodeIfPresent(Int64.self, forKey: .failureSince)
        notified = try container.decodeIfPresent(Bool.self, forKey: .notified) ?? false
        credentialsBlocked = try container.decodeIfPresent(Bool.self, forKey: .credentialsBlocked) ?? false
        if let key = try? container.decode(String.self, forKey: .configKey) {
            configKey = key
        } else if let numeric = try? container.decode(UInt64.self, forKey: .configKey) {
            configKey = String(numeric)
        }
        attempt = try container.decodeIfPresent(UInt32.self, forKey: .attempt) ?? 0
    }

    mutating func transition(phase: String, detail: String, now: Int64) -> Bool {
        let changed = self.phase != phase || self.detail != detail
        let needsAction = phase == "credentials" || phase == "config_error"
        if needsAction && self.phase != phase {
            notified = false
        }
        self.phase = phase
        self.detail = detail
        checkedAt = now
        if phase == "online" || phase == "outside" || phase == "offline" {
            failureSince = nil
            notified = false
        }
        if phase == "online" {
            lastSuccess = now
        }
        if ["credentials", "config_error", "retry"].contains(phase) {
            let since = failureSince ?? now
            failureSince = since
            let shouldNotify = !notified && (needsAction || now - since >= 120)
            if shouldNotify {
                notified = true
            }
        }
        return changed
    }
}

struct WiFiNetwork: Equatable, Sendable {
    let interfaceName: String
    let ssid: String?
    let bssid: String?
    let ip: String?

    var key: String {
        "\(interfaceName) / \(bssid ?? "未知 BSSID") / \(ip ?? "未分配 IPv4")"
    }
}

func usableIPv4(_ value: String) -> Bool {
    let parts = value.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) else { return false }
    let octets = parts.compactMap { UInt8($0) }
    guard octets.count == 4 else { return false }
    if octets[0] == 0 || octets[0] >= 224 || octets[0] == 127 { return false }
    if octets[0] == 169 && octets[1] == 254 { return false }
    if octets[0] == 198 && (octets[1] == 18 || octets[1] == 19) { return false }
    return true
}

func selectNetwork(_ networks: [WiFiNetwork]) -> WiFiNetwork? {
    networks.first { $0.ssid == campusSSID }
}

func campusConnectionStatus(networks: [WiFiNetwork], permissionAuthorized: Bool, state: AppState) -> String {
    guard permissionAuthorized else { return "需要定位权限" }
    guard let network = selectNetwork(networks) else { return "未连接" }
    guard state.network == network.key else { return "未登录" }
    switch state.phase {
    case "credentials": return state.checking ? "登录中" : "认证失败"
    case "config_error": return state.checking ? "登录中" : "设置有误"
    case "online": return "已登录"
    default: return state.checking ? "登录中" : "未登录"
    }
}

func shouldFallbackForAuthentication(_ state: AppState, campus: WiFiNetwork?) -> Bool {
    guard !state.checking, let campus, state.network == campus.key else { return false }
    return state.phase == "credentials" || state.phase == "config_error" || (state.phase == "retry" && state.attempt >= 3)
}

private func interfaceIPv4Addresses() -> [String: String] {
    var result: [String: String] = [:]
    var addressPointer: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&addressPointer) == 0, let first = addressPointer else { return result }
    defer { freeifaddrs(first) }

    var current: UnsafeMutablePointer<ifaddrs>? = first
    while let pointer = current {
        defer { current = pointer.pointee.ifa_next }
        guard let address = pointer.pointee.ifa_addr,
              address.pointee.sa_family == sa_family_t(AF_INET) else { continue }
        var ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard let text = buffer.withUnsafeMutableBufferPointer({ bufferPointer in
            inet_ntop(AF_INET, &ipv4, bufferPointer.baseAddress, socklen_t(INET_ADDRSTRLEN))
        }) else { continue }
        result[String(cString: text)] = String(cString: pointer.pointee.ifa_name)
    }
    return result.reduce(into: [:]) { output, item in
        if output[item.value] == nil, usableIPv4(item.key) {
            output[item.value] = item.key
        }
    }
}

final class WiFiMonitor: NSObject, CWEventDelegate, @unchecked Sendable {
    private let client = CWWiFiClient.shared()
    private let lock = NSLock()
    private var monitoring = false
    var onChange: (() -> Void)?

    func start() {
        lock.lock()
        monitoring = true
        lock.unlock()
        registerEvents()
        onChange?()
    }

    func stop() {
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

    func networks() -> [WiFiNetwork] {
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

    // CoreWLAN does not expose this flag publicly. Treat an unavailable or
    // ambiguous saved profile as unknown and never use it to control Wi-Fi.
    static func personalHotspotProfile(networks: [WiFiNetwork]) -> Bool? {
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
            guard String(cString: returnType) == "B" || String(cString: returnType) == "c" else { continue }
            typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
            let getter = unsafeBitCast(method_getImplementation(method), to: Getter.self)
            results.append(getter(profile, selector))
        }
        guard results.count == 1 else { return nil }
        return results[0]
    }

    func ssidDidChangeForWiFiInterface(withName interfaceName: String) { onChange?() }
    func bssidDidChangeForWiFiInterface(withName interfaceName: String) { onChange?() }
    func linkDidChangeForWiFiInterface(withName interfaceName: String) { onChange?() }
    func powerStateDidChangeForWiFiInterface(withName interfaceName: String) { onChange?() }

    func clientConnectionInterrupted() { scheduleResubscribe(); onChange?() }
    func clientConnectionInvalidated() { scheduleResubscribe(); onChange?() }
}

struct PathSignature: Equatable, Sendable {
    let satisfied: Bool
    let usesWiFi: Bool
    let usesEthernet: Bool
    let isExpensive: Bool
    let interfaces: [String]
    let gateways: [String]

    init(satisfied: Bool, usesWiFi: Bool, usesEthernet: Bool, isExpensive: Bool,
         interfaces: [String], gateways: [String]) {
        self.satisfied = satisfied
        self.usesWiFi = usesWiFi
        self.usesEthernet = usesEthernet
        self.isExpensive = isExpensive
        self.interfaces = interfaces
        self.gateways = gateways
    }

    init(_ path: NWPath) {
        self.satisfied = path.status == .satisfied
        self.usesWiFi = path.usesInterfaceType(.wifi)
        self.usesEthernet = path.usesInterfaceType(.wiredEthernet)
        self.isExpensive = path.isExpensive
        self.interfaces = path.availableInterfaces.map(\.name).sorted()
        self.gateways = path.gateways.map(\.debugDescription).sorted()
    }
}

func shouldPauseCampusSearchForHotspot(enabled: Bool, phase: HotspotPhase) -> Bool {
    guard enabled else { return false }
    switch phase {
    case .browsing, .activating, .joining, .confirming, .retrying:
        return true
    case .disabled, .suspended, .waitingForNetwork, .networkAvailable, .failed:
        return false
    }
}

func fallbackCooldownSeconds(consecutiveFallbacks: Int) -> Int {
    let exponent = min(max(0, consecutiveFallbacks - 1), 3)
    return min(120 * (1 << exponent), 600)
}

func campusCandidateEligible(rssi: Int, replacingHotspot: Bool) -> Bool {
    replacingHotspot ? rssi >= -72 : true
}

// Only a link established by this coordinator may be replaced by campus Wi-Fi.
func maySelectCampus(networks: [WiFiNetwork], permissionAuthorized: Bool, ownedHotspotSSID: String?) -> Bool {
    guard permissionAuthorized else { return false }
    return networks.allSatisfy { network in
        if let ssid = network.ssid { return ssid == ownedHotspotSSID }
        return network.bssid == nil && network.ip == nil
    }
}

func verifiedHotspotSSID(_ ssid: String?, bssid: String?, networks: [WiFiNetwork]) -> String? {
    guard let ssid, let bssid, networks.contains(where: { $0.ssid == ssid && $0.bssid == bssid }) else { return nil }
    return ssid
}

// A prior confirmation is useful across launches only while both live identifiers
// still match. Keep this bounded: network names and access points can be reused.
struct ConfirmedHotspot: Codable, Equatable {
    let ssid: String
    let bssid: String
    let confirmedAt: Date
}

final class HotspotIdentityCache {
    private let defaults: UserDefaults
    private let key = "confirmedHotspot.v1"
    private let lifetime: TimeInterval = 30 * 24 * 60 * 60
    private var saved: ConfirmedHotspot?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key) { saved = try? JSONDecoder().decode(ConfirmedHotspot.self, from: data) }
    }

    func remember(ssid: String, bssid: String, now: Date = Date()) {
        let identity = ConfirmedHotspot(ssid: ssid, bssid: bssid, confirmedAt: now)
        guard !ssid.isEmpty, !bssid.isEmpty, let data = try? JSONEncoder().encode(identity) else { return }
        saved = identity
        defaults.set(data, forKey: key)
    }

    func matching(networks: [WiFiNetwork], now: Date = Date()) -> ConfirmedHotspot? {
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

enum WiFiControlIssue {
    case occupied, unavailable
}

func hotspotRecognition(profile: Bool?, cachedMatch: Bool) -> Bool? {
    profile ?? (cachedMatch ? true : nil)
}

func acceptsHotspotProfileResult(token: UInt, currentToken: UInt, authorized: Bool,
                                 queried: [WiFiNetwork], current: [WiFiNetwork]) -> Bool {
    token == currentToken && authorized && queried == current
}

func personalHotspotStatus(networks: [WiFiNetwork], permissionAuthorized: Bool,
                           ownedSSID: String?, ownedBSSID: String?, sleeping: Bool,
                           controlIssue: WiFiControlIssue?, phase: HotspotPhase,
                           recognizedHotspot: Bool? = nil) -> String {
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

enum CampusSearchResult: Equatable {
    case connected
    case absent
    case associationFailed
    case failed(String)
    case cancelled
}

@MainActor
final class WiFiRecovery {
    private let queue = DispatchQueue(label: "com.nowaywastaken.networkauto.wifi-recovery", qos: .utility)
    private var inFlight = false
    private var nextAttempt = ContinuousClock.now
    private var cancellation = CancellationSignal()
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    var onResult: ((CampusSearchResult) -> Void)?
    var canRequest: Bool { !inFlight && ContinuousClock.now >= nextAttempt }

    func cancel() { cancellation.cancel() }

    func waitUntilIdle() async {
        if !inFlight { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    func request(snapshot: EngineSnapshot, ownedHotspotSSID: String?) {
        let current = snapshot.read()
        guard !inFlight, ContinuousClock.now >= nextAttempt,
              maySelectCampus(networks: current.networks, permissionAuthorized: current.permissionAuthorized,
                              ownedHotspotSSID: ownedHotspotSSID) else { return }
        inFlight = true
        cancellation = CancellationSignal()
        let cancellation = cancellation
        let generation = current.generation
        queue.async { [weak self] in
            let stillNeeded: @Sendable () -> Bool = {
                let current = snapshot.read()
                return !cancellation.isCancelled() && current.generation == generation && maySelectCampus(
                    networks: current.networks, permissionAuthorized: current.permissionAuthorized,
                    ownedHotspotSSID: ownedHotspotSSID)
            }
            let result = Self.connect(ownedHotspotSSID: ownedHotspotSSID, stillNeeded: stillNeeded)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.inFlight = false
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
    }

    nonisolated private static func connect(ownedHotspotSSID: String?, stillNeeded: @Sendable () -> Bool) -> CampusSearchResult {
        guard stillNeeded() else { return .cancelled }
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
                        Thread.sleep(forTimeInterval: 0.1)
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
                    } catch { associationFailure = true }
                }
            } catch { scanFailure = true }
        }
        guard stillNeeded() else { return .cancelled }
        if associationFailure { return .associationFailed }
        if scanFailure || !scanned { return .failed("扫描校园 Wi-Fi 失败；请检查系统 Wi-Fi 设置与定位权限。") }
        return .absent
    }
}

enum AuthOutcome: Equatable {
    case online
    case credentials
    case retry(String)
    case networkChanged
}

private final class LoginSessionDelegate: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var storedRedirectLocation: String?

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        storedRedirectLocation = response.value(forHTTPHeaderField: "Location")
        lock.unlock()
        completionHandler(nil)
    }

    func redirectLocation() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storedRedirectLocation
    }
}

private struct HTTPResult {
    let statusCode: Int
    let body: Data
    let redirectLocation: String?
}

private final class HTTPResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var body = Data()
    private var statusCode = 0
    private var requestError: Error?

    func set(data: Data, statusCode: Int, error: Error?) {
        lock.lock()
        self.body = data
        self.statusCode = statusCode
        self.requestError = error
        lock.unlock()
    }

    func value() -> (body: Data, statusCode: Int, error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        return (body, statusCode, requestError)
    }
}

enum LoginService {
    static func login(
        config: AppConfig,
        ip: String,
        stillConnected: @escaping @Sendable () -> Bool,
        serverURL: URL = campusLoginURL,
        systemProxy: URL? = nil
    ) -> (AuthOutcome, String) {
        if let error = config.validationError() {
            return (.retry(error), "")
        }
        let account = ",0,\(config.username)"
        let parameters = [
            ("callback", "dr1003"),
            ("login_method", "1"),
            ("user_account", account),
            ("user_password", config.password),
            ("wlan_user_ip", ip),
            ("wlan_user_ipv6", ""),
            ("wlan_user_mac", "000000000000"),
            ("wlan_ac_ip", ""),
            ("wlan_ac_name", ""),
            ("jsVersion", "4.2.1"),
            ("terminal_type", "1"),
            ("lang", "zh-cn"),
            ("v", "8207")
        ]
        let referer = originURLString(serverURL)
        var errors: [String] = []
        var lastRoute = ""

        for route in routeNames() {
            if !stillConnected() { return (.networkChanged, lastRoute) }
            lastRoute = route
            guard let request = makeRequest(
                url: serverURL,
                parameters: parameters,
                referer: referer
            ) else {
                errors.append("认证地址无效")
                continue
            }
            switch perform(
                request: request,
                route: route,
                shouldContinue: stillConnected,
                systemProxy: systemProxy
            ) {
            case .failure(let error):
                errors.append("\(routeLabel(route))：\(error.message)")
            case .success(let response):
                if !stillConnected() { return (.networkChanged, lastRoute) }
                let outcome: AuthOutcome
                if (300...399).contains(response.statusCode) {
                    outcome = parseResponse(response.redirectLocation ?? "")
                } else if (200...299).contains(response.statusCode),
                          let text = String(data: response.body, encoding: .utf8) {
                    outcome = parseResponse(text)
                } else if (200...299).contains(response.statusCode) {
                    errors.append("\(routeLabel(route))：响应读取失败")
                    continue
                } else {
                    errors.append("\(routeLabel(route))：认证服务器返回 HTTP \(response.statusCode)")
                    continue
                }

                switch outcome {
                case .credentials:
                    return (.credentials, lastRoute)
                case .online:
                    return (.online, lastRoute)
                case .retry(let detail):
                    errors.append("\(routeLabel(route))：\(detail)")
                case .networkChanged:
                    return (.networkChanged, lastRoute)
                }
            }
        }
        return (
            .retry(errors.isEmpty ? "认证失败，将立即重试。" : errors.joined(separator: "；")),
            lastRoute
        )
    }

    private static func makeRequest(
        url: URL,
        parameters: [(String, String)],
        referer: String
    ) -> URLRequest? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = parameters.map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let requestURL = components.url else { return nil }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func perform(
        request: URLRequest,
        route: String,
        shouldContinue: @escaping @Sendable () -> Bool,
        systemProxy: URL?,
        timeout: TimeInterval = loginRequestTimeoutSecs
    ) -> Result<HTTPResult, AppError> {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.waitsForConnectivity = false
        sessionConfiguration.timeoutIntervalForRequest = timeout
        sessionConfiguration.timeoutIntervalForResource = timeout
        sessionConfiguration.httpShouldSetCookies = false
        if route == "direct" {
            sessionConfiguration.connectionProxyDictionary = [
                "HTTPEnable": 0,
                "HTTPSEnable": 0
            ]
        } else if route == "system", let systemProxy,
                  let proxy = URLComponents(url: systemProxy, resolvingAgainstBaseURL: false),
                  let host = proxy.host,
                  let scheme = proxy.scheme?.lowercased() {
            let port = proxy.port ?? (scheme == "https" ? 443 : 80)
            sessionConfiguration.connectionProxyDictionary = [
                "HTTPEnable": 1,
                "HTTPProxy": host,
                "HTTPPort": port,
                "HTTPSEnable": 1,
                "HTTPSProxy": host,
                "HTTPSPort": port
            ]
        } else if route != "system" {
            return .failure(AppError(message: "代理地址无效"))
        }

        // nil keeps URLSession on the macOS system proxy/PAC path.
        let delegate = LoginSessionDelegate()
        let session = URLSession(configuration: sessionConfiguration, delegate: delegate, delegateQueue: nil)
        let semaphore = DispatchSemaphore(value: 0)
        let responseBox = HTTPResponseBox()
        let task = session.dataTask(with: request) { data, response, error in
            responseBox.set(
                data: data ?? Data(),
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0,
                error: error
            )
            semaphore.signal()
        }
        task.resume()
        let deadline = Date().addingTimeInterval(timeout + 1)
        while semaphore.wait(timeout: .now() + .milliseconds(100)) == .timedOut {
            if !shouldContinue() {
                task.cancel()
                session.invalidateAndCancel()
                return .failure(AppError(message: "检查已停止"))
            }
            if Date() >= deadline {
                task.cancel()
                session.invalidateAndCancel()
                return .failure(AppError(message: "连接超时"))
            }
        }
        session.finishTasksAndInvalidate()
        let response = responseBox.value()
        if let redirectLocation = delegate.redirectLocation() {
            return .success(HTTPResult(
                statusCode: response.statusCode == 0 ? 302 : response.statusCode,
                body: response.body,
                redirectLocation: redirectLocation
            ))
        }
        if let requestError = response.error {
            return .failure(AppError(message: connectionError(requestError)))
        }
        if response.statusCode == 0 {
            return .failure(AppError(message: "连接中断"))
        }
        return .success(HTTPResult(statusCode: response.statusCode, body: response.body, redirectLocation: delegate.redirectLocation()))
    }

    private static func connectionError(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return "连接超时"
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet:
                return "无法建立连接（请检查网络或代理是否启动）"
            default: return "连接中断"
            }
        }
        return "连接中断"
    }

    private static func originURL(_ value: URL) -> URL? {
        guard var origin = URLComponents(url: value, resolvingAgainstBaseURL: false) else { return nil }
        origin.path = "/"
        origin.query = nil
        origin.fragment = nil
        return origin.url
    }

    private static func originURLString(_ value: URL) -> String {
        originURL(value)?.absoluteString ?? ""
    }
}

func parseResponse(_ text: String) -> AuthOutcome {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    var jsonText = trimmed
    if let open = trimmed.firstIndex(of: "("),
       trimmed[..<open].trimmingCharacters(in: .whitespacesAndNewlines) == "dr1003",
       let close = trimmed.lastIndex(of: ")"), close > open {
        jsonText = String(trimmed[trimmed.index(after: open)..<close]).trimmingCharacters(in: .whitespacesAndNewlines)
        if jsonText.hasSuffix(";") { jsonText.removeLast() }
    }

    let object: [String: Any]? = (try? JSONSerialization.jsonObject(with: Data(jsonText.utf8))) as? [String: Any]
    let message = ((object?["msg"] as? String) ?? trimmed).trimmingCharacters(in: .whitespacesAndNewlines)
    let lower = message.lowercased()
    let credentialWords = [
        "密码错误", "账号错误", "帐号错误", "账号不存在", "用户不存在",
        "用户名或密码错误", "账号已欠费", "password error", "incorrect password",
        "wrong password", "invalid password", "invalid credentials",
        "username or password", "account does not exist", "user not found"
    ]
    if credentialWords.contains(where: { lower.contains($0) }) {
        return .credentials
    }
    let normalized = message.trimmingCharacters(in: CharacterSet(charactersIn: "!.！"))
    let online = message.contains("已经在线") || message.contains("已在线") || [
        "already online", "user already online", "user is already online"
    ].contains(normalized.lowercased())
    let result = object?["result"]
    let success = (result as? NSNumber)?.intValue == 1 || (result as? String) == "1"
    if success || online || trimmed.contains("Dr.COMWebLoginID_3.htm") {
        return .online
    }
    if trimmed.contains("认证超时") {
        return .retry("认证超时，将自动重试。")
    }
    if trimmed.contains("Dr.COMWebLoginID_2.htm") {
        return .retry("认证被拒绝，请检查认证参数。")
    }
    return .retry("未收到可确认的认证结果，将自动重试。")
}

private func routeLabel(_ route: String) -> String {
    switch route {
    case "direct": return "直连"
    case "system": return "系统代理"
    default: return "尚未选择"
    }
}

func routeNames() -> [String] { ["direct", "system"] }

func configFingerprint(_ config: AppConfig) -> String {
    let passwordDigest = SHA256.hash(data: Data(config.password.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
    let material = "\(config.username)\u{0}\(passwordDigest)"
    return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
}

final class LogStore: @unchecked Sendable {
    private let paths: AppPaths
    private let lock = NSLock()

    init(paths: AppPaths) { self.paths = paths }

    func append(state: AppState) {
        lock.lock()
        defer { lock.unlock() }
        do {
            try ensurePrivateDirectory(paths.logs)
            cleanup()
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone.current
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            let timestamp = formatter.string(from: Date())
            let file = paths.logs.appendingPathComponent("\(timestamp.prefix(10)).log")
            let line = "\(timestamp) [\(state.phase)] \(routeLabel(state.route)) / \(state.detail)\n"
            if !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
            try handle.close()
        } catch {
            NSLog("日志写入失败：%@", error.localizedDescription)
        }
    }

    private func cleanup() {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: paths.logs, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for entry in entries where entry.pathExtension == "log" {
            guard let values = try? entry.resourceValues(forKeys: [.contentModificationDateKey]),
                  let date = values.contentModificationDate,
                  Date().timeIntervalSince(date) > 7 * 86400 else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }
}

final class AutoLoginEngine: @unchecked Sendable {
    private let store: AppStore
    private let logger: LogStore
    private let snapshot: EngineSnapshot
    private let authenticate: @Sendable (AppConfig, String, @escaping @Sendable () -> Bool) -> (AuthOutcome, String)
    private let retryDelays: [TimeInterval]
    private let ipWaitTimeout: TimeInterval
    private let cancellation = CancellationSignal()
    private let queue = DispatchQueue(label: "com.nowaywastaken.networkauto.engine", qos: .utility)
    private var state: AppState
    private var running = false
    private var pending = false
    private var scheduled = false
    private var authenticatedGeneration: UInt64?
    private var stateGeneration: UInt64?
    private var lastLoggedPhase = ""
    private var lastLoggedDetail = ""
    private var lastLoggedAt: Int64 = 0
    var onUpdate: (@Sendable (AppState, Bool, UInt64) -> Void)?

    init(
        store: AppStore,
        snapshot: EngineSnapshot,
        retryDelays: [TimeInterval] = [1.0, 2.0],
        ipWaitTimeout: TimeInterval = 5.0,
        authenticate: @escaping @Sendable (AppConfig, String, @escaping @Sendable () -> Bool) -> (AuthOutcome, String) = { LoginService.login(config: $0, ip: $1, stillConnected: $2) },
        onUpdate: (@Sendable (AppState, Bool, UInt64) -> Void)? = nil
    ) {
        self.store = store
        self.logger = LogStore(paths: store.paths)
        self.snapshot = snapshot
        self.retryDelays = retryDelays
        self.ipWaitTimeout = ipWaitTimeout
        self.authenticate = authenticate
        self.state = store.loadState()
        self.onUpdate = onUpdate
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.requestLocked()
        }
    }

    func request() {
        queue.async { [weak self] in self?.requestLocked() }
    }

    func checkNow() {
        queue.async { [weak self] in
            guard let self, !self.cancellation.isCancelled() else { return }
            self.pending = false
            guard !self.running else { self.pending = true; return }
            self.running = true
            self.runCycle(manual: true)
            self.running = false
            self.schedulePendingIfNeeded()
        }
    }

    func stop() {
        cancellation.cancel()
    }

    private func requestLocked() {
        guard !cancellation.isCancelled() else { return }
        pending = true
        schedulePendingIfNeeded()
    }

    private func schedulePendingIfNeeded() {
        guard !cancellation.isCancelled(), !running, pending, !scheduled else { return }
        scheduled = true
        queue.async { [weak self] in
            guard let self, !self.cancellation.isCancelled() else { return }
            self.scheduled = false
            guard self.pending, !self.running else { return }
            self.pending = false
            self.running = true
            self.runCycle(manual: false)
            self.running = false
            self.schedulePendingIfNeeded()
        }
    }

    private func runCycle(manual: Bool) {
        let generation = snapshot.read().generation
        if stateGeneration != generation { state.attempt = 0 }
        stateGeneration = generation
        state.checking = true
        state.checkedAt = Int64(Date().timeIntervalSince1970)
        publish(state: state, shouldNotify: false)
        defer {
            state.checking = false
            store.saveState(state)
            publish(state: state, shouldNotify: false)
        }

        if manual {
            state.credentialsBlocked = false
            state.failureSince = nil
            state.notified = false
        }
        var useInternetEvidence = !manual
        while !cancellation.isCancelled() {
            let current = snapshot.read()
            if stateGeneration != current.generation {
                stateGeneration = current.generation
                state.attempt = 0
            }
            guard current.permissionAuthorized else {
                state.network = ""
                state.route = ""
                state.attempt = 0
                record(phase: "permission", detail: "需要定位权限才能读取 Wi‑Fi 名称，请在系统设置中允许本 App。")
                return
            }

            guard let network = selectNetwork(current.networks) else {
                state.network = ""
                state.route = ""
                state.attempt = 0
                record(phase: "outside", detail: "未连接校园网，等待网络变化。")
                return
            }
            guard let usableIP = waitForCampusIPv4(initial: network) else {
                let latest = snapshot.read()
                guard !cancellation.isCancelled(), latest.permissionAuthorized,
                      let stillCampus = selectNetwork(latest.networks) else { continue }
                state.network = stillCampus.key
                state.route = ""
                record(phase: "waiting_ip", detail: "已连接校园 Wi‑Fi，等待分配 IPv4 地址…")
                return
            }
            let activeNetwork = selectNetwork(snapshot.read().networks) ?? network
            let key = activeNetwork.key
            if state.network != key {
                state.network = key
                state.attempt = 0
                state.failureSince = nil
                state.notified = false
                useInternetEvidence = !manual
            }

            let generation = snapshot.read().generation
            stateGeneration = generation
            let stillConnected: @Sendable () -> Bool = { [snapshot, cancellation] in
                guard !cancellation.isCancelled() else { return false }
                let current = snapshot.read()
                return current.permissionAuthorized && current.generation == generation && selectNetwork(current.networks)?.key == key
            }
            if useInternetEvidence {
                if authenticatedGeneration == generation && snapshot.read().internetConnected && stillConnected() {
                    state.attempt = 0
                    record(phase: "online", detail: "互联网连接正常。")
                    return
                }
                useInternetEvidence = false
            }
            guard stillConnected() else { continue }

            let config: AppConfig
            switch store.effectiveConfig() {
            case .failure(let error):
                state.route = ""
                record(phase: "config_error", detail: error.message)
                return
            case .success(let value):
                config = value
            }

            let fingerprint = configFingerprint(config)
            if state.configKey != fingerprint {
                state.configKey = fingerprint
                state.credentialsBlocked = false
                state.failureSince = nil
                state.notified = false
            }
            if state.credentialsBlocked {
                record(phase: "credentials", detail: "认证信息被拒绝，请在设置中修改，或点击立即登录重试。")
                return
            }
            state.attempt = state.attempt == UInt32.max ? .max : state.attempt + 1
            let confirmingSession = authenticatedGeneration == generation && state.phase == "online"
            if !confirmingSession { state.phase = "login" }
            state.detail = confirmingSession ? "正在确认校园网会话…" : "正在登录校园网…"
            publish(state: state, shouldNotify: false)

            let outcome = authenticate(config, usableIP, stillConnected)
            guard stillConnected() else { continue }
            switch outcome.0 {
            case .online:
                authenticatedGeneration = generation
                state.attempt = 0
                state.route = outcome.1
                record(phase: "online", detail: confirmingSession ? "校园网会话有效。" : "登录成功或已经在线。")
                return
            case .credentials:
                state.route = outcome.1
                state.credentialsBlocked = true
                record(phase: "credentials", detail: "认证信息被拒绝，请在设置中修改，或点击立即登录重试。")
                return
            case .retry(let detail):
                state.route = outcome.1
                record(phase: "retry", detail: detail)
                // Bound one authentication round so the coordinator can fall back.
                if state.attempt >= 3 { return }
                let delayIndex = Int(state.attempt) - 1
                if delayIndex >= 0 && delayIndex < retryDelays.count {
                    sleepInterruptible(retryDelays[delayIndex], while: stillConnected)
                }
                continue
            case .networkChanged:
                state.route = outcome.1
                record(phase: "retry", detail: "网络已变化，重新检查。")
                continue
            }
        }
    }

    private func waitForCampusIPv4(initial: WiFiNetwork) -> String? {
        if let ip = initial.ip, usableIPv4(ip) { return ip }
        guard ipWaitTimeout > 0 else { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + ipWaitTimeout
        while !cancellation.isCancelled() && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.1)
            let current = snapshot.read()
            guard current.permissionAuthorized, let campus = selectNetwork(current.networks) else { return nil }
            if let ip = campus.ip, usableIPv4(ip) { return ip }
        }
        return nil
    }

    private func sleepInterruptible(_ duration: TimeInterval, while shouldContinue: () -> Bool) {
        guard duration > 0 else { return }
        let deadline = ProcessInfo.processInfo.systemUptime + duration
        while shouldContinue() && ProcessInfo.processInfo.systemUptime < deadline {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            Thread.sleep(forTimeInterval: min(0.1, max(0.01, remaining)))
        }
    }

    private func record(phase: String, detail: String) {
        let now = Int64(Date().timeIntervalSince1970)
        let oldNotified = state.notified
        let changed = state.transition(phase: phase, detail: detail, now: now)
        let shouldNotify = !oldNotified && state.notified
        let logWorthy = phase != lastLoggedPhase || detail != lastLoggedDetail || (now - lastLoggedAt) >= 60
        if changed && logWorthy {
            lastLoggedPhase = phase
            lastLoggedDetail = detail
            lastLoggedAt = now
            logger.append(state: state)
        }
        if changed || shouldNotify {
            store.saveState(state)
            publish(state: state, shouldNotify: shouldNotify)
        }
    }

    private func publish(state: AppState, shouldNotify: Bool) {
        onUpdate?(state, shouldNotify, stateGeneration ?? snapshot.read().generation)
    }
}

@MainActor
final class AppModel: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    static let shared = AppModel()

    @Published private(set) var config: AppConfig
    @Published private(set) var state: AppState
    @Published private(set) var internetStatus: InternetStatus = .unknown
    @Published private(set) var permissionStatus: CLAuthorizationStatus
    @Published private(set) var networks: [WiFiNetwork] = []
    @Published private(set) var diagnosticText = ""

    private let store: AppStore
    private let locationManager = CLLocationManager()
    private let wifiMonitor = WiFiMonitor()
    private let wifiRecovery = WiFiRecovery()
    private let wifiControlLock = WiFiControlLock()
    private var ownsWiFiControl = false
    private var wifiControlIssue: WiFiControlIssue?
    private let hotspot = HotspotController(discovery: RemoteHotspotDiscovery(), joiner: WiFiJoiner())
    private let hotspotIdentityCache = HotspotIdentityCache()
    private var ownedHotspotSSID: String?
    private var ownedHotspotBSSID: String?
    private var pendingHotspotSSID: String?
    private var lastRequestedHotspotSSID: String?
    private var hotspotSearchStartedAt: ContinuousClock.Instant?
    private var hotspotConfirmPollTask: Task<Void, Never>?
    private var profileRecognizesHotspot: Bool?
    private var profileLookupGeneration: UInt = 0
    private var profileLookupTime: ContinuousClock.Instant?
    private var campusAssociationFailures = 0
    private var consecutiveCampusFallbacks = 0
    private var fallbackUntil: ContinuousClock.Instant?
    private var wakeGraceUntil: ContinuousClock.Instant?
    private var wakeGraceTask: Task<Void, Never>?
    private var lastPathSignature: PathSignature?
    private var campusSearchTask: Task<Void, Never>?
    private var networkSleeping = false
    private var networkPathReady = false
    private var wifiRecoveryDetail = ""
    private let engineSnapshot = EngineSnapshot()
    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "com.nowaywastaken.networkauto.path")
    private var connectivityTimer: Timer?
    private let internetMonitor = ClashConnectivityMonitor()
    private var started = false
    private var manualCheckRequested = false

    private lazy var engine: AutoLoginEngine = {
        AutoLoginEngine(
            store: store,
            snapshot: engineSnapshot,
            onUpdate: { [weak self] state, shouldNotify, generation in
                Task { @MainActor [weak self] in
                    guard let self, self.engineSnapshot.read().generation == generation else { return }
                    self.apply(state: state, shouldNotify: shouldNotify)
                }
            }
        )
    }()

    private var isLocationAuthorized: Bool {
        permissionStatus == .authorized
    }

    override private init() {
        store = AppStore()
        switch store.config() {
        case .success(let config): self.config = config
        case .failure: self.config = .default
        }
        state = store.loadState()
        permissionStatus = locationManager.authorizationStatus
        super.init()
        locationManager.delegate = self
    }

    func start() {
        guard !started else { return }
        started = true
        state.phase = ""
        state.detail = ""
        requestNotificationPermission()
        registerLaunchAtLogin()

        hotspot.changed = { [weak self] in
            guard let self else { return }
            self.pendingHotspotSSID = self.hotspot.requestedSSID
            if let requested = self.hotspot.requestedSSID {
                self.lastRequestedHotspotSSID = requested
            }
            if self.hotspot.enabled {
                if self.hotspotSearchStartedAt == nil {
                    self.hotspotSearchStartedAt = ContinuousClock.now
                }
                self.wifiRecoveryDetail = self.hotspot.status
                self.diagnosticText = self.hotspot.status
            } else {
                self.hotspotSearchStartedAt = nil
            }
            self.updateHotspotConfirmPolling()
        }
        wifiRecovery.onResult = { [weak self] result in
            guard let self else { return }
            self.refreshNetworks()
            switch result {
            case .connected:
                self.campusAssociationFailures = 0
                self.ownedHotspotSSID = nil
                self.ownedHotspotBSSID = nil
                self.lastRequestedHotspotSSID = nil
                self.wifiRecoveryDetail = "已连接校园 Wi-Fi，正在检查校园网登录。"
                self.engine.request()
            case .absent:
                self.campusAssociationFailures = 0
                self.wifiRecoveryDetail = "未发现校园网，正在查找热点。"
                self.startHotspotIfAllowed()
            case .associationFailed:
                self.campusAssociationFailures += 1
                self.wifiRecoveryDetail = "连接校园 Wi-Fi 失败；请检查系统 Wi-Fi 设置。"
                if self.campusAssociationFailures >= 3 {
                    self.campusAssociationFailures = 0
                    self.enterCampusFallback()
                }
            case .failed(let message):
                self.wifiRecoveryDetail = message
                self.diagnosticText = message
            case .cancelled: break
            }
        }
        wifiMonitor.onChange = { [weak self] in
            Task { @MainActor [weak self] in self?.requestCheck() }
        }
        wifiMonitor.start()
        let workspaceNotifications = NSWorkspace.shared.notificationCenter
        workspaceNotifications.addObserver(self, selector: #selector(networkWillSleep(_:)), name: NSWorkspace.willSleepNotification, object: nil)
        workspaceNotifications.addObserver(self, selector: #selector(networkDidWake(_:)), name: NSWorkspace.didWakeNotification, object: nil)
        internetMonitor.onChange = { [weak self] status in
            guard let self else { return }
            self.internetStatus = status
            self.engineSnapshot.updateConnectivity(status.isConnected)
            if status == .dnsStalled || status == .offline { self.engine.request() }
            self.recoverWiFiIfNeeded()
        }
        internetMonitor.start()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let signature = PathSignature(path)
            Task { @MainActor [weak self] in
                guard let self else { return }
                let previousSignature = self.lastPathSignature
                self.lastPathSignature = signature
                self.networkPathReady = true
                let refreshed = self.wifiMonitor.networks()
                let wifiChanged = self.networks != refreshed
                let pathChanged = previousSignature != signature
                if pathChanged || wifiChanged || !signature.satisfied {
                    self.engineSnapshot.invalidateNetwork()
                    self.internetMonitor.reset(networkAvailable: signature.satisfied)
                }
                self.requestCheck()
            }
        }
        pathMonitor.start(queue: pathQueue)
        let connectivityTimer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.requestCheck()
            }
        }
        RunLoop.main.add(connectivityTimer, forMode: .common)
        self.connectivityTimer = connectivityTimer
        requestLocationPermissionIfNeeded()
        refreshNetworks()
        engine.start()
        if case .failure = store.effectiveConfig() {
            // 配置缺失或无效时直接打开设置，首次安装不需要再回到终端。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self else { return }
                guard case .failure = self.store.effectiveConfig() else { return }
                (NSApp.delegate as? AppDelegate)?.openSettingsWindow()
            }
        }
    }

    func stop() async {
        guard started else { return }
        started = false
        connectivityTimer?.invalidate()
        connectivityTimer = nil
        wakeGraceTask?.cancel()
        wakeGraceTask = nil
        hotspotConfirmPollTask?.cancel()
        hotspotConfirmPollTask = nil
        internetMonitor.stop()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        pathMonitor.cancel()
        wifiRecovery.cancel()
        campusSearchTask?.cancel()
        hotspot.setEnabled(false)
        wifiMonitor.stop()
        engine.stop()
        if ownsWiFiControl {
            await waitForIdleWithTimeout(.seconds(5))
            wifiControlLock.release()
            ownsWiFiControl = false
        }
    }

    private func waitForIdleWithTimeout(_ timeout: Duration) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var finished = false
            var timeoutTask: Task<Void, Never>?
            func complete() {
                guard !finished else { return }
                finished = true
                timeoutTask?.cancel()
                continuation.resume()
            }
            timeoutTask = Task {
                do { try await Task.sleep(for: timeout) } catch { return }
                NSLog("等待 Wi-Fi 控制器空闲超时，强制继续退出。")
                complete()
            }
            Task {
                await hotspot.waitUntilIdle()
                await wifiRecovery.waitUntilIdle()
                complete()
            }
        }
    }

    private func enterCampusFallback() {
        consecutiveCampusFallbacks += 1
        let cooldown = fallbackCooldownSeconds(consecutiveFallbacks: consecutiveCampusFallbacks)
        fallbackUntil = ContinuousClock.now.advanced(by: .seconds(cooldown))
        wifiRecovery.cancel()
        startHotspotIfAllowed()
    }

    private func updateHotspotConfirmPolling() {
        if hotspot.enabled && (hotspot.phase == .confirming || hotspot.phase == .joining) {
            guard hotspotConfirmPollTask == nil else { return }
            hotspotConfirmPollTask = Task { @MainActor [weak self] in
                while let self, !Task.isCancelled, self.started,
                      self.hotspot.enabled, (self.hotspot.phase == .confirming || self.hotspot.phase == .joining) {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    guard !Task.isCancelled, self.started else { return }
                    self.refreshNetworks()
                }
                self?.hotspotConfirmPollTask = nil
            }
        } else {
            hotspotConfirmPollTask?.cancel()
            hotspotConfirmPollTask = nil
        }
    }

    func requestCheck() {
        refreshNetworks()
        recoverWiFiIfNeeded()
        engine.request()
    }

    private func acquireWiFiControlIfNeeded() -> Bool {
        if ownsWiFiControl { return true }
        do {
            guard try wifiControlLock.tryAcquire() else {
                wifiControlIssue = .occupied
                wifiRecoveryDetail = "其他应用正在控制 Wi-Fi；请暂停 Sequoia Hotspot 后重试。"
                diagnosticText = wifiRecoveryDetail
                return false
            }
            ownsWiFiControl = true
            wifiControlIssue = nil
            wifiRecoveryDetail = ""
            return true
        } catch {
            wifiControlIssue = .unavailable
            wifiRecoveryDetail = "无法获取 Wi-Fi 控制权；请检查应用权限后重试。"
            diagnosticText = wifiRecoveryDetail
            return false
        }
    }

    private func startHotspotIfAllowed() {
        guard started, networkPathReady, !networkSleeping, isLocationAuthorized,
              acquireWiFiControlIfNeeded() else { return }
        let path = pathMonitor.currentPath
        guard !(path.status == .satisfied && path.usesInterfaceType(.wiredEthernet)) else { return }
        let campusFallback = fallbackUntil.map { ContinuousClock.now < $0 } ?? false
        if let owned = verifiedHotspotSSID(ownedHotspotSSID, bssid: ownedHotspotBSSID, networks: networks),
           networks.contains(where: { $0.ssid == owned && $0.ip != nil }) {
            if hotspot.enabled { hotspot.setEnabled(false) }
            wifiRecoveryDetail = "已连接热点，等待校园网恢复。"
            return
        }
        let allowed = maySelectCampus(networks: networks, permissionAuthorized: true, ownedHotspotSSID: verifiedHotspotSSID(ownedHotspotSSID, bssid: ownedHotspotBSSID, networks: networks))
            || (campusFallback && selectNetwork(networks) != nil && networks.allSatisfy {
                if let ssid = $0.ssid { return ssid == campusSSID }
                return $0.bssid == nil && $0.ip == nil
            })
        guard allowed else { return }
        if !hotspot.enabled { hotspot.setEnabled(true) }
        hotspot.networkAvailable(false)
    }

    private func recoverWiFiIfNeeded() {
        guard started, networkPathReady, !networkSleeping else { return }
        guard acquireWiFiControlIfNeeded() else { return }
        let path = pathMonitor.currentPath
        if path.status == .satisfied && path.usesInterfaceType(.wiredEthernet) {
            wifiRecovery.cancel()
            hotspot.setEnabled(false)
            return
        }
        guard isLocationAuthorized else {
            wifiRecovery.cancel()
            hotspot.setEnabled(false)
            return
        }
        if let grace = wakeGraceUntil, ContinuousClock.now < grace {
            // Give macOS time after wake to re-associate with known Wi-Fi before taking over.
            return
        }
        wakeGraceUntil = nil
        if let until = fallbackUntil, ContinuousClock.now < until {
            startHotspotIfAllowed()
            return
        }
        fallbackUntil = nil
        if selectNetwork(networks) != nil {
            wifiRecovery.cancel()
            hotspot.setEnabled(false)
            return
        }
        let candidateHotspotSSID = pendingHotspotSSID ?? lastRequestedHotspotSSID
        // Do not tear down an active hotspot discovery, join, confirmation, or retry cycle
        // every 15 seconds. Allow a periodic campus re-check only after 60s of idle searching.
        if shouldPauseCampusSearchForHotspot(enabled: hotspot.enabled, phase: hotspot.phase) {
            let linked = networks.filter { $0.ssid != nil || $0.bssid != nil || $0.ip != nil }
            let joinedOtherNetwork = !linked.isEmpty && (candidateHotspotSSID == nil || !linked.allSatisfy({ $0.ssid == candidateHotspotSSID }))
            if joinedOtherNetwork {
                hotspot.setEnabled(false)
            } else if hotspot.busy {
                return
            } else if let startedAt = hotspotSearchStartedAt, ContinuousClock.now - startedAt < .seconds(60) {
                return
            }
        }
        let verifiedSSID = verifiedHotspotSSID(ownedHotspotSSID, bssid: ownedHotspotBSSID, networks: networks)
        guard maySelectCampus(networks: networks, permissionAuthorized: true, ownedHotspotSSID: verifiedSSID) else {
            wifiRecovery.cancel()
            hotspot.setEnabled(false)
            if networks.contains(where: { $0.ssid != nil }) {
                ownedHotspotSSID = nil
                ownedHotspotBSSID = nil
                lastRequestedHotspotSSID = nil
            }
            return
        }
        guard campusSearchTask == nil, wifiRecovery.canRequest else { return }
        if hotspot.enabled { hotspot.setEnabled(false) }
        let generation = engineSnapshot.read().generation
        campusSearchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.hotspot.waitUntilIdle()
            self.campusSearchTask = nil
            guard !Task.isCancelled, self.started, !self.networkSleeping,
                  self.engineSnapshot.read().generation == generation,
                  self.fallbackUntil == nil,
                  !(self.pathMonitor.currentPath.status == .satisfied && self.pathMonitor.currentPath.usesInterfaceType(.wiredEthernet)),
                  maySelectCampus(networks: self.networks, permissionAuthorized: self.isLocationAuthorized,
                                  ownedHotspotSSID: verifiedHotspotSSID(self.ownedHotspotSSID, bssid: self.ownedHotspotBSSID, networks: self.networks)) else { return }
            self.wifiRecovery.request(snapshot: self.engineSnapshot, ownedHotspotSSID: verifiedHotspotSSID(self.ownedHotspotSSID, bssid: self.ownedHotspotBSSID, networks: self.networks))
        }
    }

    @objc private func networkWillSleep(_ notification: Notification) {
        networkSleeping = true
        wakeGraceTask?.cancel()
        wakeGraceTask = nil
        wakeGraceUntil = nil
        hotspotConfirmPollTask?.cancel()
        hotspotConfirmPollTask = nil
        wifiRecovery.cancel()
        campusSearchTask?.cancel()
        hotspot.suspend()
        hotspot.setEnabled(false)
        fallbackUntil = nil
        consecutiveCampusFallbacks = 0
        pendingHotspotSSID = nil
        lastRequestedHotspotSSID = nil
        hotspotSearchStartedAt = nil
        lastPathSignature = nil
        engineSnapshot.invalidateNetwork()
        internetMonitor.reset(networkAvailable: false)
    }

    @objc private func networkDidWake(_ notification: Notification) {
        networkSleeping = false
        consecutiveCampusFallbacks = 0
        wakeGraceUntil = ContinuousClock.now.advanced(by: .seconds(6))
        wakeGraceTask?.cancel()
        wakeGraceTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            guard let self, self.started, !self.networkSleeping else { return }
            self.wakeGraceUntil = nil
            self.requestCheck()
        }
        engineSnapshot.invalidateNetwork()
        internetMonitor.reset(networkAvailable: pathMonitor.currentPath.status == .satisfied)
        requestCheck()
    }

    func checkNow() {
        manualCheckRequested = true
        consecutiveCampusFallbacks = 0
        fallbackUntil = nil
        wakeGraceUntil = nil
        diagnosticText = "正在检查…"
        refreshNetworks()
        recoverWiFiIfNeeded()
        engine.checkNow()
    }

    func saveConfig(_ newConfig: AppConfig) {
        guard let error = newConfig.validationError() else {
            do {
                try store.saveConfig(newConfig)
                config = newConfig
                diagnosticText = "配置已保存。"
                consecutiveCampusFallbacks = 0
                fallbackUntil = nil
                hotspot.setEnabled(false)
                engineSnapshot.invalidateNetwork()
                requestCheck()
            } catch {
                diagnosticText = "保存失败：\(error.localizedDescription)"
            }
            return
        }
        diagnosticText = error
    }

    func requestLocationPermissionIfNeeded() {
        permissionStatus = locationManager.authorizationStatus
        guard permissionStatus == .notDetermined else {
            if permissionStatus == .denied || permissionStatus == .restricted {
                diagnosticText = "定位权限未允许，SSID 会被系统隐藏。请打开系统设置授权。"
            }
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.locationManager.requestWhenInUseAuthorization()
        }
    }

    var statusText: String {
        if permissionStatus != .authorized {
            switch permissionStatus {
            case .notDetermined: return "等待定位权限"
            case .denied, .restricted: return "需要定位权限"
            default: return "需要定位权限"
            }
        }
        if started && !ownsWiFiControl && !wifiRecoveryDetail.isEmpty { return wifiRecoveryDetail }
        if hotspot.enabled, !wifiRecoveryDetail.isEmpty { return wifiRecoveryDetail }
        if state.phase == "outside", !wifiRecoveryDetail.isEmpty { return wifiRecoveryDetail }
        if state.checking {
            return "正在检查…"
        }
        return state.detail.isEmpty ? "尚无检查记录" : state.detail
    }

    var personalHotspotStatusText: String {
        personalHotspotStatus(networks: networks, permissionAuthorized: isLocationAuthorized,
                              ownedSSID: ownedHotspotSSID, ownedBSSID: ownedHotspotBSSID,
                              sleeping: networkSleeping,
                              controlIssue: wifiControlIssue,
                              phase: hotspot.phase,
                              recognizedHotspot: hotspotRecognition(profile: profileRecognizesHotspot,
                                                                   cachedMatch: hotspotIdentityCache.matching(networks: networks) != nil))
    }

    var personalHotspotDetail: String {
        if personalHotspotStatusText == "无法识别" { return "当前 Wi-Fi 并非由本应用确认的个人热点，无法判断其类型。" }
        if hotspot.enabled { return hotspot.status }
        return statusText
    }

    private func apply(state: AppState, shouldNotify: Bool) {
        self.state = state
        if state.phase == "online" {
            consecutiveCampusFallbacks = 0
        }
        if shouldFallbackForAuthentication(state, campus: selectNetwork(networks)), fallbackUntil == nil {
            enterCampusFallback()
        }
        if manualCheckRequested && !state.checking {
            manualCheckRequested = false
            diagnosticText = state.detail
        }
        if shouldNotify {
            let content = UNMutableNotificationContent()
            content.title = appDisplayName
            content.body = state.detail
            let request = UNNotificationRequest(
                identifier: "failure-\(Date().timeIntervalSince1970)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }
    }

    private func refreshNetworks() {
        let refreshed = wifiMonitor.networks()
        if let pending = pendingHotspotSSID ?? lastRequestedHotspotSSID,
           (hotspot.busy || hotspot.enabled),
           let connected = refreshed.first(where: { $0.ssid == pending && $0.ip != nil && $0.bssid != nil }),
           pathMonitor.currentPath.status == .satisfied,
           pathMonitor.currentPath.usesInterfaceType(.wifi) {
            ownedHotspotSSID = pending
            ownedHotspotBSSID = connected.bssid
            if let bssid = connected.bssid { hotspotIdentityCache.remember(ssid: pending, bssid: bssid) }
            hotspot.networkAvailable(true)
        }
        let networkChanged = networks != refreshed
        if networkChanged {
            profileRecognizesHotspot = nil
            profileLookupTime = nil
            profileLookupGeneration &+= 1
        }
        if isLocationAuthorized, profileLookupTime.map({ ContinuousClock.now - $0 >= .seconds(30) }) ?? true {
            profileLookupTime = ContinuousClock.now
            profileLookupGeneration &+= 1
            let token = profileLookupGeneration
            Task { @MainActor [weak self] in
                let result = await Task.detached {
                    WiFiMonitor.personalHotspotProfile(networks: refreshed)
                }.value
                guard let self, acceptsHotspotProfileResult(token: token, currentToken: self.profileLookupGeneration,
                                                           authorized: self.isLocationAuthorized,
                                                           queried: refreshed, current: self.networks) else { return }
                self.profileRecognizesHotspot = result
                self.objectWillChange.send()
            }
        }
        if networkChanged { internetMonitor.reset() }
        networks = refreshed
        if !maySelectCampus(networks: refreshed, permissionAuthorized: isLocationAuthorized, ownedHotspotSSID: verifiedHotspotSSID(ownedHotspotSSID, bssid: ownedHotspotBSSID, networks: refreshed)) {
            wifiRecovery.cancel()
            if networkChanged { campusAssociationFailures = 0 }
        }
        engineSnapshot.update(
            networks: networks,
            permissionAuthorized: isLocationAuthorized
        )
    }

    private func requestNotificationPermission() {
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
    }

    private func registerLaunchAtLogin() {
        do {
            try SMAppService.mainApp.register()
        } catch {
            diagnosticText = "登录启动注册失败：\(error.localizedDescription)"
        }
    }

    func handleAuthorizationChange() {
        permissionStatus = locationManager.authorizationStatus
        refreshNetworks()
        requestCheck()
    }

    func quit() {
        NSApp.terminate(nil)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        handleAuthorizationChange()
    }
}

@MainActor
private final class SettingsWindowController: NSWindowController {
    private let model: AppModel
    private let username = NSTextField()
    private let password = NSSecureTextField()
    private let feedback = NSTextField(labelWithString: "")

    init(model: AppModel) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 180),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "设置"
        window.identifier = NSUserInterfaceItemIdentifier(settingsWindowIdentifier)
        window.collectionBehavior = [.managed, .primary]
        window.center()
        super.init(window: window)

        username.placeholderString = "账号"
        password.placeholderString = "密码"
        username.setAccessibilityLabel("校园网账号")
        password.setAccessibilityLabel("校园网密码")
        feedback.textColor = .secondaryLabelColor
        feedback.lineBreakMode = .byTruncatingTail
        let save = NSButton(title: "保存", target: self, action: #selector(saveConfig))
        let fields = NSStackView(views: [username, password, feedback, save])
        fields.orientation = .vertical
        fields.spacing = 12
        fields.alignment = .leading
        for field in [username, password, feedback] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 360).isActive = true
        }
        fields.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(fields)
        NSLayoutConstraint.activate([
            fields.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 30),
            fields.trailingAnchor.constraint(lessThanOrEqualTo: window.contentView!.trailingAnchor, constant: -30),
            fields.centerYAnchor.constraint(equalTo: window.contentView!.centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func showWindow(_ sender: Any?) {
        username.stringValue = model.config.username
        password.stringValue = model.config.password
        feedback.stringValue = ""
        super.showWindow(sender)
        window?.deminiaturize(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func saveConfig() {
        let draft = AppConfig(username: username.stringValue, password: password.stringValue)
        if let error = draft.validationError() {
            feedback.stringValue = error
            return
        }
        model.saveConfig(draft)
        feedback.stringValue = model.diagnosticText
    }
}

@MainActor
private func removeStatusItemPreservingPosition(_ item: NSStatusItem) {
    guard let name = item.autosaveName else {
        NSStatusBar.system.removeStatusItem(item)
        return
    }
    let key = "NSStatusItem Preferred Position \(name)"
    let position = UserDefaults.standard.object(forKey: key)
    NSStatusBar.system.removeStatusItem(item)
    if let position { UserDefaults.standard.set(position, forKey: key) }
}

@MainActor
private final class StatusBarController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let item = NSStatusBar.system.statusItem(withLength: 28)
    private let icon = NSImageView(frame: .zero)
    private let menu = NSMenu()
    private var connectivitySubscription: AnyCancellable?
    private var timer: Timer?
    private var animationTimer: Timer?
    private var campusItem: NSMenuItem?
    private var hotspotItem: NSMenuItem?
    private var internetItem: NSMenuItem?
    private var online: Bool

    init(model: AppModel) {
        self.model = model
        online = model.internetStatus.isConnected
        super.init()
        item.autosaveName = "NetworkAuto"
        guard let button = item.button else { return }
        // Ice identifies status items by bundle identifier and window title.
        button.window?.title = "NetworkAuto"
        button.image = nil
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        button.addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
        ])
        icon.image = symbol(online ? "network" : "network.slash")
        if !online { startOfflineAnimation() }
        menu.delegate = self
        item.menu = menu
        updateAccessibility()
        connectivitySubscription = model.$internetStatus
        .removeDuplicates()
        .sink { [weak self] status in
            self?.setConnectivity(status.isConnected)
            self?.item.button?.setAccessibilityLabel("互联网：\(status.title)")
        }
    }

    func verifyStableIdentity() {
        guard let window = item.button?.window else { preconditionFailure("Status item has no window") }
        precondition(item.autosaveName == "NetworkAuto" && window.title == "NetworkAuto")
        let original = online
        setConnectivity(!original)
        precondition(window.title == "NetworkAuto")
        setConnectivity(original)
        precondition(window.title == "NetworkAuto")
    }

    func stop() {
        timer?.invalidate()
        animationTimer?.invalidate()
        connectivitySubscription?.cancel()
        removeStatusItemPreservingPosition(item)
    }

    private func symbol(_ name: String) -> NSImage {
        let base = NSImage(systemSymbolName: name, accessibilityDescription: name) ?? NSImage(size: NSSize(width: 17, height: 17))
        let config = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
            .applying(.preferringHierarchical())
        return base.withSymbolConfiguration(config) ?? base
    }

    private func setConnectivity(_ connected: Bool) {
        guard online != connected else { return }
        online = connected
        animationTimer?.invalidate()
        animationTimer = nil
        icon.setSymbolImage(
            symbol(connected ? "network" : "network.slash"),
            contentTransition: .replace.upUp.byLayer
        )
        if !connected { startOfflineAnimation() }
        updateAccessibility()
    }

    private func startOfflineAnimation() {
        let timer = Timer(timeInterval: 0.8, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.icon.setSymbolImage(
                    self.symbol("network.slash"),
                    contentTransition: .replace.upUp.byLayer
                )
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    private func updateAccessibility() {
        item.button?.setAccessibilityLabel(online ? "互联网已连接" : "互联网未连接")
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshMenu()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshMenu() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        timer?.invalidate()
        timer = nil
    }

    private func refreshMenu() {
        campusItem?.title = "校园网：\(campusConnectionStatus(networks: model.networks, permissionAuthorized: model.permissionStatus == .authorized, state: model.state))"
        campusItem?.toolTip = model.statusText
        hotspotItem?.title = "个人热点：\(model.personalHotspotStatusText)"
        hotspotItem?.toolTip = model.personalHotspotDetail
        internetItem?.title = "互联网：\(model.internetStatus.title)"
        internetItem?.toolTip = model.internetStatus.detail
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        func info(_ title: String) {
            let item = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
        }
        @discardableResult
        func action(_ title: String, _ selector: Selector) -> NSMenuItem {
            let item = menu.addItem(withTitle: title, action: selector, keyEquivalent: "")
            item.target = self
            return item
        }
        menu.removeAllItems()
        info("")
        campusItem = menu.items.last
        info("")
        hotspotItem = menu.items.last
        info("")
        internetItem = menu.items.last
        menu.addItem(.separator())
        action("立即登录校园网", #selector(checkNow))
        menu.addItem(.separator())
        action("设置", #selector(openSettings))
        action("退出", #selector(quit))
        refreshMenu()
    }

    @objc private func checkNow() { model.checkNow() }
    @objc private func openSettings() { (NSApp.delegate as? AppDelegate)?.openSettingsWindow() }
    @objc private func quit() { model.quit() }
}

@MainActor
@discardableResult
private func runFocusedAlert(_ alert: NSAlert) -> NSApplication.ModalResponse {
    NSApp.setActivationPolicy(.regular)
    alert.layout()
    let window = alert.window
    window.center()
    if let screen = window.screen {
        window.setFrameOrigin(NSPoint(x: window.frame.minX, y: screen.visibleFrame.midY - window.frame.height / 2))
    }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    let response = alert.runModal()
    (NSApp.delegate as? AppDelegate)?.refreshActivationPolicy()
    return response
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var instanceLock: AppInstanceLock?
    private var statusBar: StatusBarController?
    private var settingsWindow: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowVisibilityChanged(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
        if CommandLine.arguments.contains("--self-test") {
            SelfTest.run()
            NSApp.terminate(nil)
            return
        }
        if CommandLine.arguments.contains("--unregister") {
            try? SMAppService.mainApp.unregister()
            NSApp.terminate(nil)
            return
        }
        do {
            let paths = AppPaths()
            try ensurePrivateDirectory(paths.data)
            instanceLock = try AppInstanceLock(path: paths.data.appendingPathComponent("run.lock"))
        } catch AppInstanceLockError.alreadyRunning {
            NSLog("Csust-Network-Automation 已在运行，退出重复实例。")
            showStartupError("Csust-Network-Automation 已经在运行。请使用菜单栏中的现有图标。")
            NSApp.terminate(nil)
            return
        } catch {
            NSLog("无法取得 Csust-Network-Automation 运行锁：%@", error.localizedDescription)
            showStartupError("无法启动 Csust-Network-Automation：\(error.localizedDescription)")
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        AppModel.shared.start()
        statusBar = StatusBarController(model: AppModel.shared)
        updateActivationPolicy()
        signalReadinessIfRequested()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await AppModel.shared.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
        statusBar?.stop()
        statusBar = nil
    }

    func openSettingsWindow() {
        if settingsWindow == nil { settingsWindow = SettingsWindowController(model: .shared) }
        NSApp.setActivationPolicy(.regular)
        settingsWindow?.showWindow(nil)
    }

    @objc private func windowVisibilityChanged(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.updateActivationPolicy() }
    }

    func refreshActivationPolicy() { updateActivationPolicy() }

    private func updateActivationPolicy() {
        let hasUI = settingsWindow?.window?.isVisible == true || NSApp.modalWindow?.isVisible == true
        NSApp.setActivationPolicy(hasUI ? .regular : .accessory)
    }

    private func signalReadinessIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["NETWORK_AUTO_READY_FILE"],
              !path.isEmpty else {
            return
        }
        FileManager.default.createFile(atPath: path, contents: Data())
    }

    private func showStartupError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = appDisplayName
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        runFocusedAlert(alert)
    }
}

private final class LockedString: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""

    func set(_ value: String) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func get() -> String {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class LockedAppState: @unchecked Sendable {
    private let lock = NSLock()
    private var value = AppState()

    func set(_ value: AppState) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func get() -> AppState {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

enum SelfTest {
    @MainActor
    static func run() {
        let testItem = NSStatusBar.system.statusItem(withLength: 28)
        let testName = "NetworkAuto-test-\(UUID().uuidString)"
        testItem.autosaveName = NSStatusItem.AutosaveName(testName)
        let positionKey = "NSStatusItem Preferred Position \(testName)"
        UserDefaults.standard.set(123, forKey: positionKey)
        removeStatusItemPreservingPosition(testItem)
        precondition(UserDefaults.standard.integer(forKey: positionKey) == 123)
        UserDefaults.standard.removeObject(forKey: positionKey)
        let statusBar = StatusBarController(model: .shared)
        statusBar.verifyStableIdentity()
        let menu = NSMenu()
        statusBar.menuNeedsUpdate(menu)
        precondition(menu.items.count == 8)
        precondition(menu.items[0].title.hasPrefix("校园网："))
        precondition(menu.items[1].title.hasPrefix("个人热点："))
        precondition(menu.items[2].title.hasPrefix("互联网："))
        precondition(menu.items[3].isSeparatorItem && menu.items[5].isSeparatorItem)
        precondition(menu.items[4].title == "立即登录校园网" && menu.items[4].isEnabled)
        precondition(menu.items[6].title == "设置" && menu.items[6].isEnabled)
        precondition(menu.items[7].title == "退出" && menu.items[7].isEnabled)
        (NSApp.delegate as? AppDelegate)?.refreshActivationPolicy()
        precondition(NSApp.activationPolicy() == .accessory)
        statusBar.stop()
        runHeadless()
    }

    static func runHeadless() {
        wifiRecoveryPolicy()
        precondition(!usableIPv4("127.0.0.1"))
        precondition(!usableIPv4("169.254.1.1"))
        precondition(usableIPv4("10.183.0.2"))
        let config = AppConfig(
            username: "account",
            password: "p&密+?#"
        )
        precondition(selectNetwork([
            WiFiNetwork(interfaceName: "en0", ssid: "other", bssid: nil, ip: "10.183.0.2"),
            WiFiNetwork(interfaceName: "en1", ssid: campusSSID, bssid: nil, ip: "192.0.2.1")
        ])?.interfaceName == "en1")
        precondition(selectNetwork([
            WiFiNetwork(interfaceName: "en0", ssid: "csust-student", bssid: nil, ip: nil)
        ]) == nil)
        precondition(parseResponse("dr1003({\"result\":1});") == .online)
        precondition(parseResponse("dr1003({\"msg\":\"密码错误\"});") == .credentials)
        precondition(parseResponse("dr1003({\"msg\":\"10.183.0.2 已经在线！\"});") == .online)
        let campus = WiFiNetwork(interfaceName: "en0", ssid: campusSSID, bssid: "aa", ip: "10.183.0.2")
        var campusState = AppState()
        precondition(campusConnectionStatus(networks: [], permissionAuthorized: true, state: campusState) == "未连接")
        precondition(campusConnectionStatus(networks: [campus], permissionAuthorized: false, state: campusState) == "需要定位权限")
        precondition(campusConnectionStatus(networks: [campus], permissionAuthorized: true, state: campusState) == "未登录")
        campusState.network = campus.key
        campusState.checking = true
        precondition(campusConnectionStatus(networks: [campus], permissionAuthorized: true, state: campusState) == "登录中")
        campusState.phase = "online"
        precondition(campusConnectionStatus(networks: [campus], permissionAuthorized: true, state: campusState) == "已登录")
        campusState.phase = "credentials"
        precondition(campusConnectionStatus(networks: [campus], permissionAuthorized: true, state: campusState) == "登录中")
        campusState.checking = false
        precondition(campusConnectionStatus(networks: [campus], permissionAuthorized: true, state: campusState) == "认证失败")
        precondition(shouldFallbackForAuthentication(campusState, campus: campus))
        // A new authentication round must complete before an earlier failure can trigger fallback.
        campusState.checking = true
        precondition(!shouldFallbackForAuthentication(campusState, campus: campus))
        campusState.phase = "online"
        campusState.checking = false
        precondition(!shouldFallbackForAuthentication(campusState, campus: campus))
        campusState.phase = "retry"
        campusState.attempt = 1
        precondition(!shouldFallbackForAuthentication(campusState, campus: campus))
        campusState.attempt = 3
        precondition(shouldFallbackForAuthentication(campusState, campus: campus))
        precondition(config.validationError() == nil)
        let encodedConfig = try! JSONEncoder().encode(config)
        precondition(String(decoding: encodedConfig, as: UTF8.self).contains(config.password))
        precondition(!String(decoding: encodedConfig, as: UTF8.self).contains("timeout"))
        var changedConfig = config
        changedConfig.password = "different"
        precondition(configFingerprint(config) != configFingerprint(changedConfig))
        storeMigrationAndPersistence()
        engineCancellationAndMutex()
        authenticationAttemptsResetAfterSuccess()
        authenticationWaitsForUsableIPv4AndBacksOff()
        manualLoginBypassesConnectivity()
        ClashConnectivitySelfTest.run()
        httpLogin(proxy: false)
        httpLogin(proxy: true)
        print("NetworkAuto self-test passed")
    }

    private static func wifiRecoveryPolicy() {
        let disconnected = WiFiNetwork(interfaceName: "en0", ssid: nil, bssid: nil, ip: nil)
        let hotspot = WiFiNetwork(interfaceName: "en0", ssid: "Phone", bssid: "bb", ip: "192.0.2.2")
        func hotspotStatus(_ networks: [WiFiNetwork], authorized: Bool = true, ssid: String? = nil,
                           bssid: String? = nil, sleeping: Bool = false, issue: WiFiControlIssue? = nil,
                           phase: HotspotPhase = .disabled) -> String {
            personalHotspotStatus(networks: networks, permissionAuthorized: authorized,
                                  ownedSSID: ssid, ownedBSSID: bssid, sleeping: sleeping,
                                  controlIssue: issue, phase: phase)
        }
        precondition(hotspotStatus([hotspot], ssid: "Phone", bssid: "bb") == "已连接")
        precondition(hotspotStatus([hotspot], ssid: "Phone", bssid: "other") == "无法识别")
        precondition(hotspotStatus([hotspot]) == "无法识别")
        precondition(personalHotspotStatus(networks: [hotspot], permissionAuthorized: true,
                                          ownedSSID: nil, ownedBSSID: nil, sleeping: false,
                                          controlIssue: nil, phase: .disabled, recognizedHotspot: true) == "已连接")
        precondition(personalHotspotStatus(networks: [hotspot], permissionAuthorized: false,
                                          ownedSSID: nil, ownedBSSID: nil, sleeping: false,
                                          controlIssue: nil, phase: .disabled, recognizedHotspot: true) == "需要定位权限")
        precondition(hotspotRecognition(profile: false, cachedMatch: true) == false)
        precondition(hotspotRecognition(profile: nil, cachedMatch: true) == true)
        precondition(hotspotRecognition(profile: nil, cachedMatch: false) == nil)
        precondition(personalHotspotStatus(networks: [hotspot], permissionAuthorized: true,
                                          ownedSSID: nil, ownedBSSID: nil, sleeping: false,
                                          controlIssue: nil, phase: .disabled, recognizedHotspot: false) == "未连接")
        precondition(acceptsHotspotProfileResult(token: 1, currentToken: 1, authorized: true, queried: [hotspot], current: [hotspot]))
        precondition(!acceptsHotspotProfileResult(token: 1, currentToken: 2, authorized: true, queried: [hotspot], current: [hotspot]))
        precondition(!acceptsHotspotProfileResult(token: 1, currentToken: 1, authorized: false, queried: [hotspot], current: [hotspot]))
        precondition(!acceptsHotspotProfileResult(token: 1, currentToken: 1, authorized: true, queried: [hotspot], current: [disconnected]))
        precondition(hotspotStatus([hotspot], authorized: false) == "需要定位权限")
        precondition(hotspotStatus([disconnected]) == "未连接")
        precondition(hotspotStatus([hotspot], ssid: "Phone", bssid: "bb", sleeping: true) == "已暂停")
        precondition(hotspotStatus([disconnected], issue: .occupied) == "其他应用占用")
        precondition(hotspotStatus([disconnected], issue: .unavailable) == "控制权获取失败")
        precondition(hotspotStatus([disconnected], phase: .joining) == "连接中")
        precondition(hotspotStatus([disconnected], phase: .browsing) == "查找中")
        precondition(hotspotStatus([disconnected], phase: .retrying(.joining)) == "暂不可用，重试中")
        precondition(hotspotStatus([disconnected], phase: .failed(.discovery)) == "暂不可用")
        precondition(maySelectCampus(networks: [disconnected], permissionAuthorized: true, ownedHotspotSSID: nil))
        precondition(maySelectCampus(networks: [hotspot], permissionAuthorized: true, ownedHotspotSSID: "Phone"))
        // A remembered hotspot remains eligible after wake only when the live BSSID matches.
        precondition(verifiedHotspotSSID("Phone", bssid: "bb", networks: [hotspot]) == "Phone")
        precondition(verifiedHotspotSSID("Phone", bssid: "bb", networks: [disconnected]) == nil)
        precondition(verifiedHotspotSSID("Phone", bssid: "different", networks: [hotspot]) == nil)
        let suiteName = "HotspotIdentityCacheSelfTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cache = HotspotIdentityCache(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        cache.remember(ssid: "Phone", bssid: "bb", now: now)
        precondition(cache.matching(networks: [hotspot], now: now)?.ssid == "Phone")
        precondition(HotspotIdentityCache(defaults: defaults).matching(networks: [hotspot], now: now)?.ssid == "Phone")
        precondition(cache.matching(networks: [WiFiNetwork(interfaceName: "en0", ssid: "Phone", bssid: "cc", ip: "192.0.2.2")], now: now) == nil)
        precondition(cache.matching(networks: [disconnected], now: now) == nil)
        precondition(cache.matching(networks: [hotspot], now: now.addingTimeInterval(30 * 24 * 60 * 60)) == nil)
        precondition(!maySelectCampus(networks: [hotspot], permissionAuthorized: false, ownedHotspotSSID: "Phone"))
        precondition(!maySelectCampus(networks: [hotspot], permissionAuthorized: true, ownedHotspotSSID: nil))
        precondition(!maySelectCampus(networks: [hotspot, WiFiNetwork(interfaceName: "en1", ssid: "Other", bssid: "cc", ip: nil)], permissionAuthorized: true, ownedHotspotSSID: "Phone"))
        precondition(!maySelectCampus(networks: [WiFiNetwork(interfaceName: "en0", ssid: nil, bssid: "bb", ip: nil)], permissionAuthorized: true, ownedHotspotSSID: "Phone"))
        // A hidden SSID, a pending DHCP lease, or a second associated adapter must prevent takeover.
        for connected in [
            WiFiNetwork(interfaceName: "en1", ssid: "other", bssid: nil, ip: nil),
            WiFiNetwork(interfaceName: "en1", ssid: nil, bssid: "aa", ip: nil),
            WiFiNetwork(interfaceName: "en1", ssid: nil, bssid: nil, ip: "192.0.2.1"),
            WiFiNetwork(interfaceName: "en1", ssid: campusSSID, bssid: "aa", ip: nil)
        ] {
            precondition(!maySelectCampus(networks: [disconnected, connected], permissionAuthorized: true, ownedHotspotSSID: nil))
        }
        // Hotspot coordinator stability policies.
        precondition(shouldPauseCampusSearchForHotspot(enabled: true, phase: .browsing))
        precondition(shouldPauseCampusSearchForHotspot(enabled: true, phase: .retrying(.joining)))
        precondition(shouldPauseCampusSearchForHotspot(enabled: true, phase: .activating))
        precondition(!shouldPauseCampusSearchForHotspot(enabled: false, phase: .browsing))
        precondition(!shouldPauseCampusSearchForHotspot(enabled: true, phase: .networkAvailable))
        precondition(fallbackCooldownSeconds(consecutiveFallbacks: 1) == 120)
        precondition(fallbackCooldownSeconds(consecutiveFallbacks: 2) == 240)
        precondition(fallbackCooldownSeconds(consecutiveFallbacks: 3) == 480)
        precondition(fallbackCooldownSeconds(consecutiveFallbacks: 4) == 600)
        precondition(fallbackCooldownSeconds(consecutiveFallbacks: 9) == 600)
        precondition(!campusCandidateEligible(rssi: -82, replacingHotspot: true))
        precondition(campusCandidateEligible(rssi: -68, replacingHotspot: true))
        precondition(campusCandidateEligible(rssi: -82, replacingHotspot: false))
        let sigA = PathSignature(satisfied: true, usesWiFi: true, usesEthernet: false, isExpensive: false, interfaces: ["en0"], gateways: ["10.0.0.1"])
        let sigB = PathSignature(satisfied: true, usesWiFi: true, usesEthernet: false, isExpensive: false, interfaces: ["en0"], gateways: ["10.0.0.1"])
        let sigC = PathSignature(satisfied: true, usesWiFi: true, usesEthernet: false, isExpensive: true, interfaces: ["en0"], gateways: ["172.20.10.1"])
        precondition(sigA == sigB && sigA != sigC)
    }

    private static func storeMigrationAndPersistence() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("csust-self-test-\(UUID().uuidString)")
        let data = root.appendingPathComponent("data", isDirectory: true)
        let paths = AppPaths(
            data: data,
            legacyConfig: data.appendingPathComponent("config.json"),
            legacyState: data.appendingPathComponent("state.json"),
            logs: root.appendingPathComponent("logs", isDirectory: true)
        )
        let suiteName = "csust-self-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        try! FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)

        let legacyConfig = Data(#"{"username":"migrated-account","password":"migrated-password","timeout_secs":15,"ip_prefixes":["10.183."]}"#.utf8)
        try! legacyConfig.write(to: paths.legacyConfig)
        let expectedConfig = AppConfig(
            username: "migrated-account",
            password: "migrated-password"
        )
        var legacyState = AppState()
        legacyState.phase = "online"
        legacyState.checking = true
        try! JSONEncoder().encode(legacyState).write(to: paths.legacyState)

        let store = AppStore(defaults: defaults, paths: paths)
        precondition(store.config() == .success(expectedConfig))
        precondition(defaults.data(forKey: configDefaultsKey) != nil)
        precondition(String(decoding: defaults.data(forKey: configDefaultsKey)!, as: UTF8.self).contains(expectedConfig.password))
        precondition(!FileManager.default.fileExists(atPath: paths.legacyConfig.path))
        precondition(store.effectiveConfig() == .success(expectedConfig))
        try! store.saveConfig(expectedConfig)
        precondition(String(decoding: defaults.data(forKey: configDefaultsKey)!, as: UTF8.self).contains(expectedConfig.password))
        store.saveState(legacyState)
        let reloaded = AppStore(defaults: defaults, paths: paths)
        precondition(reloaded.config() == .success(expectedConfig))
        var expectedState = legacyState
        expectedState.checking = false
        precondition(reloaded.loadState() == expectedState)
    }

    private static func engineCancellationAndMutex() {
        let lockRoot = FileManager.default.temporaryDirectory.appendingPathComponent("csust-lock-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: lockRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: lockRoot) }
        let lockPath = lockRoot.appendingPathComponent("run.lock")
        do {
            let first = try! AppInstanceLock(path: lockPath)
            precondition((fcntl(first.descriptor, F_GETFD) & FD_CLOEXEC) != 0)
            do {
                _ = try AppInstanceLock(path: lockPath)
                preconditionFailure("second instance acquired the run lock")
            } catch AppInstanceLockError.alreadyRunning {
                // expected
            } catch {
                preconditionFailure("unexpected run lock error: \(error)")
            }
            _ = first
        }
        try? FileManager.default.removeItem(at: lockPath)
        _ = try! AppInstanceLock(path: lockPath)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("csust-engine-test-\(UUID().uuidString)")
        let data = root.appendingPathComponent("data", isDirectory: true)
        let paths = AppPaths(
            data: data,
            legacyConfig: data.appendingPathComponent("config.json"),
            legacyState: data.appendingPathComponent("state.json"),
            logs: root.appendingPathComponent("logs", isDirectory: true)
        )
        let suiteName = "csust-engine-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        try! FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        var config = AppConfig.default
        config.username = "engine-account"
        config.password = "engine-password"
        let store = AppStore(defaults: defaults, paths: paths)
        try! store.saveConfig(config)
        let permissionSnapshot = EngineSnapshot()
        permissionSnapshot.update(networks: [], permissionAuthorized: false)
        let permissionWaiting = DispatchSemaphore(value: 0)
        do {
            let permissionEngine = AutoLoginEngine(store: store, snapshot: permissionSnapshot, onUpdate: { state, _, _ in
                if state.phase == "permission" { permissionWaiting.signal() }
            })
            permissionEngine.start()
            precondition(permissionWaiting.wait(timeout: .now() + 3) == .success)
            permissionEngine.stop()
        }
        let snapshot = EngineSnapshot()
        snapshot.update(
            networks: [WiFiNetwork(interfaceName: "en0", ssid: "other", bssid: nil, ip: nil)],
            permissionAuthorized: true
        )
        let observed = LockedAppState()
        let waiting = DispatchSemaphore(value: 0)
        let engine = AutoLoginEngine(store: store, snapshot: snapshot, onUpdate: { state, _, _ in
            observed.set(state)
            if state.phase == "outside" && !state.checking { waiting.signal() }
        })
        engine.start()
        precondition(waiting.wait(timeout: .now() + 3) == .success)
        precondition(observed.get().phase == "outside")
        precondition(!observed.get().checking)
        let started = Date()
        engine.stop()
        precondition(Date().timeIntervalSince(started) < 1)
    }

    private static func authenticationAttemptsResetAfterSuccess() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("csust-attempt-test-\(UUID().uuidString)")
        let paths = AppPaths(data: root, legacyConfig: root.appendingPathComponent("config.json"),
                             legacyState: root.appendingPathComponent("state.json"), logs: root.appendingPathComponent("logs"))
        let suiteName = "csust-attempt-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        let store = AppStore(defaults: defaults, paths: paths)
        try! store.saveConfig(AppConfig(username: "account", password: "password"))
        let snapshot = EngineSnapshot()
        snapshot.update(networks: [WiFiNetwork(interfaceName: "en0", ssid: campusSSID, bssid: "aa", ip: "10.183.0.2")], permissionAuthorized: true)
        let calls = LockedString()
        let firstSuccess = DispatchSemaphore(value: 0)
        let laterFailure = DispatchSemaphore(value: 0)
        let observed = LockedAppState()
        let engine = AutoLoginEngine(store: store, snapshot: snapshot, retryDelays: [], authenticate: { _, _, _ in
            let count = (Int(calls.get()) ?? 0) + 1
            calls.set(String(count))
            return (count == 3 || count >= 5 ? .online : .retry("temporary"), "direct")
        }, onUpdate: { state, _, _ in
            if !state.checking && state.phase == "online" && calls.get() == "3" {
                observed.set(state)
                firstSuccess.signal()
            }
            if state.phase == "retry" && calls.get() == "4" {
                observed.set(state)
                laterFailure.signal()
            }
        })
        engine.start()
        precondition(firstSuccess.wait(timeout: .now() + 3) == .success)
        precondition(observed.get().attempt == 0)
        engine.checkNow()
        precondition(laterFailure.wait(timeout: .now() + 3) == .success)
        precondition(observed.get().attempt == 1)
        engine.stop()
    }

    private static func authenticationWaitsForUsableIPv4AndBacksOff() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("csust-ipwait-test-\(UUID().uuidString)")
        let paths = AppPaths(data: root, legacyConfig: root.appendingPathComponent("config.json"),
                             legacyState: root.appendingPathComponent("state.json"), logs: root.appendingPathComponent("logs"))
        let suiteName = "csust-ipwait-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        let store = AppStore(defaults: defaults, paths: paths)
        try! store.saveConfig(AppConfig(username: "account", password: "password"))
        let snapshot = EngineSnapshot()
        // Connected to campus SSID without an IPv4 lease yet: must not send empty-IP login requests.
        snapshot.update(networks: [WiFiNetwork(interfaceName: "en0", ssid: campusSSID, bssid: "aa", ip: nil)], permissionAuthorized: true)
        let calls = LockedString()
        let waited = DispatchSemaphore(value: 0)
        let observed = LockedAppState()
        let engine = AutoLoginEngine(store: store, snapshot: snapshot, retryDelays: [0.05, 0.05], ipWaitTimeout: 0.25, authenticate: { _, ip, _ in
            calls.set(ip)
            return (.retry("temporary"), "direct")
        }, onUpdate: { state, _, _ in
            observed.set(state)
            if !state.checking && (state.phase == "waiting_ip" || (state.phase == "retry" && state.attempt >= 3)) {
                waited.signal()
            }
        })
        engine.start()
        precondition(waited.wait(timeout: .now() + 3) == .success)
        precondition(calls.get().isEmpty, "Must not call authenticate without a usable IPv4")
        precondition(observed.get().phase == "waiting_ip" && observed.get().attempt == 0)
        // Once DHCP assigns a valid IPv4, retries back off instead of looping instantaneously.
        let started = Date()
        snapshot.update(networks: [WiFiNetwork(interfaceName: "en0", ssid: campusSSID, bssid: "aa", ip: "10.183.0.2")], permissionAuthorized: true)
        engine.request()
        precondition(waited.wait(timeout: .now() + 3) == .success)
        precondition(calls.get() == "10.183.0.2")
        precondition(observed.get().attempt == 3)
        precondition(Date().timeIntervalSince(started) >= 0.08, "Retries must wait between attempts")
        engine.stop()
    }

    private static func manualLoginBypassesConnectivity() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("csust-manual-test-\(UUID().uuidString)")
        let paths = AppPaths(
            data: root,
            legacyConfig: root.appendingPathComponent("config.json"),
            legacyState: root.appendingPathComponent("state.json"),
            logs: root.appendingPathComponent("logs", isDirectory: true)
        )
        let suiteName = "csust-manual-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        let store = AppStore(defaults: defaults, paths: paths)
        try! store.saveConfig(AppConfig(username: "account", password: "password"))
        let snapshot = EngineSnapshot()
        snapshot.update(
            networks: [WiFiNetwork(interfaceName: "en0", ssid: campusSSID, bssid: "aa", ip: "10.183.0.2")],
            permissionAuthorized: true
        )
        snapshot.updateConnectivity(true)
        let authentication = LockedString()
        let completed = DispatchSemaphore(value: 0)
        let engine = AutoLoginEngine(
            store: store,
            snapshot: snapshot,
            authenticate: { _, _, _ in
                authentication.set("called")
                return (.online, "direct")
            },
            onUpdate: { state, _, _ in
                if !state.checking && (state.phase == "online" || state.phase == "outside") { completed.signal() }
            }
        )
        engine.start()
        precondition(completed.wait(timeout: .now() + 3) == .success)
        precondition(authentication.get() == "called") // Internet traffic cannot authenticate campus Wi-Fi.
        authentication.set("")
        engine.request()
        precondition(completed.wait(timeout: .now() + 3) == .success)
        precondition(authentication.get().isEmpty)
        snapshot.updateConnectivity(false)
        engine.request()
        precondition(completed.wait(timeout: .now() + 3) == .success)
        precondition(authentication.get() == "called") // Confirm campus session without probing external sites.
        authentication.set("")
        snapshot.updateConnectivity(true)
        engine.checkNow()
        precondition(completed.wait(timeout: .now() + 3) == .success)
        precondition(authentication.get() == "called")
        authentication.set("")
        snapshot.update(networks: [WiFiNetwork(interfaceName: "en0", ssid: "other", bssid: nil, ip: nil)], permissionAuthorized: true)
        engine.checkNow()
        precondition(completed.wait(timeout: .now() + 3) == .success)
        precondition(authentication.get().isEmpty)
        engine.stop()

        // A reconnect with the same BSSID/IP must invalidate an in-flight authentication result.
        snapshot.update(networks: [WiFiNetwork(interfaceName: "en0", ssid: campusSSID, bssid: "aa", ip: "10.183.0.2")], permissionAuthorized: true)
        let observed = LockedAppState()
        let reconnected = DispatchSemaphore(value: 0)
        let reconnectEngine = AutoLoginEngine(
            store: store,
            snapshot: snapshot,
            authenticate: { _, _, stillConnected in
                if authentication.get().isEmpty {
                    authentication.set("first")
                    snapshot.invalidateNetwork()
                    precondition(!stillConnected())
                    return (.credentials, "direct")
                }
                authentication.set("second")
                return (.online, "direct")
            },
            onUpdate: { state, _, _ in
                observed.set(state)
                if !state.checking && state.phase == "online" { reconnected.signal() }
            }
        )
        reconnectEngine.start()
        precondition(reconnected.wait(timeout: .now() + 3) == .success)
        precondition(authentication.get() == "second" && !observed.get().credentialsBlocked)
        reconnectEngine.stop()
    }

    private static func httpLogin(proxy: Bool) {
        let queue = DispatchQueue(label: "com.nowaywastaken.networkauto.self-test-server")
        let listener = try! NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        let requestDone = DispatchSemaphore(value: 0)
        let requestText = LockedString()
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, _ in
                if let data, let text = String(data: data, encoding: .utf8) {
                    requestText.set(text)
                }
                let body = Data(#"{"result":1}"#.utf8)
                let header = Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
                connection.send(content: header + body, completion: .contentProcessed { _ in
                    requestDone.signal()
                    connection.cancel()
                })
            }
        }
        listener.start(queue: queue)
        precondition(ready.wait(timeout: .now() + 3) == .success)
        let port = listener.port!.rawValue
        var config = AppConfig.default
        config.username = "account"
        config.password = "p&密+?#"
        let serverURL: URL
        let systemProxy: URL?
        if proxy {
            serverURL = URL(string: "http://127.0.0.1:9/login")!
            systemProxy = URL(string: "http://127.0.0.1:\(port)")!
        } else {
            serverURL = URL(string: "http://127.0.0.1:\(port)/login")!
            systemProxy = nil
        }
        let result = LoginService.login(
            config: config,
            ip: "10.183.0.2",
            stillConnected: { true },
            serverURL: serverURL,
            systemProxy: systemProxy
        )
        precondition(result.0 == .online)
        precondition(requestDone.wait(timeout: .now() + 3) == .success)
        let captured = requestText.get()
        precondition(captured.contains("user_password=p%26"))
        precondition(captured.contains("wlan_user_ip=10.183.0.2"))
        precondition(!captured.contains("p&密+?#"))
        listener.cancel()
    }
}

@main
enum NetworkAutoApp {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--headless-self-test") {
            SelfTest.runHeadless()
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
