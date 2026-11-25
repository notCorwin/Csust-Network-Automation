import Foundation

public actor AutoLoginEngine {
    public typealias AuthenticateClosure = @Sendable (AppConfig, String, @escaping @Sendable () -> Bool) async -> (AuthOutcome, String)
    public typealias UpdateClosure = @Sendable (AppState, Bool, UInt64) -> Void

    private let store: AppStore
    public let logger: LogStore
    private let snapshot: EngineSnapshot
    private let authenticate: AuthenticateClosure
    private let retryDelays: [TimeInterval]
    private let ipWaitTimeout: TimeInterval
    private let onUpdate: UpdateClosure?

    private var state: AppState
    private var stopped = false
    private var running = false
    private var pending = false
    private var pendingManual = false
    private var workerTask: Task<Void, Never>?
    private var authenticatedGeneration: UInt64?
    private var stateGeneration: UInt64?
    private var lastLoggedPhase: AuthPhase = .idle
    private var lastLoggedDetail = ""
    private var lastLoggedAt: Int64 = 0

    public init(
        store: AppStore,
        logger: LogStore? = nil,
        snapshot: EngineSnapshot,
        retryDelays: [TimeInterval] = [1.0, 2.0],
        ipWaitTimeout: TimeInterval = 5.0,
        authenticate: @escaping AuthenticateClosure = { config, ip, stillConnected in
            await LoginService.login(config: config, ip: ip, stillConnected: stillConnected)
        },
        onUpdate: UpdateClosure? = nil
    ) {
        self.store = store
        self.logger = logger ?? LogStore(paths: store.paths)
        self.snapshot = snapshot
        self.retryDelays = retryDelays
        self.ipWaitTimeout = ipWaitTimeout
        self.authenticate = authenticate
        self.state = store.loadState()
        self.onUpdate = onUpdate
    }

    public func start() {
        guard !stopped else { return }
        enqueue(manual: false)
    }

    public func request() {
        guard !stopped else { return }
        enqueue(manual: false)
    }

    public func checkNow() {
        guard !stopped else { return }
        enqueue(manual: true)
    }

    public func stop() {
        stopped = true
        pending = false
        pendingManual = false
        workerTask?.cancel()
        workerTask = nil
    }

    private func enqueue(manual: Bool) {
        pending = true
        if manual { pendingManual = true }
        guard !running else { return }
        running = true
        workerTask = Task {
            await self.drainQueue()
        }
    }

    private func drainQueue() async {
        defer {
            running = false
            workerTask = nil
        }
        while !stopped && !Task.isCancelled && pending {
            let isManual = pendingManual
            pending = false
            pendingManual = false
            await runCycle(manual: isManual)
        }
    }

    private func activeCampusSSID() -> String {
        switch store.config() {
        case .success(let config): return config.trimmedSSID
        case .failure: return AppConstants.defaultCampusSSID
        }
    }

    private func runCycle(manual: Bool) async {
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
            state.attempt = 0
        }
        var useInternetEvidence = !manual
        while !stopped && !Task.isCancelled {
            let current = snapshot.read()
            if stateGeneration != current.generation {
                stateGeneration = current.generation
                state.attempt = 0
            }
            guard current.permissionAuthorized else {
                state.network = ""
                state.route = ""
                state.attempt = 0
                record(phase: .permission, detail: "需要定位权限才能读取 Wi‑Fi 名称，请在系统设置中允许本 App。")
                return
            }

            let campusSSID = activeCampusSSID()
            guard let network = selectNetwork(current.networks, campusSSID: campusSSID) else {
                state.network = ""
                state.route = ""
                state.attempt = 0
                record(phase: .outside, detail: "未连接校园网（\(campusSSID)），等待网络变化。")
                return
            }
            guard let usableIP = await waitForCampusIPv4(initial: network, campusSSID: campusSSID) else {
                let latest = snapshot.read()
                guard !stopped, !Task.isCancelled, latest.permissionAuthorized,
                      let stillCampus = selectNetwork(latest.networks, campusSSID: campusSSID) else { continue }
                state.network = stillCampus.key
                state.route = ""
                record(phase: .waitingIP, detail: "已连接校园 Wi‑Fi，等待分配 IPv4 地址…")
                return
            }
            let activeNetwork = selectNetwork(snapshot.read().networks, campusSSID: campusSSID) ?? network
            let key = activeNetwork.key
            if state.network != key {
                state.network = key
                state.attempt = 0
                state.failureSince = nil
                state.notified = false
                useInternetEvidence = !manual
            }

            let currentGeneration = snapshot.read().generation
            stateGeneration = currentGeneration
            let stillConnected: @Sendable () -> Bool = { [snapshot] in
                guard !Task.isCancelled else { return false }
                let latest = snapshot.read()
                return latest.permissionAuthorized
                    && latest.generation == currentGeneration
                    && selectNetwork(latest.networks, campusSSID: campusSSID)?.key == key
            }
            if useInternetEvidence {
                if authenticatedGeneration == currentGeneration && snapshot.read().internetConnected && stillConnected() {
                    state.attempt = 0
                    record(phase: .online, detail: "互联网连接正常。")
                    return
                }
                useInternetEvidence = false
            }
            guard stillConnected() else { continue }

            let config: AppConfig
            switch store.effectiveConfig() {
            case .failure(let error):
                state.route = ""
                record(phase: .configError, detail: error.message)
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
                state.attempt = 0
            }
            if state.credentialsBlocked {
                record(phase: .credentials, detail: "认证信息被拒绝，请在设置中修改账号密码，或打开校园网登录页查看。")
                return
            }
            state.attempt = state.attempt == UInt32.max ? .max : state.attempt + 1
            let confirmingSession = authenticatedGeneration == currentGeneration && state.phase == .online
            if !confirmingSession { state.phase = .loggingIn }
            state.detail = confirmingSession ? "正在确认校园网会话…" : "正在登录校园网…"
            publish(state: state, shouldNotify: false)

            let outcome = await authenticate(config, usableIP, stillConnected)
            guard !stopped, !Task.isCancelled else { return }
            guard stillConnected() else { continue }
            switch outcome.0 {
            case .online:
                authenticatedGeneration = currentGeneration
                state.attempt = 0
                state.route = outcome.1
                record(phase: .online, detail: confirmingSession ? "校园网会话有效。" : "登录成功或已经在线。")
                return
            case .credentials:
                state.route = outcome.1
                state.credentialsBlocked = true
                record(phase: .credentials, detail: "认证信息被拒绝，请在设置中修改账号密码，或打开校园网登录页查看。")
                return
            case .retry(let detail):
                state.route = outcome.1
                record(phase: .retry, detail: detail)
                // Bound one authentication round so the coordinator can fall back.
                if state.attempt >= 3 { return }
                let delayIndex = Int(state.attempt) - 1
                if delayIndex >= 0 && delayIndex < retryDelays.count {
                    await sleepInterruptible(retryDelays[delayIndex], while: stillConnected)
                }
                continue
            case .networkChanged:
                state.route = outcome.1
                record(phase: .retry, detail: "网络已变化，重新检查。")
                continue
            }
        }
    }

    private func waitForCampusIPv4(initial: WiFiNetwork, campusSSID: String) async -> String? {
        if let ip = initial.ip, usableIPv4(ip) { return ip }
        guard ipWaitTimeout > 0 else { return nil }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int(ipWaitTimeout * 1000)))
        while !stopped && !Task.isCancelled && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            let current = snapshot.read()
            guard current.permissionAuthorized, let campus = selectNetwork(current.networks, campusSSID: campusSSID) else { return nil }
            if let ip = campus.ip, usableIPv4(ip) { return ip }
        }
        return nil
    }

    private func sleepInterruptible(_ duration: TimeInterval, while shouldContinue: () -> Bool) async {
        guard duration > 0 else { return }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int(duration * 1000)))
        while !stopped && !Task.isCancelled && shouldContinue() && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func record(phase: AuthPhase, detail: String) {
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
