# 校园网自动登录

一个面向 macOS 的原生 Swift 菜单栏 App：连接到指定校园 Wi‑Fi 后自动完成认证，并在校园网登录状态失效时重新登录。

## 功能

- 支持 macOS 13+，仅把 SSID 精确匹配 CSUST-Student 作为校园网证据。
- 使用 CoreWLAN Wi‑Fi 事件与 NWPathMonitor 网络路径事件即时检查；在校园网内每 5 秒请求一次 https://www.google.com/generate_204，只有收到空响应的 HTTP 204 才视为互联网可用。
- 认证失败会在收到结果后立即重试；检测到账号或密码错误时暂停自动尝试。
- 先直连认证地址，失败后使用 macOS 系统代理或 PAC，兼容有无代理的环境。
- 使用系统 TLS 校验证书，认证地址固定为 https://login.csust.edu.cn:802/eportal/portal/login。
- 账号、密码和状态使用 UserDefaults 保存，不使用 Keychain。
- 登录时自动启动，菜单栏提供立即检查、诊断、设置、更新和退出。
- 每 3 分钟检查 GitHub Autobuild Release，并校验归档、Bundle ID、可执行文件和 SHA-256 后再替换。

## 系统要求

- macOS 13 或更高版本。
- Apple Silicon Mac；当前构建脚本的目标架构为 arm64。
- Xcode 26，或包含 macOS 15 SDK 的 Command Line Tools。

项目不引入第三方 Swift 依赖。

## 安装与使用

在项目根目录执行：

~~~sh
bash install.sh
~~~

安装器会构建并校验 App，将它安装到 $HOME/Applications/CampusAutoLogin.app，启动 App 并注册登录时自动启动。首次运行需要在设置中填写校园网账号和密码，并允许网络与无线定位权限。

如果没有出现权限提示，可在菜单栏选择“申请定位权限”，或打开“系统设置 → 隐私与安全性 → 定位服务 → 系统服务 → 网络与无线”。

卸载 App 和旧的登录启动配置：

~~~sh
bash install.sh uninstall
~~~

卸载不会删除已保存的配置和日志。

## 开发与验证

构建、运行内置 self-test，并检查安装事务：

~~~sh
bash build.sh
bash install.sh self-test
~~~

基础脚本与 App 包检查：

~~~sh
bash -n build.sh install.sh
plutil -lint Info.plist
codesign --verify --deep --strict target/CampusAutoLogin.app
~~~

主要实现位于 [CampusAutoLoginApp.swift](CampusAutoLoginApp.swift)，更新逻辑位于 [AppUpdater.swift](AppUpdater.swift)，构建和安装入口分别是 [build.sh](build.sh) 与 [install.sh](install.sh)。

## 获取帮助与贡献

请在 [Issue 列表](https://github.com/notCorwin/Csust-Network-Automation/issues) 中附上 macOS 版本、机器架构、复现步骤和诊断信息。提交修改前请运行上述验证命令，并保持改动聚焦；不要提交账号、密码、日志中的敏感信息或构建产物。

维护者：[@notCorwin](https://github.com/notCorwin)。
