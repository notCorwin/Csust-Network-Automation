#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

APP_PATH="$(pwd)/target/NetworkAuto.app"
EXECUTABLE="$APP_PATH/Contents/MacOS/NetworkAuto"
BUNDLE_ID="com.nowaywastaken.csustautologin"

echo "🔨 正在编译 Csust-Network-Automation App..."
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
swift build -c release --product NetworkAuto --arch arm64
SWIFT_BIN_PATH="$(swift build -c release --show-bin-path --arch arm64)"
cp "$SWIFT_BIN_PATH/NetworkAuto" "$EXECUTABLE"
cp Info.plist "$APP_PATH/Contents/Info.plist"
[[ "$(plutil -extract CFBundleIdentifier raw -o - "$APP_PATH/Contents/Info.plist")" == "$BUNDLE_ID" ]]
cp Assets/NetworkAuto.icns "$APP_PATH/Contents/Resources/NetworkAuto.icns"
codesign --force --deep --identifier "$BUNDLE_ID" --sign - "$APP_PATH" >/dev/null
codesign --verify --deep --strict "$APP_PATH"

"$EXECUTABLE" --headless-self-test
bash install.sh self-test

echo ""
echo "✅ 编译完成！App 位置："
echo "   $APP_PATH"
echo ""
echo "💡 运行 App 后，在菜单栏打开设置配置账号密码"
echo ""
echo "🚀 如需开机自启，请执行："
echo "   bash install.sh"
