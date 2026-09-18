# Csust-Network-Automation

[![macOS 构建](https://github.com/notCorwin/Csust-Network-Automation/actions/workflows/release.yml/badge.svg?branch=main)](https://github.com/notCorwin/Csust-Network-Automation/actions/workflows/release.yml)

一个适用于 macOS 15+ 的原生 AppKit 菜单栏 App，安装包为 `NetworkAuto.app`。它持续检查互联网连通性，并在 `CSUST-Student` 的认证失效时自动登录 `login.csust.edu.cn`。

## 功能

- Wi‑Fi 和网络路径变化时立即检查；每 5 秒请求一次 `https://www.google.com/generate_204`，收到空的 HTTP 204 响应才视为互联网可用。离开校园网后仍检测连通性，但不发送认证请求。
- 认证失败后立即重试，账号或密码被拒绝时暂停，等待修改配置或手动重试。
- 认证时先尝试直连，再尝试 macOS 系统代理或 PAC；HTTPS 使用系统证书校验。
- 菜单栏在互联网可用时显示 SF Symbols `network`，不可用时显示持续执行按图层、向上到向上替换动画的 `network.slash`。菜单提供实时状态、立即检查、诊断、设置、更新和退出。
- 自动注册登录时启动，每 3 分钟检查一次 GitHub `autobuild` Release；有更新时在菜单中显示提交哈希和发布时间，点击更新项并确认后安装。安装前校验 SHA-256 摘要、归档内容和 App 身份。

账号、密码和运行状态保存在 **UserDefaults**，不使用 Keychain。请在自己信任的 macOS 用户账户中使用。

## 系统要求

- macOS 15 或更新版本，Apple Silicon Mac（构建脚本目前只生成 arm64 App）。
- 从源码安装需要 Xcode 26，或提供 macOS 15 SDK 的 Command Line Tools，以及 `git`。
- 需要允许 App 使用定位服务以读取当前 Wi‑Fi 名称；校园网 SSID 必须精确为 `CSUST-Student`。

项目没有第三方 Swift 依赖。

## 安装与使用

从源码安装并启动：

```sh
git clone https://github.com/notCorwin/Csust-Network-Automation.git
cd Csust-Network-Automation
bash install.sh
```

安装器会构建和测试 App，将其放入 `~/Applications/NetworkAuto.app`，启动并注册登录时自动启动。首次打开时，在菜单栏的网络图标 → **设置…** 中保存校园网账号和密码；设置窗口只包含这两个字段及保存按钮。然后按系统提示允许定位权限。连接 `CSUST-Student` 后即可自动检查和认证；需要主动检查时选择 **立即检查**，需要查看认证服务器连接情况时选择 **诊断**。

从旧版 `CampusAutoLogin.app` 升级时，请重新运行安装脚本。安装成功后，它会移除 `~/Applications` 或 `/Applications` 中同一 Bundle ID 的旧 App；Bundle ID 和用户数据位置保持不变，以沿用已保存的账号密码及登录启动配置。

如果系统没有显示定位权限提示，可在菜单栏选择 **申请定位权限** 或 **打开定位设置**。在“系统设置 → 隐私与安全性 → 定位服务”中检查 App 及“系统服务 → 网络与无线”的权限。没有可读取的 SSID 时，App 无法判断是否在校园网。

卸载 App 和旧版登录启动配置：

```sh
bash install.sh uninstall
```

卸载会保留 UserDefaults 中的配置和运行状态，以及 `~/Library/Logs/csust-auto-login/` 下的日志。

## 开发与验证

在仓库根目录运行：

```sh
bash build.sh
bash -n build.sh install.sh
plutil -lint Info.plist
codesign --verify --deep --strict target/NetworkAuto.app
```

`build.sh` 包含 Swift 6 严格并发类型检查、编译、App 内置 self-test 和安装事务 self-test。主要逻辑位于 [NetworkAutoApp.swift](NetworkAutoApp.swift)，更新器位于 [AppUpdater.swift](AppUpdater.swift)，构建和安装脚本分别是 [build.sh](build.sh) 与 [install.sh](install.sh)。推送后，[GitHub Actions](.github/workflows/release.yml) 会构建并更新 `autobuild` Release。

App 图标来自 [原始 PNG](Assets/NetworkAutoIcon.png)，构建时使用 [macOS 图标文件](Assets/NetworkAuto.icns)；菜单栏显示 SF Symbols 网络图标。

## 获取帮助与贡献

遇到问题请到 [Issues](https://github.com/notCorwin/Csust-Network-Automation/issues) 提交 macOS 版本、机器架构、复现步骤和菜单栏诊断结果。分享诊断或日志前，请先移除账号、密码及不愿公开的网络信息。

欢迎提交聚焦的修改；提交前运行上述验证命令。项目由 [@notCorwin](https://github.com/notCorwin) 维护。
