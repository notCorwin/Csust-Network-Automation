import Darwin
import Foundation
import HotspotCore

public enum InternetStatus: Equatable, Sendable {
    case online
    case dnsStalled
    case unknown
    case clashUnavailable
    case offline

    public var title: String {
        switch self {
        case .online: "已连接"
        case .dnsStalled: "异常（DNS 连接停滞）"
        case .unknown: "检测中（暂无近期流量）"
        case .clashUnavailable: "Clash 未就绪"
        case .offline: "未连接"
        }
    }

    public var isConnected: Bool {
        self == .online
    }

    public var detail: String {
        switch self {
        case .dnsStalled:
            "检测到持续多秒无响应的重复 Clash 内部 DNS 连接，正在清理异常 DNS 连接。"
        case .online:
            "已通过 Clash 代理流量或轻量连通性探测确认互联网可达。"
        case .clashUnavailable:
            "未连接到本地 Clash 控制器，已自动回退为轻量连通性探测。"
        case .offline:
            "网络路径不可用或连续连通性探测失败。"
        case .unknown:
            "等待代理流量变化或轻量连通性探测结果；没有流量不代表断网。"
        }
    }
}

public enum ClashEndpoint: Equatable, Hashable, Sendable {
    case unixSocket(String)
    case http(URL, secret: String?)

    public var displayDescription: String {
        switch self {
        case .unixSocket(let path):
            return "Unix Socket (\(URL(fileURLWithPath: path).lastPathComponent))"
        case .http(let url, _):
            return url.absoluteString
        }
    }

    public static func parse(_ raw: String, secret: String? = nil) -> ClashEndpoint? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\r"), !trimmed.contains("\n") else { return nil }
        if trimmed.hasPrefix("/") {
            return .unixSocket(trimmed)
        }
        let candidateString: String
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            candidateString = trimmed
        } else if trimmed.contains(":") {
            candidateString = "http://\(trimmed)"
        } else {
            return nil
        }
        guard let url = URL(string: candidateString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else {
            return nil
        }
        return .http(url, secret: secret)
    }
}

public struct ClashConnectivityDiagnostics: Equatable, Sendable {
    public var status: InternetStatus = .unknown
    public var sourceDescription = "等待初始化…"
    public var endpointDescription: String?
    public var activeConnectionCount: Int?
    public var stalledDNSCount = 0
    public var lastVerifiedAt: Date?

    public init() {}
}

public struct ClashConnections: Decodable, Sendable {
    public let downloadTotal: Int64
    public let connections: [Connection]?

    public init(downloadTotal: Int64, connections: [Connection]?) {
        self.downloadTotal = downloadTotal
        self.connections = connections
    }

    public struct Connection: Decodable, Sendable {
        public let id: String
        public let metadata: Metadata
        public let download: Int64
        public let upload: Int64
        public let chains: [String]

        public init(id: String, metadata: Metadata, download: Int64, upload: Int64, chains: [String]) {
            self.id = id
            self.metadata = metadata
            self.download = download
            self.upload = upload
            self.chains = chains
        }

        public struct Metadata: Decodable, Sendable {
            public let host: String
            public let destinationPort: String
            public let network: String
            public let type: String
            public let destinationIP: String?

            public init(host: String, destinationPort: String, network: String, type: String, destinationIP: String?) {
                self.host = host
                self.destinationPort = destinationPort
                self.network = network
                self.type = type
                self.destinationIP = destinationIP
            }
        }

        // Mihomo does not identify DNS requests in /connections; internal connections
        // on DNS/HTTPS ports are the available passive DNS candidates.
        public var isDNSCandidate: Bool {
            metadata.type == "Inner"
                && ["53", "443", "853"].contains(metadata.destinationPort)
                && ["tcp", "udp"].contains(metadata.network.lowercased())
                && metadata.destinationIP?.isEmpty == false
                && !Self.isLocalAddress(metadata.destinationIP)
                && !chains.contains(where: { ["REJECT", "REJECT-DROP"].contains($0.uppercased()) })
        }

