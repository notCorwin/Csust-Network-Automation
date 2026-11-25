import AppKit
import Combine
import CoreLocation
import Foundation
import HotspotCore
import Network
import NetworkAutoCore
import ServiceManagement
import UserNotifications

@MainActor
final class AppModel: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    static let shared = AppModel()

    @Published private(set) var config: AppConfig
    @Published private(set) var state: AppState
    @Published private(set) var internetStatus: InternetStatus = .unknown
    @Published private(set) var internetDiagnostics = ClashConnectivityDiagnostics()
    @Published private(set) var permissionStatus: CLAuthorizationStatus
    @Published private(set) var networks: [WiFiNetwork] = []
    @Published private(set) var diagnosticText = ""

    private let store: AppStore
    private let logger: LogStore
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

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private lazy var engine: AutoLoginEngine = {
        AutoLoginEngine(
            store: store,
            logger: logger,
            snapshot: engineSnapshot,
            onUpdate: { [weak self] state, shouldNotify, generation in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let currentGen = self.engineSnapshot.read().generation
                    // Always accept checking=false completion to prevent stale "登录中" indicators.
                    guard currentGen == generation || !state.checking else { return }
                    self.apply(state: state, shouldNotify: shouldNotify)
                }
            }
        )
    }()

    var isLocationAuthorized: Bool {
        permissionStatus == .authorized
    }

    var portalPageURL: URL {
        config.portalPageURL
    }

    var logsDirectoryURL: URL {
        store.paths.logs
    }

    override private init() {
        let store = AppStore()
        self.store = store
        self.logger = LogStore(paths: store.paths)
        switch store.config() {
        case .success(let config):
            self.config = config
        case .failure(let error):
            self.config = .default
            self.diagnosticText = error.message
        }
        self.state = store.loadState()
        self.permissionStatus = locationManager.authorizationStatus
        super.init()
        locationManager.delegate = self
    }

    func start() {
        guard !started else { return }
        started = true
        state.phase = .idle
        state.detail = ""
        requestNotificationPermission()
        syncLaunchAtLogin(enabled: config.launchAtLogin)
        internetMonitor.configure(overrideAddress: config.clashControllerAddress)

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
            self.objectWillChange.send()
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
                self.wifiRecoveryDetail = "已连接校园 Wi‑Fi，正在检查校园网登录。"
                Task { await self.engine.request() }
            case .absent:
                self.campusAssociationFailures = 0
                self.wifiRecoveryDetail = "未发现校园网（\(self.config.trimmedSSID)），正在查找个人热点。"
                self.startHotspotIfAllowed()
            case .associationFailed:
                self.campusAssociationFailures += 1
                self.wifiRecoveryDetail = "连接校园 Wi‑Fi 失败（第 \(self.campusAssociationFailures) 次）；请检查系统 Wi‑Fi 设置。"
                if self.campusAssociationFailures >= 3 {
                    self.campusAssociationFailures = 0
                    self.enterCampusFallback()
                }
            case .failed(let message):
                self.wifiRecoveryDetail = message
                self.diagnosticText = message
            case .cancelled:
                break
            }
            self.objectWillChange.send()
        }

        wifiMonitor.onChange = { [weak self] in
            Task { @MainActor [weak self] in self?.requestCheck() }
        }
        wifiMonitor.start()

        let workspaceNotifications = NSWorkspace.shared.notificationCenter
        workspaceNotifications.addObserver(self, selector: #selector(networkWillSleep(_:)), name: NSWorkspace.willSleepNotification, object: nil)
        workspaceNotifications.addObserver(self, selector: #selector(networkDidWake(_:)), name: NSWorkspace.didWakeNotification, object: nil)

        internetMonitor.onChange = { [weak self] status, diagnostics in
            guard let self else { return }
            let previous = self.internetStatus
            self.internetStatus = status
            self.internetDiagnostics = diagnostics
            self.engineSnapshot.updateConnectivity(status.isConnected)
            if previous != status, status == .dnsStalled || status == .offline {
                Task { await self.engine.request() }
            }
            if previous != status {
                self.recoverWiFiIfNeeded()
            }
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
        connectivityTimer.tolerance = 3
        RunLoop.main.add(connectivityTimer, forMode: .common)
        self.connectivityTimer = connectivityTimer

        requestLocationPermissionIfNeeded()
        refreshNetworks()
        Task { await engine.start() }

        if case .failure = store.effectiveConfig() {
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
        await engine.stop()
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
        Task { await engine.request() }
    }

    private func acquireWiFiControlIfNeeded() -> Bool {
        if ownsWiFiControl { return true }
        do {
            guard try wifiControlLock.tryAcquire() else {
                wifiControlIssue = .occupied
                wifiRecoveryDetail = "其他应用正在控制 Wi‑Fi；请暂停 Sequoia Hotspot 后重试。"
                diagnosticText = wifiRecoveryDetail
                return false
            }
            ownsWiFiControl = true
            wifiControlIssue = nil
            wifiRecoveryDetail = ""
            return true
        } catch {
            wifiControlIssue = .unavailable
            wifiRecoveryDetail = "无法获取 Wi‑Fi 控制权；请检查应用权限后重试。"
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
        let campusSSID = config.trimmedSSID
        let allowed = maySelectCampus(
            networks: networks,
            permissionAuthorized: true,
            ownedHotspotSSID: verifiedHotspotSSID(ownedHotspotSSID, bssid: ownedHotspotBSSID, networks: networks)
        ) || (campusFallback && selectNetwork(networks, campusSSID: campusSSID) != nil && networks.allSatisfy {
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
            return
        }
        wakeGraceUntil = nil
        if let until = fallbackUntil, ContinuousClock.now < until {
            startHotspotIfAllowed()
            return
        }
        fallbackUntil = nil
        let campusSSID = config.trimmedSSID
        if selectNetwork(networks, campusSSID: campusSSID) != nil {
            wifiRecovery.cancel()
            hotspot.setEnabled(false)
            return
        }
        let candidateHotspotSSID = pendingHotspotSSID ?? lastRequestedHotspotSSID
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
            let verified = verifiedHotspotSSID(self.ownedHotspotSSID, bssid: self.ownedHotspotBSSID, networks: self.networks)
            guard !Task.isCancelled, self.started, !self.networkSleeping,
                  self.engineSnapshot.read().generation == generation,
                  self.fallbackUntil == nil,
                  !(self.pathMonitor.currentPath.status == .satisfied && self.pathMonitor.currentPath.usesInterfaceType(.wiredEthernet)),
                  maySelectCampus(networks: self.networks, permissionAuthorized: self.isLocationAuthorized, ownedHotspotSSID: verified) else { return }
            self.wifiRecovery.request(
                snapshot: self.engineSnapshot,
                ownedHotspotSSID: verified,
                campusSSID: self.config.trimmedSSID
            )
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
        internetMonitor.setSuspended(true)
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
        internetMonitor.setSuspended(false)
        internetMonitor.reset(networkAvailable: pathMonitor.currentPath.status == .satisfied)
        requestCheck()
    }

    func saveConfig(_ newConfig: AppConfig) -> Result<String, AppError> {
        if let error = newConfig.validationError() {
            diagnosticText = error
            return .failure(AppError(message: error))
        }
        do {
            try store.saveConfig(newConfig)
            config = newConfig
            syncLaunchAtLogin(enabled: newConfig.launchAtLogin)
            internetMonitor.configure(overrideAddress: newConfig.clashControllerAddress)
            consecutiveCampusFallbacks = 0
            fallbackUntil = nil
            hotspot.setEnabled(false)
            engineSnapshot.invalidateNetwork()
            diagnosticText = "配置已保存（密码已安全存储于钥匙串），正在重新检测…"
            refreshNetworks()
            recoverWiFiIfNeeded()
            Task { await engine.checkNow() }
            return .success(diagnosticText)
        } catch {
            let message = "保存失败：\(error.localizedDescription)"
            diagnosticText = message
            return .failure(AppError(message: message))
        }
    }

    func openPortalPage() {
        NSWorkspace.shared.open(portalPageURL)
    }

    func openLogsFolder() {
        try? ensurePrivateDirectory(logsDirectoryURL)
        NSWorkspace.shared.open(logsDirectoryURL)
    }

    func copyDiagnosticsToPasteboard() {
        let report = diagnosticSummary()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
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

    // MARK: - Transparent Menu Status Presentation

    var currentNetworkTitle: String {
        if networkSleeping { return "当前网络：系统休眠中" }
        if !isLocationAuthorized { return "当前网络：需要定位权限" }
        if lastPathSignature?.satisfied == true && lastPathSignature?.usesEthernet == true {
            return "当前网络：有线以太网"
        }
        if let active = networks.first(where: { $0.ssid != nil || $0.bssid != nil || $0.ip != nil }) {
            let name = active.ssid ?? "未知 Wi‑Fi"
            if let ip = active.ip {
                return "当前网络：\(name) (\(ip))"
            }
            return "当前网络：\(name)（等待 IP）"
        }
        return "当前网络：未连接"
    }

    var currentNetworkSubtitle: String {
        if !isLocationAuthorized {
            return "请在“系统设置 → 隐私与安全性 → 定位服务”中允许本应用"
        }
        if lastPathSignature?.satisfied == true && lastPathSignature?.usesEthernet == true {
            return "已通过有线网络连接，暂停 Wi‑Fi 自动接管"
        }
        if let active = networks.first(where: { $0.ssid != nil || $0.bssid != nil || $0.ip != nil }) {
            var parts = ["接口 \(active.interfaceName)"]
            if let bssid = active.bssid { parts.append("BSSID \(bssid)") }
            if lastPathSignature?.isExpensive == true { parts.append("计费网络") }
            return parts.joined(separator: " · ")
        }
        if let grace = wakeGraceUntil, ContinuousClock.now < grace {
            let remaining = max(1, Int((grace - ContinuousClock.now).components.seconds))
            return "系统刚唤醒，等待系统自动重连（约 \(remaining) 秒）"
        }
        return "无活跃 Wi‑Fi 连接，将自动搜索校园网"
    }

    var campusStatusTitle: String {
        let status = campusConnectionStatus(
            networks: networks,
            permissionAuthorized: isLocationAuthorized,
            state: state,
            campusSSID: config.trimmedSSID
        )
        return "校园网：\(status)"
    }

    var campusStatusSubtitle: String {
        if !isLocationAuthorized {
            return "目标 SSID：\(config.trimmedSSID)（等待定位权限）"
        }
        if let until = fallbackUntil, ContinuousClock.now < until {
            let remaining = max(1, Int((until - ContinuousClock.now).components.seconds))
            return "校园网暂不可用，已切换等待冷却（剩余 \(remaining) 秒）"
        }
        if state.checking {
            return state.detail.isEmpty ? "正在检查校园网状态…" : state.detail
        }
        if state.phase == .online {
            var parts: [String] = []
            if !state.route.isEmpty { parts.append("路由：\(routeLabel(state.route))") }
            if let ts = state.lastSuccess {
                parts.append("上次确认 \(Self.timeFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(ts))))")
            }
            return parts.isEmpty ? "校园网会话正常" : parts.joined(separator: " · ")
        }
        if selectNetwork(networks, campusSSID: config.trimmedSSID) == nil {
            if !wifiRecoveryDetail.isEmpty { return wifiRecoveryDetail }
            return "目标 SSID：\(config.trimmedSSID)"
        }
        return state.detail.isEmpty ? "等待触发认证" : state.detail
    }

    var personalHotspotStatusText: String {
        let isExpensiveWiFi = (lastPathSignature?.usesWiFi == true && lastPathSignature?.isExpensive == true)
        return personalHotspotStatus(
            networks: networks,
            permissionAuthorized: isLocationAuthorized,
            ownedSSID: ownedHotspotSSID,
            ownedBSSID: ownedHotspotBSSID,
            sleeping: networkSleeping,
            controlIssue: wifiControlIssue,
            phase: hotspot.phase,
            recognizedHotspot: hotspotRecognition(
                profile: profileRecognizesHotspot,
                cachedMatch: hotspotIdentityCache.matching(networks: networks) != nil,
                pathExpensive: isExpensiveWiFi
            ),
            campusSSID: config.trimmedSSID
        )
    }

    var hotspotStatusTitle: String {
        if let owned = verifiedHotspotSSID(ownedHotspotSSID, bssid: ownedHotspotBSSID, networks: networks) {
            return "个人热点：已连接（\(owned)）"
        }
        if personalHotspotStatusText == "已连接",
           let ssid = networks.first(where: { $0.ssid != nil && $0.ssid != config.trimmedSSID })?.ssid {
            return "个人热点：已连接（\(ssid)）"
        }
        return "个人热点：\(personalHotspotStatusText)"
    }

    var hotspotStatusSubtitle: String {
        if personalHotspotStatusText == "无法识别" {
            return "当前为非校园 Wi‑Fi，无法确认是否为个人热点"
        }
        if hotspot.enabled {
            return hotspot.status
        }
        if let owned = verifiedHotspotSSID(ownedHotspotSSID, bssid: ownedHotspotBSSID, networks: networks) {
            return "由本应用接管连接（\(owned)），将周期性探测校园网恢复"
        }
        if selectNetwork(networks, campusSSID: config.trimmedSSID) != nil {
            return "当前已连接校园网，待命"
        }
        return wifiRecoveryDetail.isEmpty ? "校园网不可用时自动寻找同 Apple 账户热点" : wifiRecoveryDetail
    }

    var internetStatusTitle: String {
        "互联网：\(internetStatus.title)"
    }

    var internetStatusSubtitle: String {
        var parts = [internetDiagnostics.sourceDescription]
        if let verifiedAt = internetDiagnostics.lastVerifiedAt, internetStatus == .online {
            parts.append("更新于 \(Self.timeFormatter.string(from: verifiedAt))")
        }
        return parts.joined(separator: " · ")
    }

    var statusText: String {
        campusStatusSubtitle
    }

    func diagnosticSummary() -> String {
        let bundleVersion = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        let shortVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let networkLines = networks.isEmpty
            ? ["(无 Wi-Fi 接口信息)"]
            : networks.map { "  - \($0.interfaceName): ssid=\($0.ssid ?? "nil"), bssid=\($0.bssid ?? "nil"), ip=\($0.ip ?? "nil")" }
        let recentLogs = logger.recentEntries(limit: 12)
        let logSection = recentLogs.isEmpty ? "  (本次运行暂无新日志)" : recentLogs.map { "  \($0)" }.joined(separator: "\n")

        return """
        === \(AppConstants.displayName) 诊断信息 ===
        版本：\(shortVersion) (\(bundleVersion))
        时间：\(ISO8601DateFormatter().string(from: Date()))
        定位权限：\(permissionStatus.rawValue) (authorized=\(isLocationAuthorized))
        配置摘要：ssid=\(config.trimmedSSID), loginURL=\(config.loginURLString), launchAtLogin=\(config.launchAtLogin), clashOverride=\(config.clashControllerAddress.isEmpty ? "auto" : config.clashControllerAddress)
        \(currentNetworkTitle) | \(currentNetworkSubtitle)
        \(campusStatusTitle) | \(campusStatusSubtitle)
        \(hotspotStatusTitle) | \(hotspotStatusSubtitle)
        \(internetStatusTitle) | \(internetStatusSubtitle)
        Clash 控制器：\(internetDiagnostics.endpointDescription ?? "未连接")
        网络路径：\(lastPathSignature.map { "satisfied=\($0.satisfied), wifi=\($0.usesWiFi), ethernet=\($0.usesEthernet), expensive=\($0.isExpensive), ifaces=\($0.interfaces)" } ?? "未就绪")
        Wi-Fi 接口：
        \(networkLines.joined(separator: "\n"))
        最近日志：
        \(logSection)
        """
    }

    private func apply(state: AppState, shouldNotify: Bool) {
        self.state = state
        if state.phase == .online {
            consecutiveCampusFallbacks = 0
        }
        if shouldFallbackForAuthentication(state, campus: selectNetwork(networks, campusSSID: config.trimmedSSID)), fallbackUntil == nil {
            enterCampusFallback()
        }
        if shouldNotify {
            let content = UNMutableNotificationContent()
            content.title = AppConstants.displayName
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
            let campusSSID = config.trimmedSSID
            Task { @MainActor [weak self] in
                let result = await Task.detached {
                    WiFiMonitor.personalHotspotProfile(networks: refreshed, campusSSID: campusSSID)
                }.value
                guard let self, acceptsHotspotProfileResult(
                    token: token,
                    currentToken: self.profileLookupGeneration,
                    authorized: self.isLocationAuthorized,
                    queried: refreshed,
                    current: self.networks
                ) else { return }
                self.profileRecognizesHotspot = result
                self.objectWillChange.send()
            }
        }
        if networkChanged { internetMonitor.reset() }
        networks = refreshed
        if !maySelectCampus(
            networks: refreshed,
            permissionAuthorized: isLocationAuthorized,
            ownedHotspotSSID: verifiedHotspotSSID(ownedHotspotSSID, bssid: ownedHotspotBSSID, networks: refreshed)
        ) {
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

    private func syncLaunchAtLogin(enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            diagnosticText = "开机自启设置更新失败：\(error.localizedDescription)"
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
