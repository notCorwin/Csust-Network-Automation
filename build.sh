#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

APP_PATH="$(pwd)/target/NetworkAuto.app"
EXECUTABLE="$APP_PATH/Contents/MacOS/NetworkAuto"
BUNDLE_ID="com.nowaywastaken.csustautologin"
ARCH="${ARCH:-$(uname -m)}"

resolve_signing_identity() {
  if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    printf '%s' "$CODESIGN_IDENTITY"
    return
  fi
  local detected
  detected="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk '/"Apple Development:|"Developer ID Application:/ { print $2; exit }')"
  if [[ -n "$detected" ]]; then
    printf '%s' "$detected"
  else
    printf '%s' "-"
  fi
}

BUILD_VERSION="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
SIGN_IDENTITY="$(resolve_signing_identity)"

echo "🔨 正在编译 Csust-Network-Automation App (${ARCH}, build ${BUILD_VERSION})..."
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
swift build -c release --product NetworkAuto --arch "$ARCH"
SWIFT_BIN_PATH="$(swift build -c release --show-bin-path --arch "$ARCH")"
cp "$SWIFT_BIN_PATH/NetworkAuto" "$EXECUTABLE"
cp Info.plist "$APP_PATH/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_VERSION" "$APP_PATH/Contents/Info.plist"
[[ "$(plutil -extract CFBundleIdentifier raw -o - "$APP_PATH/Contents/Info.plist")" == "$BUNDLE_ID" ]]
cp Assets/NetworkAuto.icns "$APP_PATH/Contents/Resources/NetworkAuto.icns"

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo "⚠️  未找到开发证书，使用 ad-hoc 签名（重编后钥匙串/定位权限可能需要重新授权；可设置 CODESIGN_IDENTITY 指定固定证书）。"
  codesign --force --deep --identifier "$BUNDLE_ID" --sign - "$APP_PATH" >/dev/null
else
  echo "🔐 使用证书签名：$SIGN_IDENTITY"
  codesign --force --deep --identifier "$BUNDLE_ID" --sign "$SIGN_IDENTITY" "$APP_PATH" >/dev/null
fi
codesign --verify --deep --strict "$APP_PATH"

echo "🧪 正在运行单元测试与安装事务自检..."
swift test
bash install.sh self-test

echo ""
echo "✅ 编译完成！App 位置："
echo "   $APP_PATH"
echo ""
echo "💡 运行 App 后，在菜单栏打开“设置…”配置账号密码（将安全存储于系统钥匙串）"
echo ""
echo "🚀 如需安装并开启自启，请执行："
echo "   bash install.sh"