        // Reuse Clash's actual routing decision instead of maintaining a domain list.
        // A connection or uploaded bytes alone do not prove that a remote server replied.
        public var isInternetCandidate: Bool {
            guard let outbound = chains.first?.uppercased(),
                  !["DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE"].contains(outbound),
                  metadata.destinationPort == "443",
                  ["tcp", "udp"].contains(metadata.network.lowercased()) else { return false }
            let host = metadata.host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return host.contains(".") && !host.contains(":")
                && !host.allSatisfy({ $0.isNumber || $0 == "." })
                && ![".local", ".lan", ".internal", ".localhost"].contains(where: host.hasSuffix)
                && host != "csust.edu.cn" && !host.hasSuffix(".csust.edu.cn")
                && !Self.isLocalAddress(metadata.destinationIP)
        }

        private static func isLocalAddress(_ value: String?) -> Bool {
            guard let value, !value.isEmpty else { return false }
            // FakeIP is metadata for the original domain, not a LAN destination.
            let parts = value.split(separator: ".").compactMap { UInt8($0) }
            if parts.count == 4 {
                let a = parts[0], b = parts[1]
                return a == 0 || a == 10 || a == 127 || a >= 224
                    || (a == 100 && (64...127).contains(b))
                    || (a == 169 && b == 254) || (a == 172 && (16...31).contains(b))
                    || (a == 192 && b == 168)
            }
            if value.contains(":") {
                var address = in6_addr()
                guard inet_pton(AF_INET6, value, &address) == 1 else { return true }
                let bytes = withUnsafeBytes(of: address) { Array($0) }
                if bytes.prefix(12) == Array(repeating: UInt8(0), count: 10) + [255, 255] {
                    return isLocalAddress(bytes.suffix(4).map(String.init).joined(separator: "."))
                }
                return bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes.last! <= 1
                    || bytes[0] & 0xfe == 0xfc || bytes[0] == 0xff
                    || (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80)
            }
            return true
        }
    }
}

public struct ClashObservation: Equatable, Sendable {
    public let status: InternetStatus
    public let stalledDNSConnectionIDs: [String]
    public let activeConnectionCount: Int
}

public struct ClashTrafficEvidence: Sendable {
    public static let lifetime: TimeInterval = 30
    public static let duplicateDNSSustainDuration: TimeInterval = 3
    private var downloads: [String: Int64] = [:]
    private var dnsDownloads: [String: Int64] = [:]
    private var duplicateDNSSince: TimeInterval?
    private var hasSustainedDuplicateDNS = false
    private var lastStalledDNSIDs: [String] = []
    private var total: Int64?
    private var lastReply: TimeInterval?

    private struct DNSDestination: Hashable {
        let ip: String
        let port: String
        let network: String
    }

    public init() {}

    public mutating func reset() {
        downloads.removeAll(keepingCapacity: true)
        dnsDownloads.removeAll(keepingCapacity: true)
        duplicateDNSSince = nil
        hasSustainedDuplicateDNS = false
        lastStalledDNSIDs = []
        total = nil
        lastReply = nil
    }

    public mutating func observeDetailed(_ snapshot: ClashConnections, now: TimeInterval) -> ClashObservation {
        if let total, snapshot.downloadTotal < total { reset() }
        let baselineExists = total != nil
        let allConnections = snapshot.connections ?? []
        var nextDownloads: [String: Int64] = [:]
        var nextDNSDownloads: [String: Int64] = [:]
        var dnsByDestination: [DNSDestination: [ClashConnections.Connection]] = [:]

        for connection in allConnections {
            if connection.isInternetCandidate {
                let previous = downloads[connection.id] ?? 0
                if baselineExists && connection.download > previous { lastReply = now }
                nextDownloads[connection.id] = connection.download
            }
            if connection.isDNSCandidate {
                let destination = DNSDestination(
                    ip: connection.metadata.destinationIP!.lowercased(),
                    port: connection.metadata.destinationPort,
                    network: connection.metadata.network.lowercased()
                )
                dnsByDestination[destination, default: []].append(connection)
                nextDNSDownloads[connection.id] = connection.download
            }
        }

        // Only treat duplicate DNS connections as stalled if they make no download progress.
        // Active DoH/DoT pooled connections with growing download counters are healthy.
        var stagnantDuplicateIDs: [String] = []
        for (_, group) in dnsByDestination where group.count >= 2 {
            let groupMadeProgress = group.contains { conn in
                guard let previous = dnsDownloads[conn.id] else { return false }
                return conn.download > previous
            }
            if !groupMadeProgress {
                stagnantDuplicateIDs.append(contentsOf: group.map(\.id))
            }
        }
        stagnantDuplicateIDs.sort()

        downloads = nextDownloads
        dnsDownloads = nextDNSDownloads

        if !stagnantDuplicateIDs.isEmpty {
            let since = duplicateDNSSince ?? now
            duplicateDNSSince = since
            hasSustainedDuplicateDNS = now >= since && (now - since) >= Self.duplicateDNSSustainDuration
            lastStalledDNSIDs = hasSustainedDuplicateDNS ? stagnantDuplicateIDs : []
        } else {
            duplicateDNSSince = nil
            hasSustainedDuplicateDNS = false
            lastStalledDNSIDs = []
        }
        // Only traffic received after the sustained duplicate connections clear can confirm recovery.
        if hasSustainedDuplicateDNS { lastReply = nil }
        total = snapshot.downloadTotal
        return ClashObservation(
            status: status(now: now),
            stalledDNSConnectionIDs: lastStalledDNSIDs,
            activeConnectionCount: allConnections.count
        )
    }

