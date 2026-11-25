import Foundation

public enum AuthOutcome: Equatable, Sendable {
    case online
    case credentials
    case retry(String)
    case networkChanged
}

private final class LoginSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var storedRedirectLocation: String?

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        lock.withLock {
            storedRedirectLocation = response.value(forHTTPHeaderField: "Location")
        }
        return nil
    }

    func redirectLocation() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storedRedirectLocation
    }
}

private struct HTTPResult: Sendable {
    let statusCode: Int
    let body: Data
    let redirectLocation: String?
}

public enum LoginService {
    /// Unreserved RFC 3986 characters (`A-Z`, `a-z`, `0-9`, `-`, `.`, `_`, `~`).
    /// Explicitly excludes `+`, `&`, `=`, `#`, `?`, `%`, and spaces so Dr.COM's
    /// `application/x-www-form-urlencoded` parser never turns `+` into a space.
    private static let formComponentAllowed: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return set
    }()

    public static func percentEncodeQueryComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: formComponentAllowed) ?? value
    }

    public static func makeRequest(
        url: URL,
        parameters: [(String, String)],
        referer: String
    ) -> URLRequest? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.percentEncodedQuery = parameters
            .map { "\(percentEncodeQueryComponent($0.0))=\(percentEncodeQueryComponent($0.1))" }
            .joined(separator: "&")
        guard let requestURL = components.url else { return nil }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        return request
    }

    public static func login(
        config: AppConfig,
        ip: String,
        stillConnected: @escaping @Sendable () -> Bool,
        serverURL: URL? = nil,
        systemProxy: URL? = nil,
        timeout: TimeInterval = AppConstants.loginRequestTimeoutSecs
    ) async -> (AuthOutcome, String) {
        if let error = config.validationError() {
            return (.retry(error), "")
        }
        guard let targetURL = serverURL ?? config.loginURL else {
            return (.retry("认证地址无效"), "")
        }
        let account = ",0,\(config.username.trimmingCharacters(in: .whitespacesAndNewlines))"
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
        let referer = originURLString(targetURL)
        var errors: [String] = []
        var lastRoute = ""

        for route in routeNames() {
            if !stillConnected() || Task.isCancelled { return (.networkChanged, lastRoute) }
            lastRoute = route
            guard let request = makeRequest(
                url: targetURL,
                parameters: parameters,
                referer: referer
            ) else {
                errors.append("认证地址无效")
                continue
            }
            switch await perform(
                request: request,
                route: route,
                shouldContinue: stillConnected,
                systemProxy: systemProxy,
                timeout: timeout
            ) {
            case .failure(let error):
                if !stillConnected() || Task.isCancelled { return (.networkChanged, lastRoute) }
                errors.append("\(routeLabel(route))：\(error.message)")
            case .success(let response):
                if !stillConnected() || Task.isCancelled { return (.networkChanged, lastRoute) }
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
            .retry(errors.isEmpty ? "认证失败，将自动重试。" : errors.joined(separator: "；")),
            lastRoute
        )
    }

    private static func perform(
        request: URLRequest,
        route: String,
        shouldContinue: @escaping @Sendable () -> Bool,
        systemProxy: URL?,
        timeout: TimeInterval
    ) async -> Result<HTTPResult, AppError> {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.waitsForConnectivity = false
        sessionConfiguration.timeoutIntervalForRequest = timeout
        sessionConfiguration.timeoutIntervalForResource = timeout
        sessionConfiguration.httpShouldSetCookies = false
        sessionConfiguration.urlCache = nil
        sessionConfiguration.httpCookieStorage = nil

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

        let delegate = LoginSessionDelegate()
        let session = URLSession(configuration: sessionConfiguration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let watchdog = Task {
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int((timeout + 1) * 1000)))
            while !Task.isCancelled {
                if !shouldContinue() || ContinuousClock.now >= deadline {
                    session.invalidateAndCancel()
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        defer { watchdog.cancel() }

        do {
            let (data, response) = try await session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let redirectLocation = delegate.redirectLocation() {
                return .success(HTTPResult(
                    statusCode: statusCode == 0 ? 302 : statusCode,
                    body: data,
                    redirectLocation: redirectLocation
                ))
            }
            if statusCode == 0 {
                return .failure(AppError(message: "连接中断"))
            }
            return .success(HTTPResult(statusCode: statusCode, body: data, redirectLocation: nil))
        } catch {
            if !shouldContinue() || Task.isCancelled {
                return .failure(AppError(message: "检查已停止"))
            }
            return .failure(AppError(message: connectionError(error)))
        }
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

public func parseResponse(_ text: String) -> AuthOutcome {
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
