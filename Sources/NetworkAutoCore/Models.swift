import CryptoKit
import Darwin
import Foundation

public enum AppConstants {
    public static let displayName = "Csust-Network-Automation"
    public static let bundleIdentifier = "com.nowaywastaken.csustautologin"
    public static let defaultCampusSSID = "CSUST-Student"
    public static let defaultCampusLoginURL = URL(string: "https://login.csust.edu.cn:802/eportal/portal/login")!
    public static let defaultCampusPortalPageURL = URL(string: "https://login.csust.edu.cn")!
    public static let loginRequestTimeoutSecs: TimeInterval = 15
    public static let settingsWindowIdentifier = "com.nowaywastaken.networkauto.settings"
}

public struct AppError: Error, LocalizedError, Sendable, Equatable {
    public let message: String

    public init(message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

public enum AuthPhase: String, Codable, Equatable, Sendable {
    case idle = ""
    case permission
    case outside
    case waitingIP = "waiting_ip"
    case loggingIn = "login"
    case online
    case retry
    case credentials
    case configError = "config_error"
    case offline

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode(String.self)) ?? ""
        self = AuthPhase(rawValue: raw) ?? .idle
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var displayTitle: String {
        switch self {
        case .idle: "待检测"
        case .permission: "需要定位权限"
        case .outside: "未连接校园网"
        case .waitingIP: "等待分配 IP"
        case .loggingIn: "登录中"
        case .online: "已登录"
        case .retry: "重试中"
        case .credentials: "认证失败"
        case .configError: "设置有误"
        case .offline: "离线"
        }
    }
}

public struct AppConfig: Equatable, Sendable {
    public var username: String
    public var password: String
    public var campusSSID: String
    public var loginURLString: String
    public var launchAtLogin: Bool
    public var clashControllerAddress: String

    public static let `default` = AppConfig(
        username: "",
        password: "",
        campusSSID: AppConstants.defaultCampusSSID,
        loginURLString: AppConstants.defaultCampusLoginURL.absoluteString,
        launchAtLogin: true,
        clashControllerAddress: ""
    )

    public init(
        username: String,
        password: String,
        campusSSID: String = AppConstants.defaultCampusSSID,
        loginURLString: String = AppConstants.defaultCampusLoginURL.absoluteString,
        launchAtLogin: Bool = true,
        clashControllerAddress: String = ""
    ) {
        self.username = username
        self.password = password
        self.campusSSID = campusSSID
        self.loginURLString = loginURLString
        self.launchAtLogin = launchAtLogin
        self.clashControllerAddress = clashControllerAddress
    }

    public var trimmedSSID: String {
        let trimmed = campusSSID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? AppConstants.defaultCampusSSID : trimmed
    }

    public var loginURL: URL? {
        let trimmed = loginURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else {
            return nil
        }
        return url
    }

    public var portalPageURL: URL {
        guard let url = loginURL, let host = url.host, !host.isEmpty else {
            return AppConstants.defaultCampusPortalPageURL
        }
        var components = URLComponents()
        components.scheme = url.scheme ?? "https"
        components.host = host
        return components.url ?? AppConstants.defaultCampusPortalPageURL
    }

    public func validationError() -> String? {
        if username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty {
            return "账号或密码为空，请在设置中补充。"
        }
        if campusSSID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "校园网 Wi-Fi 名称不能为空。"
        }
        if loginURL == nil {
            return "认证接口地址无效，请输入有效的 http/https URL。"
        }
        let clashAddr = clashControllerAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clashAddr.isEmpty, ClashEndpoint.parse(clashAddr) == nil {
            return "Clash 控制器地址无效，请输入以 / 开头的 Socket 路径或 http(s) 地址。"
        }
        return nil
    }
}

public struct AppPaths: Sendable {
    public let data: URL
    public let legacyConfig: URL
    public let legacyState: URL
    public let logs: URL

    public init(fileManager: FileManager = .default) {
        let home = fileManager.homeDirectoryForCurrentUser
        data = home.appendingPathComponent("Library/Application Support/csust-auto-login", isDirectory: true)
        legacyConfig = data.appendingPathComponent("config.json")
        legacyState = data.appendingPathComponent("state.json")
        logs = home.appendingPathComponent("Library/Logs/csust-auto-login", isDirectory: true)
    }

    public init(data: URL, legacyConfig: URL, legacyState: URL, logs: URL) {
        self.data = data
        self.legacyConfig = legacyConfig
        self.legacyState = legacyState
        self.logs = logs
    }
}

public func ensurePrivateDirectory(_ url: URL) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
}

public enum AppInstanceLockError: Error, LocalizedError, Equatable {
    case alreadyRunning
    case openFailed(String)
    case lockFailed(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning: return "\(AppConstants.displayName) 已经在运行。"
        case .openFailed(let message): return "无法打开运行锁：\(message)"
        case .lockFailed(let message): return "无法取得运行锁：\(message)"
        }
    }
}

public final class AppInstanceLock: @unchecked Sendable {
    public let descriptor: Int32

    public init(path: URL) throws {
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

public final class CancellationSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    public func isCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

public final class EngineSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var networks: [WiFiNetwork] = []
    private var permissionAuthorized = false
    private var internetConnected = false
    private var generation: UInt64 = 0

    public init() {}

    public func update(networks: [WiFiNetwork], permissionAuthorized: Bool) {
        lock.lock()
        if self.networks != networks {
            internetConnected = false
            generation &+= 1
        }
        self.networks = networks
        self.permissionAuthorized = permissionAuthorized
        lock.unlock()
    }

    public func updateConnectivity(_ connected: Bool) {
        lock.lock()
        internetConnected = connected
        lock.unlock()
    }

    public func invalidateNetwork() {
        lock.lock()
        generation &+= 1
        internetConnected = false
        lock.unlock()
    }

    public func read() -> (networks: [WiFiNetwork], permissionAuthorized: Bool, internetConnected: Bool, generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        return (networks, permissionAuthorized, internetConnected, generation)
    }
}

public struct AppState: Codable, Equatable, Sendable {
    public var phase: AuthPhase = .idle
    public var detail = ""
    public var network = ""
    public var route = ""
    public var checkedAt: Int64 = 0
    public var checking = false
    public var lastSuccess: Int64?
    public var failureSince: Int64?
    public var notified = false
    public var credentialsBlocked = false
    public var configKey = ""
    public var attempt: UInt32 = 0

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

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        phase = try container.decodeIfPresent(AuthPhase.self, forKey: .phase) ?? .idle
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

    @discardableResult
    public mutating func transition(phase: AuthPhase, detail: String, now: Int64) -> Bool {
        let changed = self.phase != phase || self.detail != detail
        let needsAction = phase == .credentials || phase == .configError
        if needsAction && self.phase != phase {
            notified = false
        }
        self.phase = phase
        self.detail = detail
        checkedAt = now
        if phase == .online || phase == .outside || phase == .offline {
            failureSince = nil
            notified = false
        }
        if phase == .online {
            lastSuccess = now
        }
        if phase == .credentials || phase == .configError || phase == .retry {
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

public func routeLabel(_ route: String) -> String {
    switch route {
    case "direct": return "直连"
    case "system": return "系统代理"
    default: return "尚未选择"
    }
}

public func routeNames() -> [String] { ["direct", "system"] }

public func configFingerprint(_ config: AppConfig) -> String {
    let passwordDigest = SHA256.hash(data: Data(config.password.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
    let material = [
        config.username,
        passwordDigest,
        config.trimmedSSID,
        config.loginURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    ].joined(separator: "\u{0}")
    return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
}
