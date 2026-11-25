import Darwin
import Foundation
import HotspotCore
import Network
import Testing
@testable import NetworkAutoCore

@Suite("NetworkAutoCore")
struct NetworkAutoCoreTests {

    @Test("Usable IPv4 validation and deterministic primary address selection")
    func ipv4Selection() {
        #expect(!usableIPv4("127.0.0.1"))
        #expect(!usableIPv4("169.254.1.1"))
        #expect(!usableIPv4("198.18.0.1"))
        #expect(!usableIPv4("224.0.0.1"))
        #expect(usableIPv4("10.183.0.2"))

        let entries = [
            InterfaceIPv4Entry(interfaceName: "en0", ip: "169.254.10.2", isUpAndRunning: true),
            InterfaceIPv4Entry(interfaceName: "en0", ip: "10.183.1.1", isUpAndRunning: false),
            InterfaceIPv4Entry(interfaceName: "en0", ip: "10.183.1.2", isUpAndRunning: true),
            InterfaceIPv4Entry(interfaceName: "en0", ip: "10.183.1.99", isUpAndRunning: true),
            InterfaceIPv4Entry(interfaceName: "en1", ip: "192.168.1.5", isUpAndRunning: true)
        ]
        // Repeated runs must deterministically choose the first up+running usable address.
        for _ in 0..<10 {
            let selected = selectPrimaryIPv4Addresses(from: entries)
            #expect(selected == ["en0": "10.183.1.2", "en1": "192.168.1.5"])
        }
    }

    @Test("Config validation, portalPageURL derivation, and fingerprint")
    func configValidationAndPortalURL() {
        let config = AppConfig(username: "account", password: "p&密+?#")
        #expect(config.validationError() == nil)
        #expect(config.portalPageURL.absoluteString == "https://login.csust.edu.cn")

        var custom = config
        custom.loginURLString = "http://portal.example.edu.cn:802/eportal/login"
        #expect(custom.portalPageURL.absoluteString == "http://portal.example.edu.cn")

        var badURL = config
        badURL.loginURLString = "not-a-url"
        #expect(badURL.validationError() != nil)

        var badClash = config
        badClash.clashControllerAddress = "invalid"
        #expect(badClash.validationError() != nil)

        var goodClash = config
        goodClash.clashControllerAddress = "http://127.0.0.1:9097"
        #expect(goodClash.validationError() == nil)

        var changedPassword = config
        changedPassword.password = "different"
        #expect(configFingerprint(config) != configFingerprint(changedPassword))
    }

    @Test("Dr.COM response parsing")
    func responseParsing() {
        #expect(parseResponse(#"dr1003({"result":1});"#) == .online)
        #expect(parseResponse(#"dr1003({"msg":"密码错误"});"#) == .credentials)
        #expect(parseResponse(#"dr1003({"msg":"10.183.0.2 已经在线！"});"#) == .online)
        #expect(parseResponse("Dr.COMWebLoginID_3.htm") == .online)
        if case .retry = parseResponse("认证超时") {} else { Issue.record("Expected retry on timeout") }
    }

    @Test("Query encoding escapes + as %2B and handles special password characters")
    func queryEncodingEscapesPlus() {
        let req = LoginService.makeRequest(
            url: URL(string: "https://login.csust.edu.cn:802/eportal/portal/login")!,
            parameters: [
                ("user_account", ",0,20240001"),
                ("user_password", "a+b&c=d#e?f 密")
            ],
            referer: "https://login.csust.edu.cn:802/"
        )
        let query = req?.url?.query ?? ""
        #expect(query.contains("user_password=a%2Bb%26c%3Dd%23e%3Ff%20%E5%AF%86"))
        #expect(!query.contains("+"))
    }

