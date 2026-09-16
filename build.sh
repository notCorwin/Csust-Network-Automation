#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

APP_PATH="$(pwd)/target/NetworkAuto.app"
EXECUTABLE="$APP_PATH/Contents/MacOS/NetworkAuto"
APP_REVISION="${APP_REVISION:-development}"

echo "🔨 正在编译 Csust-Network-Automation App..."
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library -typecheck \
	-target arm64-apple-macosx15.0 \
	-framework AppKit \
  -framework SwiftUI \
  -framework CoreLocation \
  -framework CoreWLAN \
  -framework CryptoKit \
  -framework Network \
  -framework ServiceManagement \
  -framework UserNotifications \
  NetworkAutoApp.swift AppUpdater.swift
swiftc -swift-version 6 -strict-concurrency=complete -O -parse-as-library \
	-target arm64-apple-macosx15.0 \
	-framework AppKit \
  -framework SwiftUI \
  -framework CoreLocation \
  -framework CoreWLAN \
  -framework CryptoKit \
  -framework Network \
  -framework ServiceManagement \
  -framework UserNotifications \
  -o "$EXECUTABLE" NetworkAutoApp.swift AppUpdater.swift
cp Info.plist "$APP_PATH/Contents/Info.plist"
cp Assets/NetworkAuto.icns "$APP_PATH/Contents/Resources/NetworkAuto.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleSourceRevision $APP_REVISION" "$APP_PATH/Contents/Info.plist"
codesign --force --deep --sign - "$APP_PATH" >/dev/null
codesign --verify --deep --strict "$APP_PATH"

"$EXECUTABLE" --self-test
bash install.sh self-test

echo ""
echo "✅ 编译完成！App 位置："
echo "   $APP_PATH"
echo ""
echo "💡 运行 App 后，在菜单栏打开设置配置账号密码"
echo ""
echo "🚀 如需开机自启，请执行："
echo "   bash install.sh"
