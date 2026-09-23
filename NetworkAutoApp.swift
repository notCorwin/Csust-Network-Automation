import AppKit
import Combine
import CoreLocation
import CoreWLAN
import CryptoKit
import Darwin
import Foundation
import Network
import ServiceManagement
import Symbols
import UserNotifications

private let appDisplayName = "Csust-Network-Automation"
private let campusSSID = "CSUST-Student"
private let campusLoginURL = URL(string: "https://login.csust.edu.cn:802/eportal/portal/login")!
private let connectivityURL = URL(string: "https://www.google.com/generate_204")!
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
    private let descriptor: Int32

    init(path: URL) throws {
        let descriptor = Darwin.open(path.path, O_CREAT | O_RDWR, mode_t(0o600))
        guard descriptor >= 0 else {
            throw AppInstanceLockError.openFailed(String(cString: strerror(errno)))
        }
        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let error = errno
            close(descriptor)
            if error == EWOULDBLOCK || error == EAGAIN {
                throw AppInstanceLockError.alreadyRunning
            }
            throw AppInstanceLockError.lockFailed(String(cString: strerror(error)))
        }
        self.descriptor = descriptor
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

    func update(networks: [WiFiNetwork], permissionAuthorized: Bool) {
        lock.lock()
        self.networks = networks
        self.permissionAuthorized = permissionAuthorized
        lock.unlock()
    }

    func read() -> (networks: [WiFiNetwork], permissionAuthorized: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (networks, permissionAuthorized)
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

func hasInternetEvidence(google: Bool, networks: [WiFiNetwork], state: AppState) -> Bool {
    guard google else { return false }
    guard let campus = selectNetwork(networks) else { return true }
    return state.network == campus.key && state.phase == "online"
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

final class WiFiMonitor: NSObject, CWEventDelegate {
    private let client = CWWiFiClient.shared()
    var onChange: (() -> Void)?

    func start() {
        client.delegate = self
        for event in [CWEventType.ssidDidChange, .bssidDidChange, .linkDidChange, .powerDidChange] {
            _ = try? client.startMonitoringEvent(with: event)
        }
        onChange?()
    }

    func stop() {
        _ = try? client.stopMonitoringAllEvents()
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

    func ssidDidChangeForWiFiInterface(withName interfaceName: String) { onChange?() }
    func bssidDidChangeForWiFiInterface(withName interfaceName: String) { onChange?() }
    func linkDidChangeForWiFiInterface(withName interfaceName: String) { onChange?() }
    func powerStateDidChangeForWiFiInterface(withName interfaceName: String) { onChange?() }

    func clientConnectionInterrupted() { onChange?() }
    func clientConnectionInvalidated() { onChange?() }
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
    static func hasInternetConnectivity(stillConnected: @escaping @Sendable () -> Bool) -> Bool {
        var request = URLRequest(url: connectivityURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        guard case .success(let response) = perform(
            request: request,
            route: "system",
            shouldContinue: stillConnected,
            systemProxy: nil,
            timeout: 4
        ) else { return false }
        return isConnectivityEvidence(
            statusCode: response.statusCode,
            body: response.body,
            redirectLocation: response.redirectLocation
        )
    }

    static func isConnectivityEvidence(statusCode: Int, body: Data, redirectLocation: String?) -> Bool {
        statusCode == 204 && body.isEmpty && redirectLocation == nil
    }

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
                errors.append("\(routeLabel(route))：\(error)")
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
    private let connectivityCheck: @Sendable (@escaping @Sendable () -> Bool) -> Bool
    private let authenticate: @Sendable (AppConfig, String, @escaping @Sendable () -> Bool) -> (AuthOutcome, String)
    private let cancellation = CancellationSignal()
    private let queue = DispatchQueue(label: "com.nowaywastaken.networkauto.engine", qos: .utility)
    private var state: AppState
    private var running = false
    private var pending = false
    private var scheduled = false
    var onUpdate: (@Sendable (AppState, Bool) -> Void)?

    init(
        store: AppStore,
        snapshot: EngineSnapshot,
        connectivityCheck: @escaping @Sendable (@escaping @Sendable () -> Bool) -> Bool = {
            LoginService.hasInternetConnectivity(stillConnected: $0)
        },
        authenticate: @escaping @Sendable (AppConfig, String, @escaping @Sendable () -> Bool) -> (AuthOutcome, String) = { LoginService.login(config: $0, ip: $1, stillConnected: $2) },
        onUpdate: (@Sendable (AppState, Bool) -> Void)? = nil
    ) {
        self.store = store
        self.logger = LogStore(paths: store.paths)
        self.snapshot = snapshot
        self.connectivityCheck = connectivityCheck
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
        var shouldProbe = !manual
        while !cancellation.isCancelled() {
            let current = snapshot.read()
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
            let key = network.key
            if state.network != key {
                state.network = key
                state.failureSince = nil
                state.notified = false
                shouldProbe = !manual
            }

            let stillConnected: @Sendable () -> Bool = { [snapshot, cancellation] in
                guard !cancellation.isCancelled() else { return false }
                let current = snapshot.read()
                return current.permissionAuthorized && selectNetwork(current.networks)?.key == key
            }
            if shouldProbe {
                if connectivityCheck(stillConnected) {
                    state.attempt = 0
                    record(phase: "online", detail: "互联网连接正常。")
                    return
                }
                shouldProbe = false
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
            state.phase = "login"
            state.detail = "正在登录校园网…"
            publish(state: state, shouldNotify: false)

            let outcome = authenticate(config, network.ip ?? "", stillConnected)
            switch outcome.0 {
            case .online:
                state.route = outcome.1
                record(phase: "online", detail: "登录成功或已经在线。")
                return
            case .credentials:
                state.route = outcome.1
                state.credentialsBlocked = true
                record(phase: "credentials", detail: "认证信息被拒绝，请在设置中修改，或点击立即登录重试。")
                return
            case .retry(let detail):
                state.route = outcome.1
                record(phase: "retry", detail: detail)
                continue
            case .networkChanged:
                state.route = outcome.1
                record(phase: "retry", detail: "网络已变化，重新检查。")
                continue
            }
        }
    }

    private func record(phase: String, detail: String) {
        let oldNotified = state.notified
        let changed = state.transition(phase: phase, detail: detail, now: Int64(Date().timeIntervalSince1970))
        let shouldNotify = !oldNotified && state.notified
        if changed { logger.append(state: state) }
        if changed || shouldNotify {
            store.saveState(state)
            publish(state: state, shouldNotify: shouldNotify)
        }
    }

    private func publish(state: AppState, shouldNotify: Bool) {
        onUpdate?(state, shouldNotify)
    }
}

func updatePublishedAgo(_ date: Date, now: Date = Date()) -> String {
    let elapsed = now.timeIntervalSince(date)
    guard elapsed.isFinite, elapsed >= 10 else { return "刚刚" }
    var remaining = elapsed >= TimeInterval(Int64.max) ? Int64.max : Int64(elapsed)
    let units: [(Int64, String)] = [
        (365 * 86400, "年"), (86400, "天"), (3600, "小时"), (60, "分钟"), (1, "秒")
    ]
    var parts: [String] = []
    for (seconds, name) in units {
        let count = remaining / seconds
        if count > 0 {
            parts.append("\(count) \(name)")
            remaining %= seconds
        }
        if parts.count == 2 { break }
    }
    return parts.joined(separator: " ") + "前"
}

@MainActor
final class AppModel: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    static let shared = AppModel()

    @Published private(set) var config: AppConfig
    @Published private(set) var state: AppState
    @Published private(set) var internetConnected = false
    @Published private(set) var permissionStatus: CLAuthorizationStatus
    @Published private(set) var networks: [WiFiNetwork] = []
    @Published private(set) var diagnosticText = ""
    @Published private(set) var updateStatus = AppUpdateStatus.idle
    @Published private var updateNow = Date()

    private let store: AppStore
    private let updater = AppUpdater()
    private let locationManager = CLLocationManager()
    private let wifiMonitor = WiFiMonitor()
    private let engineSnapshot = EngineSnapshot()
    private let pathMonitor = NWPathMonitor(requiredInterfaceType: .wifi)
    private let pathQueue = DispatchQueue(label: "com.nowaywastaken.networkauto.path")
    private var updateCheckTimer: Timer?
    private var updateDisplayTimer: Timer?
    private var lastUpdatePublishedAt: Date?
    private var connectivityTimer: Timer?
    private let internetQueue = DispatchQueue(label: "com.nowaywastaken.networkauto.internet", qos: .utility)
    private var internetProbeRunning = false
    private var started = false
    private var isCheckingForUpdate = false
    private var isInstallingUpdate = false
    private var manualCheckRequested = false

    private lazy var engine: AutoLoginEngine = {
        AutoLoginEngine(
            store: store,
            snapshot: engineSnapshot,
            onUpdate: { [weak self] state, shouldNotify in
                Task { @MainActor [weak self] in
                    self?.apply(state: state, shouldNotify: shouldNotify)
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

        wifiMonitor.onChange = { [weak self] in
            Task { @MainActor [weak self] in self?.requestCheck() }
        }
        wifiMonitor.start()
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor [weak self] in self?.requestCheck() }
        }
        pathMonitor.start(queue: pathQueue)
        let updateCheckTimer = Timer(timeInterval: 3 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkForUpdates(silently: true) }
        }
        RunLoop.main.add(updateCheckTimer, forMode: .common)
        self.updateCheckTimer = updateCheckTimer
        let updateDisplayTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateNow = Date() }
        }
        RunLoop.main.add(updateDisplayTimer, forMode: .common)
        self.updateDisplayTimer = updateDisplayTimer
        let connectivityTimer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.requestCheck()
            }
        }
        RunLoop.main.add(connectivityTimer, forMode: .common)
        self.connectivityTimer = connectivityTimer
        probeInternet()
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

    func stop() {
        updateCheckTimer?.invalidate()
        updateCheckTimer = nil
        updateDisplayTimer?.invalidate()
        updateDisplayTimer = nil
        connectivityTimer?.invalidate()
        connectivityTimer = nil
        pathMonitor.cancel()
        wifiMonitor.stop()
        engine.stop()
        updater.cancel()
    }

    func requestCheck() {
        probeInternet()
        refreshNetworks()
        engine.request()
    }

    private func probeInternet() {
        guard !internetProbeRunning else { return }
        internetProbeRunning = true
        internetQueue.async { [weak self] in
            let connected = LoginService.hasInternetConnectivity(stillConnected: { true })
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.internetProbeRunning = false
                self.internetConnected = connected
            }
        }
    }

    func checkNow() {
        manualCheckRequested = true
        diagnosticText = "正在检查…"
        probeInternet()
        refreshNetworks()
        engine.checkNow()
    }

    func saveConfig(_ newConfig: AppConfig) {
        guard let error = newConfig.validationError() else {
            do {
                try store.saveConfig(newConfig)
                config = newConfig
                diagnosticText = "配置已保存。"
                engine.request()
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

    func checkForUpdatesNow() {
        checkForUpdates(silently: false)
    }

    var updateMenuTitle: String {
        if isInstallingUpdate { return "正在安装更新…" }
        guard case .available = updateStatus, let lastUpdatePublishedAt else {
            return updateStatus.title
        }
        return "\(updateStatus.title) · \(updatePublishedAgo(lastUpdatePublishedAt, now: updateNow))发布"
    }

    var updateActionEnabled: Bool {
        !isInstallingUpdate && updateStatus.isInteractive
    }

    private func checkForUpdates(silently: Bool) {
        guard !isCheckingForUpdate, !isInstallingUpdate else { return }
        isCheckingForUpdate = true
        updateStatus = .checking
        updater.check { [weak self] result in
            guard let self else { return }
            isCheckingForUpdate = false

            switch result {
            case .success(let update):
                lastUpdatePublishedAt = update?.publishedAt
                guard let update else {
                    updateStatus = .latest
                    if !silently {
                        showUpdateAlert(title: "已是最新版本", message: "当前已是最新版本。")
                    }
                    return
                }
                updateStatus = .available(String(update.revision.prefix(7)))
                if !silently {
                    presentUpdate(update)
                }
            case .failure(let error):
                lastUpdatePublishedAt = nil
                updateStatus = .failed
                if !silently {
                    showUpdateAlert(title: "检查更新失败", message: error.localizedDescription)
                }
            }
        }
    }

    private func presentUpdate(_ update: AppUpdate) {
        let alert = NSAlert()
        alert.messageText = "发现 Csust-Network-Automation 新版本"
        let revision = update.revision == "unknown"
            ? ""
            : "\n构建提交：\(update.revision.prefix(7))"
        alert.informativeText = "\(update.name)\(revision)\n是否下载并安装？"
        alert.addButton(withTitle: "更新")
        alert.addButton(withTitle: "稍后")
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let choice = alert.runModal()
        (NSApp.delegate as? AppDelegate)?.refreshActivationPolicy()
        guard choice == .alertFirstButtonReturn else { return }

        isInstallingUpdate = true
        updater.downloadAndInstall(update) { [weak self] result in
            guard let self else { return }
            if case .failure(let error) = result {
                isInstallingUpdate = false
                showUpdateAlert(title: "安装更新失败", message: error.localizedDescription)
            }
        }
    }

    private func showUpdateAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        (NSApp.delegate as? AppDelegate)?.refreshActivationPolicy()
    }

    var statusText: String {
        if permissionStatus != .authorized {
            switch permissionStatus {
            case .notDetermined: return "等待定位权限"
            case .denied, .restricted: return "需要定位权限"
            default: return "需要定位权限"
            }
        }
        if state.checking {
            return "正在检查…"
        }
        return state.detail.isEmpty ? "尚无检查记录" : state.detail
    }

    private func apply(state: AppState, shouldNotify: Bool) {
        self.state = state
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
        networks = wifiMonitor.networks()
        engineSnapshot.update(
            networks: networks,
            permissionAuthorized: isLocationAuthorized
        )
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
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
private final class StatusBarController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let item = NSStatusBar.system.statusItem(withLength: 28)
    private let icon = NSImageView(frame: .zero)
    private let menu = NSMenu()
    private var connectivitySubscription: AnyCancellable?
    private var timer: Timer?
    private var animationTimer: Timer?
    private var campusItem: NSMenuItem?
    private var googleItem: NSMenuItem?
    private var updateItem: NSMenuItem?
    private var online: Bool

    init(model: AppModel) {
        self.model = model
        online = hasInternetEvidence(
            google: model.internetConnected,
            networks: model.networks,
            state: model.state
        )
        super.init()
        item.autosaveName = "NetworkAuto"
        guard let button = item.button else { return }
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
        connectivitySubscription = Publishers.CombineLatest3(
            model.$internetConnected,
            model.$networks,
            model.$state
        )
        .map { google, networks, state in
            hasInternetEvidence(google: google, networks: networks, state: state)
        }
        .removeDuplicates()
        .sink { [weak self] online in self?.setConnectivity(online) }
    }

    func stop() {
        timer?.invalidate()
        animationTimer?.invalidate()
        connectivitySubscription?.cancel()
        NSStatusBar.system.removeStatusItem(item)
    }

    private func symbol(_ name: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: name)!
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
                    .applying(.preferringHierarchical())
            )!
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
        googleItem?.title = "Google：\(model.internetConnected ? "已连接" : "未连接")"
        updateItem?.title = model.updateMenuTitle
        updateItem?.isEnabled = model.updateActionEnabled
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
        googleItem = menu.items.last
        menu.addItem(.separator())
        action("立即登录校园网", #selector(checkNow))
        menu.addItem(.separator())
        updateItem = action(model.updateMenuTitle, #selector(checkForUpdates))
        updateItem?.isEnabled = model.updateActionEnabled
        action("设置", #selector(openSettings))
        action("退出", #selector(quit))
        refreshMenu()
    }

    @objc private func checkNow() { model.checkNow() }
    @objc private func openSettings() { (NSApp.delegate as? AppDelegate)?.openSettingsWindow() }
    @objc private func checkForUpdates() { model.checkForUpdatesNow() }
    @objc private func quit() { model.quit() }
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

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
        AppModel.shared.stop()
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
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = appDisplayName
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
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
        let statusBar = StatusBarController(model: .shared)
        let menu = NSMenu()
        statusBar.menuNeedsUpdate(menu)
        precondition(menu.items.count == 8)
        precondition(menu.items[0].title.hasPrefix("校园网："))
        precondition(menu.items[1].title.hasPrefix("Google："))
        precondition(menu.items[2].isSeparatorItem && menu.items[4].isSeparatorItem)
        precondition(menu.items[3].title == "立即登录校园网" && menu.items[3].isEnabled)
        precondition(menu.items[5].title == "检查更新" && menu.items[5].isEnabled)
        precondition(menu.items[6].title == "设置" && menu.items[6].isEnabled)
        precondition(menu.items[7].title == "退出" && menu.items[7].isEnabled)
        (NSApp.delegate as? AppDelegate)?.refreshActivationPolicy()
        precondition(NSApp.activationPolicy() == .accessory)
        statusBar.stop()
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
        precondition(LoginService.isConnectivityEvidence(statusCode: 204, body: Data(), redirectLocation: nil))
        precondition(!LoginService.isConnectivityEvidence(statusCode: 200, body: Data(), redirectLocation: nil))
        precondition(!LoginService.isConnectivityEvidence(statusCode: 302, body: Data(), redirectLocation: "https://portal.example"))
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
        precondition(!hasInternetEvidence(google: true, networks: [campus], state: campusState))
        campusState.phase = "online"
        precondition(hasInternetEvidence(google: true, networks: [campus], state: campusState))
        precondition(!hasInternetEvidence(google: false, networks: [campus], state: campusState))
        let otherWiFi = WiFiNetwork(interfaceName: "en0", ssid: "other", bssid: "bb", ip: "192.0.2.2")
        precondition(hasInternetEvidence(google: true, networks: [otherWiFi], state: campusState))
        precondition(!hasInternetEvidence(google: false, networks: [otherWiFi], state: campusState))
        precondition(config.validationError() == nil)
        let encodedConfig = try! JSONEncoder().encode(config)
        precondition(String(decoding: encodedConfig, as: UTF8.self).contains(config.password))
        precondition(!String(decoding: encodedConfig, as: UTF8.self).contains("timeout"))
        var changedConfig = config
        changedConfig.password = "different"
        precondition(configFingerprint(config) != configFingerprint(changedConfig))
        precondition(AppUpdateStatus.latest.title == "检查更新")
        precondition(AppUpdateStatus.failed.title == "检查更新")
        precondition(updatePublishedAgo(Date(timeIntervalSince1970: 0), now: Date(timeIntervalSince1970: 438)) == "7 分钟 18 秒前")
        updateParsing()
        storeMigrationAndPersistence()
        engineCancellationAndMutex()
        manualLoginBypassesConnectivity()
        httpLogin(proxy: false)
        httpLogin(proxy: true)
        print("NetworkAuto self-test passed")
    }

    private static func updateParsing() {
        let revision = String(repeating: "a", count: 40)
        let digest = String(repeating: "0", count: 64)
        let data = Data(
            """
            {
              "name": "autobuild",
              "published_at": "2026-09-07T00:00:00Z",
              "target_commitish": "\(revision)",
              "body": "",
              "assets": [{
                "name": "NetworkAuto.app.tar",
                "browser_download_url": "https://github.com/notCorwin/Csust-Network-Automation/releases/download/autobuild/NetworkAuto.app.tar",
                "digest": "sha256:\(digest)"
              }]
            }
            """.utf8
        )
        precondition(AppUpdater.revision(in: "commit \(revision)") == revision)
        precondition(
            AppUpdater.archiveAppRoot(
                from: "NetworkAuto.app/Contents/MacOS/NetworkAuto"
            ) == "NetworkAuto.app"
        )
        precondition(
            AppUpdater.archiveAppRoot(from: "../NetworkAuto.app/Contents") == nil
        )
        precondition(
            AppUpdater.archiveContainsUnsafeEntry(
                in: "lrwxr-xr-x  0 user  wheel  0 Jan 1 00:00 Link -> /tmp"
            )
        )
        precondition(
            !AppUpdater.archiveExceedsSizeLimit(
                in: "-rw-r--r--  0 user  wheel  268435456 Jan 1 00:00 file"
            )
        )
        guard case .success(let update) = AppUpdater.parse(data: data, currentRevision: "development"),
              let update else {
            preconditionFailure("release metadata must parse")
        }
        precondition(update.revision == revision)
        precondition(update.expectedSHA256 == digest)
        precondition(update.publishedAt == Date(timeIntervalSince1970: 1_788_739_200))
        guard case .success(nil) = AppUpdater.parse(data: data, currentRevision: revision) else {
            preconditionFailure("same revision must not update")
        }
        let missingDigest = Data(String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\"digest\": \"sha256:\(digest)\"", with: "\"digest\": null").utf8)
        guard case .failure(.invalidResponse) = AppUpdater.parse(data: missingDigest, currentRevision: "development") else {
            preconditionFailure("release without SHA-256 must be rejected")
        }
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
            let permissionEngine = AutoLoginEngine(store: store, snapshot: permissionSnapshot, onUpdate: { state, _ in
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
        let engine = AutoLoginEngine(store: store, snapshot: snapshot, onUpdate: { state, _ in
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
        let authentication = LockedString()
        let completed = DispatchSemaphore(value: 0)
        let engine = AutoLoginEngine(
            store: store,
            snapshot: snapshot,
            connectivityCheck: { _ in true },
            authenticate: { _, _, _ in
                authentication.set("called")
                return (.online, "direct")
            },
            onUpdate: { state, _ in
                if !state.checking && (state.phase == "online" || state.phase == "outside") { completed.signal() }
            }
        )
        engine.start()
        precondition(completed.wait(timeout: .now() + 3) == .success)
        precondition(authentication.get().isEmpty)
        engine.checkNow()
        precondition(completed.wait(timeout: .now() + 3) == .success)
        precondition(authentication.get() == "called")
        authentication.set("")
        snapshot.update(networks: [WiFiNetwork(interfaceName: "en0", ssid: "other", bssid: nil, ip: nil)], permissionAuthorized: true)
        engine.checkNow()
        precondition(completed.wait(timeout: .now() + 3) == .success)
        precondition(authentication.get().isEmpty)
        engine.stop()
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
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
