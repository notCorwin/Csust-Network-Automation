import AppKit
import Combine
import Foundation
import NetworkAutoCore
import Symbols

@MainActor
func removeStatusItemPreservingPosition(_ item: NSStatusItem) {
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
final class StatusBarController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let item = NSStatusBar.system.statusItem(withLength: 28)
    private let icon = NSImageView(frame: .zero)
    private let menu = NSMenu()
    private var connectivitySubscription: AnyCancellable?
    private var menuRefreshTimer: Timer?

    private var networkItem: NSMenuItem?
    private var campusItem: NSMenuItem?
    private var hotspotItem: NSMenuItem?
    private var internetItem: NSMenuItem?
    private var online: Bool

    init(model: AppModel) {
        self.model = model
        self.online = model.internetStatus.isConnected
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
        updateOfflineSymbolEffect(connected: online)
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        updateAccessibility()

        connectivitySubscription = model.$internetStatus
            .removeDuplicates()
            .sink { [weak self] status in
                self?.setConnectivity(status.isConnected)
                self?.item.button?.setAccessibilityLabel("互联网：\(status.title)")
            }
    }

    func stop() {
        menuRefreshTimer?.invalidate()
        menuRefreshTimer = nil
        connectivitySubscription?.cancel()
        icon.removeAllSymbolEffects()
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
        icon.setSymbolImage(
            symbol(connected ? "network" : "network.slash"),
            contentTransition: .replace.upUp.byLayer
        )
        updateOfflineSymbolEffect(connected: connected)
        updateAccessibility()
    }

    private func updateOfflineSymbolEffect(connected: Bool) {
        icon.removeAllSymbolEffects()
        if !connected {
            icon.addSymbolEffect(.pulse, options: .repeating)
        }
    }

    private func updateAccessibility() {
        item.button?.setAccessibilityLabel(online ? "互联网已连接" : "互联网未连接")
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshMenu()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshMenu() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        menuRefreshTimer = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        menuRefreshTimer?.invalidate()
        menuRefreshTimer = nil
    }

    private func refreshMenu() {
        updateStatusItem(networkItem, title: model.currentNetworkTitle, subtitle: model.currentNetworkSubtitle)
        updateStatusItem(campusItem, title: model.campusStatusTitle, subtitle: model.campusStatusSubtitle)
        updateStatusItem(hotspotItem, title: model.hotspotStatusTitle, subtitle: model.hotspotStatusSubtitle)
        updateStatusItem(internetItem, title: model.internetStatusTitle, subtitle: model.internetStatusSubtitle)
    }

    private func updateStatusItem(_ item: NSMenuItem?, title: String, subtitle: String) {
        guard let item else { return }
        item.title = title
        item.subtitle = subtitle
        item.toolTip = subtitle
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        func statusItem(symbolName: String) -> NSMenuItem {
            let item = menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            return item
        }
        @discardableResult
        func action(_ title: String, _ selector: Selector, keyEquivalent: String = "", symbolName: String? = nil) -> NSMenuItem {
            let item = menu.addItem(withTitle: title, action: selector, keyEquivalent: keyEquivalent)
            item.target = self
            item.isEnabled = true
            if let symbolName {
                item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            }
            return item
        }

        menu.removeAllItems()
        menu.addItem(.sectionHeader(title: "网络状态"))
        networkItem = statusItem(symbolName: "wifi")
        campusItem = statusItem(symbolName: "building.columns")
        hotspotItem = statusItem(symbolName: "personalhotspot")
        internetItem = statusItem(symbolName: "globe")

        menu.addItem(.separator())
        action("打开校园网登录页", #selector(openPortalPage), symbolName: "safari")
        action("打开日志目录", #selector(openLogsFolder), symbolName: "doc.text.magnifyingglass")
        action("复制诊断信息", #selector(copyDiagnostics), symbolName: "doc.on.clipboard")

        menu.addItem(.separator())
        action("设置…", #selector(openSettings), keyEquivalent: ",", symbolName: "gearshape")
        action("退出", #selector(quit), keyEquivalent: "q", symbolName: "power")

        refreshMenu()
    }

    @objc private func openPortalPage() { model.openPortalPage() }
    @objc private func openLogsFolder() { model.openLogsFolder() }
    @objc private func copyDiagnostics() { model.copyDiagnosticsToPasteboard() }
    @objc private func openSettings() { (NSApp.delegate as? AppDelegate)?.openSettingsWindow() }
    @objc private func quit() { model.quit() }
}
