import Darwin
import Foundation

enum InternetStatus: Equatable, Sendable {
    case online
    case dnsStalled
    case unknown
    case clashUnavailable
    case offline

    var title: String {
        switch self {
        case .online: "已连接"
        case .dnsStalled: "未连接（重复 DNS 连接）"
        case .unknown: "暂无近期流量"
        case .clashUnavailable: "Clash 未就绪"
        case .offline: "未连接"
        }
    }

    var isConnected: Bool {
        switch self {
        case .online: true
        default: false
        }
    }

    var detail: String {
        switch self {
        case .dnsStalled:
            "检测到至少两条连接指向同一 Clash 内部 DNS 候选目标，按断线处理。"
        default:
            "根据 Clash 实际代理连接的近期收包判断；没有流量不代表断网。"
        }
    }
}

struct ClashConnections: Decodable, Sendable {
    let downloadTotal: Int64
    let connections: [Connection]?

    struct Connection: Decodable, Sendable {
        let id: String
        let metadata: Metadata
        let download: Int64
        let upload: Int64
        let chains: [String]

        struct Metadata: Decodable, Sendable {
            let host: String
            let destinationPort: String
            let network: String
            let type: String
            let destinationIP: String?
        }

        // Mihomo does not identify DNS requests in /connections; internal connections
        // on DNS/HTTPS ports are the available passive DNS candidates.
        var isDNSCandidate: Bool {
            metadata.type == "Inner"
                && ["53", "443", "853"].contains(metadata.destinationPort)
                && ["tcp", "udp"].contains(metadata.network.lowercased())
                && metadata.destinationIP?.isEmpty == false
                && !Self.isLocalAddress(metadata.destinationIP)
                && !chains.contains(where: { ["REJECT", "REJECT-DROP"].contains($0.uppercased()) })
        }

