import Foundation
import OSLog

private let configDefaultsKeyV2 = "config.v2"
private let legacyConfigDefaultsKeyV1 = "config.v1"
private let stateDefaultsKey = "state.v1"

private struct StoredPreferences: Codable {
    var username: String
    var campusSSID: String
    var loginURLString: String
    var launchAtLogin: Bool
    var clashControllerAddress: String

    init(from config: AppConfig) {
        username = config.username
        campusSSID = config.trimmedSSID
        loginURLString = config.loginURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        launchAtLogin = config.launchAtLogin
        clashControllerAddress = config.clashControllerAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        campusSSID = try container.decodeIfPresent(String.self, forKey: .campusSSID) ?? AppConstants.defaultCampusSSID
        loginURLString = try container.decodeIfPresent(String.self, forKey: .loginURLString) ?? AppConstants.defaultCampusLoginURL.absoluteString
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? true
        clashControllerAddress = try container.decodeIfPresent(String.self, forKey: .clashControllerAddress) ?? ""
    }
}

private struct LegacyStoredConfig: Decodable {
    let username: String?
    let password: String?
}

public final class AppStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let secretStore: any SecretStore
    public let paths: AppPaths
    private let lock = NSLock()
    private var storedConfig: AppConfig
    private var configError: String?
    private var passwordFallbackURL: URL { paths.data.appendingPathComponent("password") }

    public init(
        defaults: UserDefaults = .standard,
        paths: AppPaths = AppPaths(),
        secretStore: any SecretStore = KeychainSecretStore()
    ) {
        self.defaults = defaults
        self.paths = paths
        self.secretStore = secretStore
        let legacyPasswordURL = paths.data.appendingPathComponent("password")

        var loadedConfig = AppConfig.default
        var legacyPlaintextPassword: String?
        var hadLegacyV1 = false
        var hadLegacyFile = false

        if let data = defaults.data(forKey: configDefaultsKeyV2) {
            do {
                let prefs = try JSONDecoder().decode(StoredPreferences.self, from: data)
                loadedConfig.username = prefs.username
                loadedConfig.campusSSID = prefs.campusSSID
                loadedConfig.loginURLString = prefs.loginURLString
                loadedConfig.launchAtLogin = prefs.launchAtLogin
                loadedConfig.clashControllerAddress = prefs.clashControllerAddress
                configError = nil
            } catch {
                configError = "配置格式错误，无法读取已保存设置。"
            }
        } else if let data = defaults.data(forKey: legacyConfigDefaultsKeyV1) {
            hadLegacyV1 = true
            do {
                let legacy = try JSONDecoder().decode(LegacyStoredConfig.self, from: data)
                loadedConfig.username = legacy.username ?? ""
                if let pw = legacy.password, !pw.isEmpty {
                    legacyPlaintextPassword = pw
                }
                configError = nil
            } catch {
                configError = "配置格式错误，无法读取旧版设置。"
            }
        } else if let data = try? Data(contentsOf: paths.legacyConfig) {
            hadLegacyFile = true
            do {
                let legacy = try JSONDecoder().decode(LegacyStoredConfig.self, from: data)
                loadedConfig.username = legacy.username ?? ""
                if let pw = legacy.password, !pw.isEmpty {
                    legacyPlaintextPassword = pw
                }
                configError = nil
            } catch {
                configError = "旧配置格式错误，无法完成迁移。"
            }
        }

        if configError == nil, legacyPlaintextPassword == nil,
           let data = try? Data(contentsOf: legacyPasswordURL),
           let password = String(data: data, encoding: .utf8),
           !password.isEmpty {
            legacyPlaintextPassword = password
        }

        if configError == nil {
            do {
                let keychainPassword = try secretStore.loadPassword()
                if let keychainPassword, !keychainPassword.isEmpty {
                    loadedConfig.password = keychainPassword
                    // Keychain already holds a password; safe to remove any leftover plaintext stores.
                    if hadLegacyV1 { defaults.removeObject(forKey: legacyConfigDefaultsKeyV1) }
                    if hadLegacyFile { try? FileManager.default.removeItem(at: paths.legacyConfig) }
                    try? FileManager.default.removeItem(at: legacyPasswordURL)
                } else if let legacyPlaintextPassword {
                    loadedConfig.password = legacyPlaintextPassword
                    try secretStore.savePassword(legacyPlaintextPassword)
                    if let encoded = try? JSONEncoder().encode(StoredPreferences(from: loadedConfig)) {
                        defaults.set(encoded, forKey: configDefaultsKeyV2)
                    }
                    defaults.removeObject(forKey: legacyConfigDefaultsKeyV1)
                    try? FileManager.default.removeItem(at: paths.legacyConfig)
                    try? FileManager.default.removeItem(at: legacyPasswordURL)
                } else if hadLegacyV1 || hadLegacyFile {
                    if let encoded = try? JSONEncoder().encode(StoredPreferences(from: loadedConfig)) {
                        defaults.set(encoded, forKey: configDefaultsKeyV2)
                    }
                    defaults.removeObject(forKey: legacyConfigDefaultsKeyV1)
                    try? FileManager.default.removeItem(at: paths.legacyConfig)
                }
            } catch {
                // Preserve loaded plaintext password in memory so we do not lose credentials if Keychain fails.
                if let legacyPlaintextPassword {
                    loadedConfig.password = legacyPlaintextPassword
                } else {
                    configError = error.localizedDescription
                }
            }
        }

        storedConfig = loadedConfig
    }

    public func config() -> Result<AppConfig, AppError> {
        lock.lock()
        defer { lock.unlock() }
        if let configError {
            return .failure(AppError(message: configError))
        }
        return .success(storedConfig)
    }

    public func effectiveConfig() -> Result<AppConfig, AppError> {
        switch config() {
        case .failure(let error):
            return .failure(error)
        case .success(let config):
            if let error = config.validationError() {
                return .failure(AppError(message: error))
            }
            return .success(config)
        }
    }

    public func saveConfig(_ config: AppConfig) throws {
        if let error = config.validationError() {
            throw StoreError.invalidConfig(error)
        }
        let encoded = try JSONEncoder().encode(StoredPreferences(from: config))
        try secretStore.savePassword(config.password)
        lock.lock()
        defer { lock.unlock() }
        storedConfig = config
        configError = nil
        defaults.set(encoded, forKey: configDefaultsKeyV2)
        defaults.removeObject(forKey: legacyConfigDefaultsKeyV1)
        try? FileManager.default.removeItem(at: paths.legacyConfig)
        try? FileManager.default.removeItem(at: passwordFallbackURL)
    }

    public func loadState() -> AppState {
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

    public func saveState(_ state: AppState) {
        lock.lock()
        defer { lock.unlock() }
        if let encoded = try? JSONEncoder().encode(state) {
            defaults.set(encoded, forKey: stateDefaultsKey)
        }
    }

    public enum StoreError: LocalizedError, Equatable {
        case invalidConfig(String)

        public var errorDescription: String? {
            switch self {
            case .invalidConfig(let reason): return reason
            }
        }
    }
}