    @Test("HTTP login over direct and system proxy routes", arguments: [false, true])
    func httpLogin(proxy: Bool) async throws {
        let queue = DispatchQueue(label: "com.nowaywastaken.networkauto.test-server")
        let listener = try NWListener(using: .tcp, on: .any)
        let ready = AsyncGate()
        let requestDone = AsyncGate()
        let captured = LockedBox("")

        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.open() }
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, _ in
                if let data, let text = String(data: data, encoding: .utf8) {
                    captured.set(text)
                }
                let body = Data(#"{"result":1}"#.utf8)
                let header = Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
                connection.send(content: header + body, completion: .contentProcessed { _ in
                    requestDone.open()
                    connection.cancel()
                })
            }
        }
        listener.start(queue: queue)
        defer { listener.cancel() }

        #expect(await ready.wait(timeout: .seconds(3)))
        let port = listener.port!.rawValue
        let config = AppConfig(username: "account", password: "p&密+?#")
        let serverURL = proxy
            ? URL(string: "http://127.0.0.1:9/login")!
            : URL(string: "http://127.0.0.1:\(port)/login")!
        let systemProxy = proxy ? URL(string: "http://127.0.0.1:\(port)")! : nil

        let result = await LoginService.login(
            config: config,
            ip: "10.183.0.2",
            stillConnected: { true },
            serverURL: serverURL,
            systemProxy: systemProxy,
            timeout: 3
        )
        #expect(result.0 == .online)
        #expect(await requestDone.wait(timeout: .seconds(3)))
        let rawRequest = captured.get()
        #expect(rawRequest.contains("user_password=p%26%E5%AF%86%2B%3F%23"))
        #expect(rawRequest.contains("wlan_user_ip=10.183.0.2"))
        #expect(!rawRequest.contains("p&密+?#"))
    }

    @Test("AppStore migrates plaintext config into SecretStore and strips password from UserDefaults")
    func storeMigrationAndSecretStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("csust-test-\(UUID().uuidString)")
        let dataDir = root.appendingPathComponent("data", isDirectory: true)
        let paths = AppPaths(
            data: dataDir,
            legacyConfig: dataDir.appendingPathComponent("config.json"),
            legacyState: dataDir.appendingPathComponent("state.json"),
            logs: root.appendingPathComponent("logs", isDirectory: true)
        )
        let suiteName = "csust-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

        let legacyJSON = Data(#"{"username":"migrated-account","password":"migrated-secret","timeout_secs":15}"#.utf8)
        try legacyJSON.write(to: paths.legacyConfig)

        var legacyState = AppState()
        legacyState.phase = .online
        legacyState.checking = true
        try JSONEncoder().encode(legacyState).write(to: paths.legacyState)

        let secretStore = InMemorySecretStore()
        let store = AppStore(defaults: defaults, paths: paths, secretStore: secretStore)
        let loaded = try store.config().get()
        #expect(loaded.username == "migrated-account")
        #expect(loaded.password == "migrated-secret")
        #expect(try secretStore.loadPassword() == "migrated-secret")
        #expect(!FileManager.default.fileExists(atPath: paths.legacyConfig.path))

        // Verify password is NEVER persisted in UserDefaults.
        let persistedV2 = defaults.data(forKey: "config.v2")
        #expect(persistedV2 != nil)
        #expect(!String(decoding: persistedV2!, as: UTF8.self).contains("migrated-secret"))
        #expect(defaults.data(forKey: "config.v1") == nil)

        // Reload with new AppStore instance sharing defaults & secretStore.
        let reloaded = AppStore(defaults: defaults, paths: paths, secretStore: secretStore)
        #expect(try reloaded.config().get() == loaded)

        // State resets `checking` on load.
        store.saveState(legacyState)
        var expectedState = legacyState
        expectedState.checking = false
        #expect(reloaded.loadState() == expectedState)
    }

    @Test("AppInstanceLock prevents duplicate instances")
    func instanceLock() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("csust-lock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let lockPath = root.appendingPathComponent("run.lock")
        do {
            let first = try AppInstanceLock(path: lockPath)
            #expect((fcntl(first.descriptor, F_GETFD) & FD_CLOEXEC) != 0)
            #expect(throws: AppInstanceLockError.alreadyRunning) {
                _ = try AppInstanceLock(path: lockPath)
            }
            _ = first
        }
        try? FileManager.default.removeItem(at: lockPath)
        _ = try AppInstanceLock(path: lockPath)
    }

    @Test("Wi-Fi and personal hotspot policies")
    func wifiAndHotspotPolicies() {
        let disconnected = WiFiNetwork(interfaceName: "en0", ssid: nil, bssid: nil, ip: nil)
        let hotspot = WiFiNetwork(interfaceName: "en0", ssid: "Phone", bssid: "bb", ip: "192.0.2.2")
        let campus = WiFiNetwork(interfaceName: "en0", ssid: AppConstants.defaultCampusSSID, bssid: "aa", ip: "10.183.0.2")

        #expect(selectNetwork([
            WiFiNetwork(interfaceName: "en0", ssid: "other", bssid: nil, ip: "10.183.0.2"),
            WiFiNetwork(interfaceName: "en1", ssid: AppConstants.defaultCampusSSID, bssid: nil, ip: "192.0.2.1")
        ])?.interfaceName == "en1")

        #expect(personalHotspotStatus(networks: [hotspot], permissionAuthorized: true, ownedSSID: "Phone", ownedBSSID: "bb", sleeping: false, controlIssue: nil, phase: .disabled) == "已连接")
        #expect(personalHotspotStatus(networks: [disconnected], permissionAuthorized: true, ownedSSID: nil, ownedBSSID: nil, sleeping: false, controlIssue: nil, phase: .disabled) == "未连接")
        #expect(personalHotspotStatus(networks: [hotspot], permissionAuthorized: true, ownedSSID: nil, ownedBSSID: nil, sleeping: false, controlIssue: nil, phase: .disabled, recognizedHotspot: true) == "已连接")
        #expect(hotspotRecognition(profile: nil, cachedMatch: false, pathExpensive: true) == true)
        #expect(hotspotRecognition(profile: false, cachedMatch: true, pathExpensive: true) == false)

        #expect(maySelectCampus(networks: [disconnected], permissionAuthorized: true, ownedHotspotSSID: nil))
        #expect(maySelectCampus(networks: [hotspot], permissionAuthorized: true, ownedHotspotSSID: "Phone"))
        #expect(!maySelectCampus(networks: [hotspot], permissionAuthorized: true, ownedHotspotSSID: nil))

        var state = AppState()
        state.network = campus.key
        state.phase = .credentials
        state.checking = false
        #expect(shouldFallbackForAuthentication(state, campus: campus))
        state.checking = true
        #expect(!shouldFallbackForAuthentication(state, campus: campus))

        #expect(fallbackCooldownSeconds(consecutiveFallbacks: 1) == 120)
        #expect(fallbackCooldownSeconds(consecutiveFallbacks: 4) == 600)
        #expect(!campusCandidateEligible(rssi: -82, replacingHotspot: true))
        #expect(campusCandidateEligible(rssi: -68, replacingHotspot: true))
        #expect(campusCandidateEligible(rssi: -82, replacingHotspot: false))
    }

    @Test("AutoLoginEngine preserves manual flag when checkNow arrives mid-cycle")
    func manualCheckNotLostWhileRunning() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("csust-manual-\(UUID().uuidString)")
        let paths = AppPaths(data: root, legacyConfig: root.appendingPathComponent("c"), legacyState: root.appendingPathComponent("s"), logs: root.appendingPathComponent("logs"))
        let suiteName = "csust-manual-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        let store = AppStore(defaults: defaults, paths: paths, secretStore: InMemorySecretStore())
        try store.saveConfig(AppConfig(username: "u", password: "p"))
        let snapshot = EngineSnapshot()
        snapshot.update(networks: [WiFiNetwork(interfaceName: "en0", ssid: AppConstants.defaultCampusSSID, bssid: "aa", ip: "10.183.0.2")], permissionAuthorized: true)

        let callCount = LockedBox(0)
        let firstCallEntered = AsyncGate()
        let secondCallDone = AsyncGate()
        let allowFirstFinish = AsyncGate()

        let engine = AutoLoginEngine(
            store: store,
            snapshot: snapshot,
            retryDelays: [],
            authenticate: { _, _, _ in
                let n = callCount.modify { $0 += 1; return $0 }
                if n == 1 {
                    firstCallEntered.open()
                    _ = await allowFirstFinish.wait(timeout: .seconds(3))
                    return (.credentials, "direct")
                }
                return (.online, "direct")
            },
            onUpdate: { state, _, _ in
                if !state.checking && state.phase == .online {
                    secondCallDone.open()
                }
            }
        )

        await engine.start()
        #expect(await firstCallEntered.wait(timeout: .seconds(3)))
        // Call checkNow while the first cycle is in-flight and about to return .credentials!
        await engine.checkNow()
        allowFirstFinish.open()
        // The queued manual cycle must clear credentialsBlocked and re-authenticate to .online.
        #expect(await secondCallDone.wait(timeout: .seconds(3)))
        #expect(callCount.get() == 2)
        await engine.stop()
    }

    @Test("AutoLoginEngine waits for usable IPv4 and backs off retries")
    func engineWaitsForIPv4AndBacksOff() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("csust-ipwait-\(UUID().uuidString)")
        let paths = AppPaths(data: root, legacyConfig: root.appendingPathComponent("c"), legacyState: root.appendingPathComponent("s"), logs: root.appendingPathComponent("logs"))
        let suiteName = "csust-ipwait-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        let store = AppStore(defaults: defaults, paths: paths, secretStore: InMemorySecretStore())
        try store.saveConfig(AppConfig(username: "u", password: "p"))
        let snapshot = EngineSnapshot()
        snapshot.update(networks: [WiFiNetwork(interfaceName: "en0", ssid: AppConstants.defaultCampusSSID, bssid: "aa", ip: nil)], permissionAuthorized: true)

        let authedIP = LockedBox("")
        let observed = LockedBox(AppState())
        let waitingDone = AsyncGate()
        let retriesDone = AsyncGate()

        let engine = AutoLoginEngine(
            store: store,
            snapshot: snapshot,
            retryDelays: [0.05, 0.05],
            ipWaitTimeout: 0.2,
            authenticate: { _, ip, _ in
                authedIP.set(ip)
                return (.retry("temporary"), "direct")
            },
            onUpdate: { state, _, _ in
                observed.set(state)
                if !state.checking && state.phase == .waitingIP {
                    waitingDone.open()
                }
                if !state.checking && state.phase == .retry && state.attempt >= 3 {
                    retriesDone.open()
                }
            }
        )

        await engine.start()
        #expect(await waitingDone.wait(timeout: .seconds(3)))
        #expect(authedIP.get().isEmpty)
        #expect(observed.get().phase == .waitingIP)

        let started = ContinuousClock.now
        snapshot.update(networks: [WiFiNetwork(interfaceName: "en0", ssid: AppConstants.defaultCampusSSID, bssid: "aa", ip: "10.183.0.2")], permissionAuthorized: true)
        await engine.request()
        #expect(await retriesDone.wait(timeout: .seconds(3)))
        #expect(authedIP.get() == "10.183.0.2")
        #expect(observed.get().attempt == 3)
        #expect(ContinuousClock.now - started >= .milliseconds(80))
        await engine.stop()
    }

    @Test("Clash traffic evidence, healthy DoH pool immunity, and surgical DNS stall IDs")
    func clashTrafficEvidenceAndDNSStall() {
        func dnsConn(_ id: String, ip: String = "223.5.5.5", port: String = "443", download: Int64 = 0) -> ClashConnections.Connection {
            .init(
                id: id,
                metadata: .init(host: "", destinationPort: port, network: "tcp", type: "Inner", destinationIP: ip),
                download: download,
                upload: 1500,
                chains: ["DIRECT"]
            )
        }
        let internet = ClashConnections.Connection(
            id: "internet",
            metadata: .init(host: "example.com", destinationPort: "443", network: "tcp", type: "Tun", destinationIP: "198.18.0.1"),
            download: 1,
            upload: 10,
            chains: ["node"]
        )

        var evidence = ClashTrafficEvidence()
        // Baseline
        #expect(evidence.observe(ClashConnections(downloadTotal: 100, connections: [dnsConn("d1", download: 1000), dnsConn("d2", download: 1000), internet]), now: 0) == .unknown)
        // Active DoH pool where download counters grow must NOT trigger .dnsStalled!
        #expect(evidence.observe(ClashConnections(downloadTotal: 500, connections: [dnsConn("d1", download: 1200), dnsConn("d2", download: 1000), internet]), now: 2) == .unknown)
        #expect(evidence.observe(ClashConnections(downloadTotal: 900, connections: [dnsConn("d1", download: 1400), dnsConn("d2", download: 1100), internet]), now: 5) == .unknown)

        // Now both DNS connections stagnate for >= 3 seconds -> .dnsStalled with exact IDs!
        let obs1 = evidence.observeDetailed(ClashConnections(downloadTotal: 900, connections: [dnsConn("d1", download: 1400), dnsConn("d2", download: 1100), internet]), now: 6)
        #expect(obs1.status == .unknown)
        let obs2 = evidence.observeDetailed(ClashConnections(downloadTotal: 900, connections: [dnsConn("d1", download: 1400), dnsConn("d2", download: 1100), internet]), now: 9)
        #expect(obs2.status == .dnsStalled)
        #expect(obs2.stalledDNSConnectionIDs == ["d1", "d2"])
    }

    @Test("Clash YAML config parsing handles quotes, comments, CRLF, and HTTP controller")
    func clashYAMLConfigParsing() {
        #expect(ClashController.configuredSocket(in: "external-controller-unix: '/tmp/clash.sock' # comment\r\n") == "/tmp/clash.sock")
        #expect(ClashController.configuredSocket(in: "external-controller-unix: \"/tmp/clash.sock\" # comment\n") == "/tmp/clash.sock")
        #expect(ClashController.configuredSocket(in: "external-controller-unix: ''\n") == nil)
        #expect(ClashController.configuredSocket(in: "  external-controller-unix: /tmp/nested.sock\n") == nil)

        let yaml = """
        external-controller: 127.0.0.1:9097 # api
        secret: "my-secret" # token
        """
        let endpoint = ClashController.configuredHTTPEndpoint(in: yaml)
        #expect(endpoint == .http(URL(string: "http://127.0.0.1:9097")!, secret: "my-secret"))
    }

    @Test("Clash Unix socket IPC supports GET, surgical DELETE /connections/{id}, and DELETE /connections")
    func clashUnixSocketIPC() throws {
        let path = "/tmp/csust-ipc-\(UUID().uuidString).sock"
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(listener >= 0)
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
        #expect(bound == 0 && listen(listener, 3) == 0)

        let finished = DispatchSemaphore(value: 0)
        let seenRequests = LockedBox([String]())
        DispatchQueue.global(qos: .utility).async {
            defer { finished.signal() }
            for _ in 0..<3 {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { return }
                var bytes = [UInt8](repeating: 0, count: 4096)
                let count = recv(client, &bytes, bytes.count, 0)
                guard count > 0 else { close(client); return }
                let request = String(decoding: bytes.prefix(count), as: UTF8.self)
                let firstLine = request.components(separatedBy: "\r\n").first ?? ""
                seenRequests.modify { $0.append(firstLine) }
                let responseString = firstLine.hasPrefix("GET ")
                    ? "HTTP/1.0 200 OK\r\n\r\n{\"downloadTotal\":3,\"connections\":null}"
                    : "HTTP/1.0 204 No Content\r\n\r\n"
                let response = Array(responseString.utf8)
                var sent = 0
                while sent < response.count {
                    let n = response.withUnsafeBytes { send(client, $0.baseAddress!.advanced(by: sent), response.count - sent, 0) }
                    guard n > 0 else { break }
                    sent += n
                }
                close(client)
            }
        }

        let snapshot = try ClashController.readSnapshot(path: path, cancellation: CancellationSignal())
        #expect(snapshot.downloadTotal == 3 && snapshot.connections == nil)
        try ClashController.closeConnection(path: path, id: "dns-42", cancellation: CancellationSignal())
        try ClashController.closeConnections(path: path, cancellation: CancellationSignal())
        #expect(finished.wait(timeout: .now() + 3) == .success)
        #expect(seenRequests.get() == [
            "GET /connections HTTP/1.0",
            "DELETE /connections/dns-42 HTTP/1.0",
            "DELETE /connections HTTP/1.0"
        ])
    }
}

private final class LockedBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T

    init(_ value: T) { self.value = value }

    func get() -> T {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: T) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    @discardableResult
    func modify<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

private final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        lock.lock()
        if opened {
            lock.unlock()
            return
        }
        opened = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        pending.forEach { $0.resume() }
    }

    func wait(timeout: Duration) async -> Bool {
        let alreadyOpen: Bool = lock.withLock { opened }
        if alreadyOpen { return true }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    self.lock.lock()
                    if self.opened {
                        self.lock.unlock()
                        continuation.resume()
                    } else {
                        self.waiters.append(continuation)
                        self.lock.unlock()
                    }
                }
                return true
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}