    public mutating func observe(_ snapshot: ClashConnections, now: TimeInterval) -> InternetStatus {
        observeDetailed(snapshot, now: now).status
    }

    public func status(now: TimeInterval) -> InternetStatus {
        if hasSustainedDuplicateDNS { return .dnsStalled }
        let connected = lastReply.map { now >= $0 && now - $0 < Self.lifetime } ?? false
        return connected ? .online : .unknown
    }
}

/// Local IPC/HTTP controller client for Mihomo / Clash cores.
public enum ClashController {
    public static let maximumResponseSize = 8 * 1024 * 1024

    public static func endpoints(overrideAddress: String = "") -> [ClashEndpoint] {
        var result: [ClashEndpoint] = []
        func appendIfValid(_ endpoint: ClashEndpoint) {
            switch endpoint {
            case .unixSocket(let path):
                guard isSocket(path) else { return }
            case .http:
                break
            }
            if !result.contains(endpoint) {
                result.append(endpoint)
            }
        }

        if let custom = ClashEndpoint.parse(overrideAddress) {
            appendIfValid(custom)
        }

        let servicePath = "/var/run/clash-verge-service/users/\(getuid())/verge-mihomo.sock"
        appendIfValid(.unixSocket(servicePath))

        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidateConfigs = [
            home.appendingPathComponent("Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/clash-verge.yaml"),
            home.appendingPathComponent("Library/Application Support/mihomo-party/work/config.yaml"),
            home.appendingPathComponent(".config/mihomo/config.yaml")
        ]
        for config in candidateConfigs {
            guard let text = try? String(contentsOf: config, encoding: .utf8) else { continue }
            if let path = configuredSocket(in: text) {
                appendIfValid(.unixSocket(path))
            }
            if let httpEndpoint = configuredHTTPEndpoint(in: text) {
                appendIfValid(httpEndpoint)
            }
        }

        return result
    }

    public static func configuredSocket(in text: String) -> String? {
        guard let value = yamlTopLevelValue(forKey: "external-controller-unix", in: text) else { return nil }
        return value.hasPrefix("/") && !value.contains("\r") && !value.contains("\n") ? value : nil
    }

    public static func configuredHTTPEndpoint(in text: String) -> ClashEndpoint? {
        guard let value = yamlTopLevelValue(forKey: "external-controller", in: text) else { return nil }
        let secret = yamlTopLevelValue(forKey: "secret", in: text)
        return ClashEndpoint.parse(value, secret: secret)
    }

