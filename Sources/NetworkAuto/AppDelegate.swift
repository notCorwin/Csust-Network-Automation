import AppKit
import Foundation
import NetworkAutoCore
import ServiceManagement

@MainActor
@discardableResult
private func runFocusedAlert(_ alert: NSAlert) -> NSApplication.ModalResponse {
    NSApp.setActivationPolicy(.regular)
    alert.layout()
    let window = alert.window
    window.center()
    if let screen = window.screen {
        window.setFrameOrigin(NSPoint(x: window.frame.minX, y: screen.visibleFrame.midY - window.frame.height / 2))
    }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    let response = alert.runModal()
    (NSApp.delegate as? AppDelegate)?.refreshActivationPolicy()
    return response
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var instanceLock: AppInstanceLock?
    private var statusBar: StatusBarController?
    private var settingsWindow: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowVisibilityChanged(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
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
            NSLog("\(AppConstants.displayName) 已在运行，退出重复实例。")
            showStartupError("\(AppConstants.displayName) 已经在运行。请使用菜单栏中的现有图标。")
            NSApp.terminate(nil)
            return
        } catch {
            NSLog("无法取得 \(AppConstants.displayName) 运行锁：%@", error.localizedDescription)
            showStartupError("无法启动 \(AppConstants.displayName)：\(error.localizedDescription)")
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        AppModel.shared.start()
        statusBar = StatusBarController(model: AppModel.shared)
        updateActivationPolicy()
        signalReadinessIfRequested()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await AppModel.shared.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
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

    /// Standard AppKit Edit/Window menus enable Cmd+V/C/X/A/Z/W in text fields and dialogs.
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出 \(AppConstants.displayName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func signalReadinessIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["NETWORK_AUTO_READY_FILE"],
              !path.isEmpty else {
            return
        }
        FileManager.default.createFile(atPath: path, contents: Data())
    }

    private func showStartupError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = AppConstants.displayName
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        runFocusedAlert(alert)
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