        // Reuse Clash's actual routing decision instead of maintaining a domain list.
        // A connection or uploaded bytes alone do not prove that a remote server replied.
        var isInternetCandidate: Bool {
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

enum ClashConnectivitySelfTest {
    static func run() {
        func snapshot(_ download: Int64, total: Int64 = 1000, id: String = "a", chain: String = "node",
                      host: String = "example.com", ip: String = "198.18.0.1", port: String = "443") -> ClashConnections {
            let object: [String: Any] = [
                "downloadTotal": total,
                "connections": [["id": id, "metadata": ["host": host, "destinationIP": ip, "destinationPort": port, "network": "tcp", "type": "HTTPS"],
                                 "download": download, "upload": 99999, "chains": [chain, "group"]]]
            ]
            return try! JSONDecoder().decode(ClashConnections.self, from: JSONSerialization.data(withJSONObject: object))
        }
        var evidence = ClashTrafficEvidence()
        precondition(evidence.observe(snapshot(100), now: 0) == .unknown)
        precondition(evidence.observe(snapshot(100), now: 1) == .unknown) // Only uploads or historical bytes.
        precondition(evidence.observe(snapshot(101), now: 2) == .online)
        precondition(evidence.observe(snapshot(101), now: 31) == .online)
        precondition(evidence.observe(snapshot(101), now: 32) == .unknown)
        precondition(evidence.observe(snapshot(1, id: "new"), now: 33) == .online)
        precondition(evidence.observe(snapshot(200, total: 500), now: 34) == .unknown) // Core restart.
        evidence.reset()
        precondition(evidence.observe(snapshot(1000), now: 35) == .unknown) // New network's baseline.
        for excluded in [snapshot(1, chain: "DIRECT"), snapshot(1, chain: "REJECT"), snapshot(1, host: "router.local"),
                         snapshot(1, host: "login.csust.edu.cn"), snapshot(1, ip: "192.168.1.1"),
                         snapshot(1, ip: "::1"), snapshot(1, ip: "::ffff:10.0.0.1"), snapshot(1, ip: "fe80::1"),
                         snapshot(1, host: "127.0.0.1"), snapshot(1, port: "80")] {
            evidence.reset()
            _ = evidence.observe(snapshot(0), now: 0)
            precondition(evidence.observe(excluded, now: 1) == .unknown)
        }
        precondition(snapshot(1, ip: "2606:4700::1").connections![0].isInternetCandidate)
        let body = Data(#"{"downloadTotal":0,"connections":null}"#.utf8)
        precondition((try! ClashController.decodeResponse(Data("HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n\r\n".utf8) + body)).connections == nil)
        for invalid in [Data("HTTP/1.0 401 Unauthorized\r\n\r\n".utf8) + body,
                        Data("HTTP/1.0 200 OK\r\n\r\n{".utf8),
                        Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n".utf8) + body] {
            do { _ = try ClashController.decodeResponse(invalid); preconditionFailure("Invalid controller response accepted") }
            catch {}
        }
        precondition(ClashController.configuredSocket(in: "secret: do-not-read\nexternal-controller-unix: '/tmp/clash.sock'\n") == "/tmp/clash.sock")
        precondition(ClashController.configuredSocket(in: "external-controller-unix: \"/tmp/clash.sock\"\n") == "/tmp/clash.sock")
        precondition(ClashController.configuredSocket(in: "external-controller-unix: ''\n") == nil)
        precondition(ClashController.configuredSocket(in: "  external-controller-unix: /tmp/nested.sock\n") == nil)
        let snapshotState = EngineSnapshot()
        let campus = WiFiNetwork(interfaceName: "en0", ssid: "CSUST-Student", bssid: "aa", ip: "10.0.0.1")
        snapshotState.update(networks: [campus], permissionAuthorized: true)
        snapshotState.updateConnectivity(true)
        precondition(snapshotState.read().internetConnected)
        snapshotState.update(networks: [], permissionAuthorized: true)
        precondition(!snapshotState.read().internetConnected)
        dnsStalls()
        ipcSnapshot()
    }

    private static func dnsStalls() {
        func connection(_ id: String, ip: String = "223.5.5.5", port: String = "443",
                        type: String = "Inner", download: Int64 = 0) -> ClashConnections.Connection {
            .init(id: id, metadata: .init(host: "", destinationPort: port, network: "tcp", type: type, destinationIP: ip),
                  download: download, upload: 1500, chains: ["DIRECT"])
        }
        func snapshot(_ connections: [ClashConnections.Connection], total: Int64 = 1000) -> ClashConnections {
            ClashConnections(downloadTotal: total, connections: connections)
        }
        let first = connection("dns-1")
        let duplicate = connection("dns-2")
        let internet = ClashConnections.Connection(
            id: "internet", metadata: .init(host: "example.com", destinationPort: "443", network: "tcp",
                                            type: "Tun", destinationIP: "198.18.0.1"),
            download: 1, upload: 10, chains: ["node"]
        )
        var evidence = ClashTrafficEvidence()
        precondition(evidence.observe(snapshot([first]), now: 0) == .unknown)
        // Two simultaneous connections to the same resolver signal an interruption immediately.
        precondition(evidence.observe(snapshot([first, duplicate, internet]), now: 1) == .dnsStalled)
        precondition(!evidence.status(now: 1).isConnected)
        // Recent internet traffic cannot override the interruption; removal restores that evidence.
        precondition(evidence.observe(snapshot([first, internet]), now: 2) == .online)
        precondition(evidence.observe(snapshot([first, duplicate, internet]), now: 3) == .dnsStalled)
        evidence.reset()
        precondition(evidence.status(now: 3) == .unknown)
        // Different endpoints and excluded connections do not count as duplicates.
        for other in [connection("other", ip: "223.6.6.6"), connection("other", port: "853"),
                      connection("other", type: "Tun"), connection("other", ip: "192.168.1.1"),
                      connection("other", port: "123")] {
            evidence.reset()
            precondition(evidence.observe(snapshot([first, other]), now: 0) == .unknown)
        }
        // The rule uses concurrent connections, regardless of their byte counters.
        precondition(evidence.observe(snapshot([connection("a", download: 4000), connection("b", download: 4000)]), now: 1) == .dnsStalled)
        precondition(evidence.observe(snapshot([], total: 0), now: 2) == .unknown)
    }

    private static func ipcSnapshot() {
        let path = "/tmp/csust-ipc-\(UUID().uuidString).sock"
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        precondition(listener >= 0)
        defer { close(listener); unlink(path) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        precondition(bound == 0 && listen(listener, 1) == 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            let client = accept(listener, nil, nil)
            precondition(client >= 0)
            defer { close(client); finished.signal() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = recv(client, &bytes, bytes.count, 0)
            precondition(count > 0)
            let request = String(decoding: bytes.prefix(count), as: UTF8.self)
            precondition(request.hasPrefix("GET /connections HTTP/1.0\r\n"))
            precondition(!request.contains("Authorization"))
            let response = Array("HTTP/1.0 200 OK\r\n\r\n{\"downloadTotal\":3,\"connections\":null}".utf8)
            var sent = 0
            while sent < response.count {
                let count = response.withUnsafeBytes { send(client, $0.baseAddress!.advanced(by: sent), response.count - sent, 0) }
                precondition(count > 0)
                sent += count
            }
        }
        let snapshot = try! ClashController.readSnapshot(path: path, cancellation: CancellationSignal())
        precondition(snapshot.downloadTotal == 3 && snapshot.connections == nil)
        precondition(finished.wait(timeout: .now() + 3) == .success)
        let cancellation = CancellationSignal()
        cancellation.cancel()
        do {
            _ = try ClashController.readSnapshot(path: path, cancellation: cancellation)
            preconditionFailure("Cancelled IPC request was executed")
        } catch {
            precondition((error as? URLError)?.code == .cancelled)
        }
    }
}

struct ClashTrafficEvidence {
    static let lifetime: TimeInterval = 30
    private var downloads: [String: Int64] = [:]
    private var hasDuplicateDNS = false
    private var total: Int64?
    private var lastReply: TimeInterval?

    private struct DNSDestination: Hashable {
        let ip: String
        let port: String
        let network: String
    }

    mutating func reset() {
        downloads.removeAll(keepingCapacity: true)
        hasDuplicateDNS = false
        total = nil
        lastReply = nil
    }

    mutating func observe(_ snapshot: ClashConnections, now: TimeInterval) -> InternetStatus {
        if let total, snapshot.downloadTotal < total { reset() }
        let baselineExists = total != nil
        var next: [String: Int64] = [:]
        var dnsDestinations = Set<DNSDestination>()
        var duplicateDNS = false
        for connection in snapshot.connections ?? [] {
            if connection.isInternetCandidate {
                let previous = downloads[connection.id] ?? 0
                if baselineExists && connection.download > previous { lastReply = now }
                next[connection.id] = connection.download
            }
            if connection.isDNSCandidate {
                let destination = DNSDestination(ip: connection.metadata.destinationIP!.lowercased(),
                                                 port: connection.metadata.destinationPort,
                                                 network: connection.metadata.network.lowercased())
                if !dnsDestinations.insert(destination).inserted { duplicateDNS = true }
            }
        }
        downloads = next
        hasDuplicateDNS = duplicateDNS
        total = snapshot.downloadTotal
        return status(now: now)
    }

    func status(now: TimeInterval) -> InternetStatus {
        let connected = lastReply.map { now >= $0 && now - $0 < Self.lifetime } ?? false
        if hasDuplicateDNS { return .dnsStalled }
        return connected ? .online : .unknown
    }
}

// The controller is local IPC, independent of system proxies, PAC and TUN routing.
// HTTP/1.0 avoids chunked transfer encoding and lets EOF delimit each snapshot.
enum ClashController {
    static let maximumResponseSize = 8 * 1024 * 1024

    static func socketPaths() -> [String] {
        let servicePath = "/var/run/clash-verge-service/users/\(getuid())/verge-mihomo.sock"
        var paths = isSocket(servicePath) ? [servicePath] : []
        let config = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/clash-verge.yaml")
        if let text = try? String(contentsOf: config, encoding: .utf8),
           let path = configuredSocket(in: text), isSocket(path), !paths.contains(path) {
            paths.append(path)
        }
        return paths
    }

    static func configuredSocket(in text: String) -> String? {
        guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix("external-controller-unix:") }) else { return nil }
        let value = line.dropFirst("external-controller-unix:".count).trimmingCharacters(in: .whitespaces)
        let path: String
        if value.hasPrefix("\"") {
            guard let decoded = try? JSONDecoder().decode(String.self, from: Data(value.utf8)) else { return nil }
            path = decoded
        } else if value.hasPrefix("'") && value.hasSuffix("'") {
            path = String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        } else {
            path = value.components(separatedBy: " #")[0].trimmingCharacters(in: .whitespaces)
        }
        return path.hasPrefix("/") && !path.contains("\r") ? path : nil
    }

    static func decodeResponse(_ data: Data) throws -> ClashConnections {
        guard data.count <= maximumResponseSize,
              let boundary = data.range(of: Data("\r\n\r\n".utf8)),
              let headers = String(data: data[..<boundary.lowerBound], encoding: .utf8),
              let status = headers.components(separatedBy: "\r\n").first,
              status.split(separator: " ").dropFirst().first == "200",
              !headers.lowercased().contains("transfer-encoding:") else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(ClashConnections.self, from: data[boundary.upperBound...])
    }

    static func readSnapshot(path: String, cancellation: CancellationSignal) throws -> ClashConnections {
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
        let request = Array("GET /connections HTTP/1.0\r\nHost: localhost\r\n\r\n".utf8)
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
            if count == 0 { return try decodeResponse(response) }
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

    static func socketIdentity(_ path: String) -> UInt64? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK else { return nil }
        return UInt64(info.st_ino)
    }
}

@MainActor
final class ClashConnectivityMonitor {
    var onChange: ((InternetStatus) -> Void)?
    private(set) var status: InternetStatus = .unknown
    private var evidence = ClashTrafficEvidence()
    private var timer: Timer?
    private var request: CancellationSignal?
    private var requestID = UUID()
    private var retryAt: TimeInterval = 0
    private var socketPaths: [String] = []
    private var socketIdentity: UInt64?
    private let queue = DispatchQueue(label: "com.nowaywastaken.networkauto.clash", qos: .utility)
    private var networkAvailable = true

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        sample()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        reset()
    }

    func reset(networkAvailable: Bool? = nil) {
        if let networkAvailable { self.networkAvailable = networkAvailable }
        cancelRequest()
        evidence.reset()
        retryAt = 0
        publish(self.networkAvailable ? .unknown : .offline)
    }

    private func sample() {
        guard timer != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard networkAvailable else { return }
        guard request == nil else { return }
        if status != .clashUnavailable { publish(evidence.status(now: now)) }
        guard now >= retryAt else { return }
        if socketPaths.isEmpty { socketPaths = ClashController.socketPaths() }
        guard let socketPath = socketPaths.first else { failed(); return }
        let identity = ClashController.socketIdentity(socketPath)
        if socketIdentity != identity {
            evidence.reset()
            publish(.unknown)
            socketIdentity = identity
        }
        let cancellation = CancellationSignal()
        request = cancellation
        let id = UUID()
        requestID = id
        queue.async { [weak self] in
            let result = Result { try ClashController.readSnapshot(path: socketPath, cancellation: cancellation) }
            Task { @MainActor [weak self] in
                guard let self, self.requestID == id, self.timer != nil else { return }
                self.request = nil
                switch result {
                case .success(let snapshot):
                    self.publish(self.evidence.observe(snapshot, now: ProcessInfo.processInfo.systemUptime))
                case .failure: self.failed()
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
        if !socketPaths.isEmpty { socketPaths.removeFirst() }
        socketIdentity = nil
        evidence.reset()
        retryAt = ProcessInfo.processInfo.systemUptime + (socketPaths.isEmpty ? 5 : 1)
        publish(.clashUnavailable)
    }

    private func publish(_ status: InternetStatus) {
        guard self.status != status else { return }
        self.status = status
        onChange?(status)
    }
}