    static func yamlTopLevelValue(forKey key: String, in text: String) -> String? {
        let prefix = "\(key):"
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        guard let line = normalized.split(separator: "\n", omittingEmptySubsequences: false)
            .first(where: { $0.hasPrefix(prefix) }) else { return nil }
        let raw = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return nil }
        if raw.hasPrefix("\"") {
            // Find the closing unescaped double quote so trailing `# comments` do not break decoding.
            var escaped = false
            var closingIndex: String.Index?
            var idx = raw.index(after: raw.startIndex)
            while idx < raw.endIndex {
                let ch = raw[idx]
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    closingIndex = idx
                    break
                }
                idx = raw.index(after: idx)
            }
            guard let end = closingIndex else { return nil }
            let quoted = String(raw[raw.startIndex...end])
            guard let decoded = try? JSONDecoder().decode(String.self, from: Data(quoted.utf8)), !decoded.isEmpty else {
                return nil
            }
            return decoded
        } else if raw.hasPrefix("'") {
            var idx = raw.index(after: raw.startIndex)
            var result = ""
            while idx < raw.endIndex {
                if raw[idx] == "'" {
                    let next = raw.index(after: idx)
                    if next < raw.endIndex && raw[next] == "'" {
                        result.append("'")
                        idx = raw.index(after: next)
                        continue
                    }
                    return result.isEmpty ? nil : result
                }
                result.append(raw[idx])
                idx = raw.index(after: idx)
            }
            return nil
        } else {
            let stripped = raw.components(separatedBy: " #")[0].trimmingCharacters(in: .whitespaces)
            return stripped.isEmpty ? nil : stripped
        }
    }

    public static func decodeResponse(_ data: Data) throws -> ClashConnections {
        let body = try responseBody(data, expectedStatus: "200")
        return try JSONDecoder().decode(ClashConnections.self, from: body)
    }

    private static func responseBody(_ data: Data, expectedStatus: String) throws -> Data {
        guard data.count <= maximumResponseSize,
              let boundary = data.range(of: Data("\r\n\r\n".utf8)),
              let headers = String(data: data[..<boundary.lowerBound], encoding: .utf8),
              let status = headers.components(separatedBy: "\r\n").first,
              status.split(separator: " ").dropFirst().first.map(String.init) == expectedStatus,
              !headers.lowercased().contains("transfer-encoding:") else {
            throw URLError(.badServerResponse)
        }
        return Data(data[boundary.upperBound...])
    }

    public static func readSnapshot(path: String, cancellation: CancellationSignal) throws -> ClashConnections {
        try decodeResponse(unixRequest(path: path, method: "GET", requestPath: "/connections", cancellation: cancellation))
    }

    public static func closeConnections(path: String, cancellation: CancellationSignal) throws {
        _ = try responseBody(unixRequest(path: path, method: "DELETE", requestPath: "/connections", cancellation: cancellation), expectedStatus: "204")
    }

    public static func closeConnection(path: String, id: String, cancellation: CancellationSignal) throws {
        let safeID = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        _ = try responseBody(unixRequest(path: path, method: "DELETE", requestPath: "/connections/\(safeID)", cancellation: cancellation), expectedStatus: "204")
    }

    public static func readSnapshot(endpoint: ClashEndpoint, cancellation: CancellationSignal) async throws -> ClashConnections {
        switch endpoint {
        case .unixSocket(let path):
            return try await Task.detached(priority: .utility) {
                try readSnapshot(path: path, cancellation: cancellation)
            }.value
        case .http(let baseURL, let secret):
            let url = baseURL.appendingPathComponent("connections")
            let data = try await httpRequest(url: url, method: "GET", secret: secret, expectedStatus: 200)
            return try JSONDecoder().decode(ClashConnections.self, from: data)
        }
    }

    public static func closeConnections(endpoint: ClashEndpoint, ids: [String]?, cancellation: CancellationSignal) async throws {
        switch endpoint {
        case .unixSocket(let path):
            try await Task.detached(priority: .utility) {
                if let ids, !ids.isEmpty {
                    for id in ids {
                        try? closeConnection(path: path, id: id, cancellation: cancellation)
                    }
                } else {
                    try closeConnections(path: path, cancellation: cancellation)
                }
            }.value
        case .http(let baseURL, let secret):
            if let ids, !ids.isEmpty {
                for id in ids {
                    let url = baseURL.appendingPathComponent("connections").appendingPathComponent(id)
                    _ = try? await httpRequest(url: url, method: "DELETE", secret: secret, expectedStatus: 204)
                }
            } else {
                let url = baseURL.appendingPathComponent("connections")
                _ = try await httpRequest(url: url, method: "DELETE", secret: secret, expectedStatus: 204)
            }
        }
    }

    private static func httpRequest(url: URL, method: String, secret: String?, expectedStatus: Int) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 3
        config.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let secret, !secret.isEmpty {
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == expectedStatus,
              data.count <= maximumResponseSize else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private static func unixRequest(path: String, method: String, requestPath: String, cancellation: CancellationSignal) throws -> Data {
        guard !cancellation.isCancelled() else { throw URLError(.cancelled) }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else { throw URLError(.cannotConnectToHost) }
        var noSignal: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal))) == 0 else {
            throw URLError(.cannotConnectToHost)
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let pathBytes = Array(path.utf8) + [0]
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw URLError(.badURL) }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: pathBytes)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        func waitFor(_ events: Int16) throws {
            while !cancellation.isCancelled() {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw URLError(.timedOut) }
                var descriptorState = pollfd(fd: descriptor, events: events, revents: 0)
                let result = poll(&descriptorState, 1, 100)
                if result > 0 { return }
                if result < 0 && errno != EINTR { throw URLError(.networkConnectionLost) }
            }
            throw URLError(.cancelled)
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            guard errno == EINPROGRESS else { throw URLError(.cannotConnectToHost) }
            try waitFor(Int16(POLLOUT))
            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout.size(ofValue: socketError))
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0, socketError == 0 else {
                throw URLError(.cannotConnectToHost)
            }
        }
        let request = Array("\(method) \(requestPath) HTTP/1.0\r\nHost: localhost\r\n\r\n".utf8)
        var sent = 0
        while sent < request.count {
            try waitFor(Int16(POLLOUT))
            let count = request.withUnsafeBytes { bytes in
                send(descriptor, bytes.baseAddress!.advanced(by: sent), request.count - sent, 0)
            }
            if count > 0 { sent += count }
            else if count == 0 || (errno != EAGAIN && errno != EINTR) { throw URLError(.networkConnectionLost) }
        }
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try waitFor(Int16(POLLIN))
            let count = recv(descriptor, &buffer, buffer.count, 0)
            if count == 0 { return response }
            if count < 0 {
                if errno == EAGAIN || errno == EINTR { continue }
                throw URLError(.networkConnectionLost)
            }
            guard response.count + count <= maximumResponseSize else { throw URLError(.dataLengthExceedsMaximum) }
            response.append(contentsOf: buffer.prefix(count))
        }
    }

    private static func isSocket(_ path: String) -> Bool {
        socketIdentity(path) != nil
    }

    public static func socketIdentity(_ path: String) -> UInt64? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK else { return nil }
        return UInt64(info.st_ino)
    }
}

