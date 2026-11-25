import AppKit
import Foundation
import NetworkAutoCore

@MainActor
final class SettingsWindowController: NSWindowController {
    private let model: AppModel
    private let usernameField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let ssidField = NSTextField()
    private let loginURLField = NSTextField()
    private let clashControllerField = NSTextField()
    private let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "开机自动启动", target: nil, action: nil)
    private let feedbackLabel = NSTextField(wrappingLabelWithString: "")

    init(model: AppModel) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 330),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "设置 — \(AppConstants.displayName)"
        window.identifier = NSUserInterfaceItemIdentifier(AppConstants.settingsWindowIdentifier)
        window.collectionBehavior = [.managed, .primary]
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)

        setupUI(in: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    private func setupUI(in window: NSWindow) {
        usernameField.placeholderString = "学号 / 校园网账号"
        passwordField.placeholderString = "密码（加密保存在系统钥匙串）"
        ssidField.placeholderString = AppConstants.defaultCampusSSID
        loginURLField.placeholderString = AppConstants.defaultCampusLoginURL.absoluteString
        clashControllerField.placeholderString = "留空自动发现，或填 Socket 路径 / http://127.0.0.1:9097"

        usernameField.setAccessibilityLabel("校园网账号")
        passwordField.setAccessibilityLabel("校园网密码")
        ssidField.setAccessibilityLabel("校园网 Wi-Fi 名称")
        loginURLField.setAccessibilityLabel("校园网认证接口地址")
        clashControllerField.setAccessibilityLabel("Clash 控制器地址")

        func rowLabel(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.alignment = .right
            label.setContentHuggingPriority(.required, for: .horizontal)
            return label
        }

        let grid = NSGridView(views: [
            [rowLabel("校园网账号："), usernameField],
            [rowLabel("校园网密码："), passwordField],
            [rowLabel("校园网 SSID："), ssidField],
            [rowLabel("认证接口地址："), loginURLField],
            [rowLabel("Clash 控制器："), clashControllerField]
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        grid.translatesAutoresizingMaskIntoConstraints = false

        for field in [usernameField, passwordField, ssidField, loginURLField, clashControllerField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 310).isActive = true
        }

        feedbackLabel.textColor = .secondaryLabelColor
        feedbackLabel.font = .systemFont(ofSize: 12)
        feedbackLabel.maximumNumberOfLines = 2

        let resetButton = NSButton(title: "恢复默认地址", target: self, action: #selector(resetDefaults))
        let saveButton = NSButton(title: "保存", target: self, action: #selector(saveConfig))
        saveButton.keyEquivalent = "\r"
        saveButton.bezelStyle = .rounded

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [resetButton, spacer, saveButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY

        let container = NSStackView(views: [grid, launchAtLoginCheckbox, feedbackLabel, buttons])
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 14
        container.translatesAutoresizingMaskIntoConstraints = false

        guard let contentView = window.contentView else { return }
        contentView.addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            container.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            container.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            container.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -20),
            grid.widthAnchor.constraint(equalTo: container.widthAnchor),
            feedbackLabel.widthAnchor.constraint(equalTo: container.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: container.widthAnchor)
        ])
    }

    override func showWindow(_ sender: Any?) {
        let current = model.config
        usernameField.stringValue = current.username
        passwordField.stringValue = current.password
        ssidField.stringValue = current.campusSSID
        loginURLField.stringValue = current.loginURLString
        clashControllerField.stringValue = current.clashControllerAddress
        launchAtLoginCheckbox.state = current.launchAtLogin ? .on : .off
        feedbackLabel.textColor = .secondaryLabelColor
        feedbackLabel.stringValue = ""
        super.showWindow(sender)
        window?.deminiaturize(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func resetDefaults() {
        ssidField.stringValue = AppConstants.defaultCampusSSID
        loginURLField.stringValue = AppConstants.defaultCampusLoginURL.absoluteString
        clashControllerField.stringValue = ""
        feedbackLabel.textColor = .secondaryLabelColor
        feedbackLabel.stringValue = "已填入默认地址，点击“保存”生效。"
    }

    @objc private func saveConfig() {
        let draft = AppConfig(
            username: usernameField.stringValue,
            password: passwordField.stringValue,
            campusSSID: ssidField.stringValue,
            loginURLString: loginURLField.stringValue,
            launchAtLogin: launchAtLoginCheckbox.state == .on,
            clashControllerAddress: clashControllerField.stringValue
        )
        switch model.saveConfig(draft) {
        case .success(let message):
            feedbackLabel.textColor = .systemGreen
            feedbackLabel.stringValue = message
        case .failure(let error):
            feedbackLabel.textColor = .systemRed
            feedbackLabel.stringValue = error.message
        }
    }
}