public final class LogStore: @unchecked Sendable {
    private let paths: AppPaths
    private let lock = NSLock()
    private let osLogger = Logger(subsystem: AppConstants.bundleIdentifier, category: "network")
    private let timestampFormatter: DateFormatter
    private var lastCleanupDay: String?
    private var directoryPrepared = false
    private var recentLines: [String] = []
    private let maxRecentLines = 30

    public init(paths: AppPaths) {
        self.paths = paths
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        self.timestampFormatter = formatter
    }

    public func append(state: AppState) {
        let message = "[\(state.phase.rawValue.isEmpty ? "idle" : state.phase.rawValue)] \(routeLabel(state.route)) / \(state.detail)"
        append(rawMessage: message)
    }

    public func append(rawMessage: String) {
        osLogger.info("\(rawMessage, privacy: .public)")
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        let timestamp = timestampFormatter.string(from: now)
        let day = String(timestamp.prefix(10))
        let line = "\(timestamp) \(rawMessage)"
        recentLines.append(line)
        if recentLines.count > maxRecentLines {
            recentLines.removeFirst(recentLines.count - maxRecentLines)
        }
        do {
            if !directoryPrepared || !FileManager.default.fileExists(atPath: paths.logs.path) {
                try ensurePrivateDirectory(paths.logs)
                directoryPrepared = true
            }
            if lastCleanupDay != day {
                cleanup(now: now)
                lastCleanupDay = day
            }
            let file = paths.logs.appendingPathComponent("\(day).log")
            if !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((line + "\n").utf8))
        } catch {
            osLogger.error("日志写入失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    public func recentEntries(limit: Int = 15) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(recentLines.suffix(max(0, limit)))
    }

    private func cleanup(now: Date) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: paths.logs,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for entry in entries where entry.pathExtension == "log" {
            guard let values = try? entry.resourceValues(forKeys: [.contentModificationDateKey]),
                  let date = values.contentModificationDate,
                  now.timeIntervalSince(date) > 7 * 86400 else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }
}