public struct OutageClosePolicy: Sendable {
    public static let dnsCloseCooldown: TimeInterval = 15
    private var attempted = false
    private var lastDNSCloseAt: TimeInterval?

    public init() {}

    public mutating func shouldClose(
        for status: InternetStatus,
        fromSnapshot: Bool,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        if status == .dnsStalled {
            guard fromSnapshot else { return false }
            if let last = lastDNSCloseAt, now >= last, now - last < Self.dnsCloseCooldown {
                return false
            }
            lastDNSCloseAt = now
            return true
        }
        if status == .online {
            attempted = false
            lastDNSCloseAt = nil
        }
        guard status == .offline, !attempted else { return false }
        attempted = true
        return true
    }
}

@MainActor
public final class ClashConnectivityMonitor {
    public var onChange: ((InternetStatus, ClashConnectivityDiagnostics) -> Void)?
    public private(set) var status: InternetStatus = .unknown
    public private(set) var diagnostics = ClashConnectivityDiagnostics()

    private var evidence = ClashTrafficEvidence()
    private var pollTask: Task<Void, Never>?
    private var request: CancellationSignal?
    private var requestID = UUID()
    private var retryAt: TimeInterval = 0
    private var endpoints: [ClashEndpoint] = []
    private var socketIdentity: UInt64?
    private var overrideAddress = ""
    private var networkAvailable = true
    private var suspended = false
    private var outageClosePolicy = OutageClosePolicy()
    private var probeTask: Task<Void, Never>?
    private var lastProbeSuccessAt: TimeInterval?
    private var nextProbeAt: TimeInterval = 0
    private var consecutiveProbeFailures = 0
    private var generation: UInt = 0
    private static let activeProbeLifetime: TimeInterval = 35
    private static let activeProbeInterval: TimeInterval = 25

    public init() {}

    public func configure(overrideAddress: String) {
        let trimmed = overrideAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard self.overrideAddress != trimmed else { return }
        self.overrideAddress = trimmed
        endpoints = []
        socketIdentity = nil
        retryAt = 0
        evidence.reset()
    }

    public func start() {
        guard pollTask == nil else { return }
        suspended = false
        pollTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                if !self.suspended {
                    await self.sample()
                }
                // Adaptive interval reduces background wakeups once online.
                let interval: Duration = self.suspended ? .seconds(5) : (self.status == .online ? .milliseconds(1500) : .seconds(1))
                let tolerance: Duration = self.status == .online ? .milliseconds(400) : .milliseconds(200)
                do {
                    try await Task.sleep(for: interval, tolerance: tolerance)
                } catch {
                    return
                }
            }
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        reset()
    }

    public func setSuspended(_ suspended: Bool) {
        self.suspended = suspended
        if suspended {
            reset(networkAvailable: false)
        }
    }

    public func reset(networkAvailable: Bool? = nil) {
        generation &+= 1
        if let networkAvailable { self.networkAvailable = networkAvailable }
        cancelRequest()
        probeTask?.cancel()
        probeTask = nil
        lastProbeSuccessAt = nil
        nextProbeAt = 0
        consecutiveProbeFailures = 0
        evidence.reset()
        retryAt = 0
        diagnostics.stalledDNSCount = 0
        diagnostics.activeConnectionCount = nil
        diagnostics.sourceDescription = self.networkAvailable ? "网络已变更，重新检测中…" : "当前无可用网络路径"
        publish(self.networkAvailable ? .unknown : .offline, forceNotify: true)
    }

    private func sample() async {
        guard pollTask != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard networkAvailable else { return }
        guard request == nil else { return }
        if status != .clashUnavailable {
            publish(effectiveStatus(passive: evidence.status(now: now), now: now))
        }
        guard now >= retryAt else {
            maybeRunActiveProbe(now: now)
            return
        }
        if endpoints.isEmpty {
            endpoints = ClashController.endpoints(overrideAddress: overrideAddress)
        }
        guard let endpoint = endpoints.first else {
            failed()
            maybeRunActiveProbe(now: now)
            return
        }
        if case .unixSocket(let socketPath) = endpoint {
            let identity = ClashController.socketIdentity(socketPath)
            if socketIdentity != identity {
                evidence.reset()
                socketIdentity = identity
            }
        }
        let cancellation = CancellationSignal()
        request = cancellation
        let id = UUID()
        requestID = id

        let result: Result<ClashConnections, Error>
        do {
            let snapshot = try await ClashController.readSnapshot(endpoint: endpoint, cancellation: cancellation)
            result = .success(snapshot)
        } catch {
            result = .failure(error)
        }

        guard requestID == id, pollTask != nil else { return }
        request = nil
        let sampleNow = ProcessInfo.processInfo.systemUptime
        switch result {
        case .success(let snapshot):
            let observation = evidence.observeDetailed(snapshot, now: sampleNow)
            let passive = observation.status
            diagnostics.endpointDescription = endpoint.displayDescription
            diagnostics.activeConnectionCount = observation.activeConnectionCount
            diagnostics.stalledDNSCount = observation.stalledDNSConnectionIDs.count

            if passive == .online {
                consecutiveProbeFailures = 0
                probeTask?.cancel()
                probeTask = nil
                diagnostics.lastVerifiedAt = Date()
                diagnostics.sourceDescription = "Clash 代理流量确认（\(observation.activeConnectionCount) 条连接）"
            } else if passive == .dnsStalled {
                lastProbeSuccessAt = nil
                diagnostics.sourceDescription = "检测到 \(observation.stalledDNSConnectionIDs.count) 条停滞的 DNS 连接"
            }

            if outageClosePolicy.shouldClose(for: passive, fromSnapshot: true, now: sampleNow) {
                // Only surgically close the stalled DNS connection IDs on .dnsStalled!
                let idsToClose = passive == .dnsStalled ? observation.stalledDNSConnectionIDs : nil
                closeConnections(endpoint: endpoint, ids: idsToClose)
            }
            let effective = effectiveStatus(passive: passive, now: sampleNow)
            if effective == .online && passive != .online {
                diagnostics.sourceDescription = "轻量探测确认 · Clash 活跃连接 \(observation.activeConnectionCount) 条"
            } else if effective == .unknown {
                diagnostics.sourceDescription = "Clash 已连接（\(observation.activeConnectionCount) 条连接），等待代理流量或主动探测"
            }
            publish(effective, forceNotify: true)
            if passive == .unknown {
                maybeRunActiveProbe(now: sampleNow)
            }
        case .failure:
            failed()
            maybeRunActiveProbe(now: sampleNow)
        }
    }

    private func effectiveStatus(passive: InternetStatus, now: TimeInterval) -> InternetStatus {
        if passive == .dnsStalled || passive == .online { return passive }
        if let verified = lastProbeSuccessAt, now >= verified, now - verified < Self.activeProbeLifetime {
            return .online
        }
        if consecutiveProbeFailures >= 2 { return .offline }
        return passive
    }

    private func maybeRunActiveProbe(now: TimeInterval) {
        guard pollTask != nil, networkAvailable, !suspended, probeTask == nil, now >= nextProbeAt else { return }
        let token = generation
        probeTask = Task { @MainActor [weak self] in
            let reachable = await InternetConnectivityProbe.check(timeout: 4)
            guard let self, self.generation == token, self.pollTask != nil, self.networkAvailable else { return }
            self.probeTask = nil
            let finishNow = ProcessInfo.processInfo.systemUptime
            if reachable {
                self.consecutiveProbeFailures = 0
                self.lastProbeSuccessAt = finishNow
                self.nextProbeAt = finishNow + Self.activeProbeInterval
                self.diagnostics.lastVerifiedAt = Date()
                if self.diagnostics.endpointDescription == nil {
                    self.diagnostics.sourceDescription = "轻量探测确认（未检测到 Clash 控制器）"
                } else {
                    self.diagnostics.sourceDescription = "轻量连通性探测确认可达"
                }
                self.publish(.online, forceNotify: true)
            } else {
                self.lastProbeSuccessAt = nil
                self.consecutiveProbeFailures += 1
                self.nextProbeAt = finishNow + (self.consecutiveProbeFailures >= 2 ? 10 : 2)
                if self.consecutiveProbeFailures >= 2 {
                    self.diagnostics.sourceDescription = "连续 \(self.consecutiveProbeFailures) 次轻量探测失败"
                    self.publish(.offline, forceNotify: true)
                }
            }
        }
    }

    private func cancelRequest() {
        requestID = UUID()
        request?.cancel()
        request = nil
    }

    private func failed() {
        cancelRequest()
        if !endpoints.isEmpty { endpoints.removeFirst() }
        socketIdentity = nil
        evidence.reset()
        diagnostics.endpointDescription = nil
        diagnostics.activeConnectionCount = nil
        diagnostics.stalledDNSCount = 0
        let now = ProcessInfo.processInfo.systemUptime
        retryAt = now + (endpoints.isEmpty ? 5 : 1)
        let effective = effectiveStatus(passive: .clashUnavailable, now: now)
        if effective == .clashUnavailable {
            diagnostics.sourceDescription = "未连接到本地 Clash 控制器，使用轻量探测"
        }
        publish(effective, forceNotify: true)
    }

    private func publish(_ status: InternetStatus, forceNotify: Bool = false) {
        let changed = self.status != status
        self.status = status
        diagnostics.status = status
        if changed, outageClosePolicy.shouldClose(for: status, fromSnapshot: false) {
            closeConnections(endpoint: endpoints.first, ids: nil)
        }
        if changed || forceNotify {
            onChange?(status, diagnostics)
        }
    }

    private func closeConnections(endpoint: ClashEndpoint?, ids: [String]?) {
        let override = overrideAddress
        Task.detached(priority: .utility) {
            guard let target = endpoint ?? ClashController.endpoints(overrideAddress: override).first else { return }
            try? await ClashController.closeConnections(endpoint: target, ids: ids, cancellation: CancellationSignal())
        }
    }
}
