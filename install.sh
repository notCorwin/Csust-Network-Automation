#!/usr/bin/env bash
set -euo pipefail
umask 077
cd "$(dirname "$0")"

LABEL="com.nowaywastaken.csustautologin"
DOMAIN="gui/$(id -u)"
APP_NAME="NetworkAuto"
LEGACY_NAME="CampusAutoLogin"
APP_SOURCE="${APP_SOURCE:-$(pwd)/target/NetworkAuto.app}"
APP_DEST="${APP_DEST:-$HOME/Applications/$APP_NAME.app}"
APP_EXEC="$APP_DEST/Contents/MacOS/$APP_NAME"
DATA_DIR="${DATA_DIR:-$HOME/Library/Application Support/csust-auto-login}"
OLD_PLIST="${OLD_PLIST:-$HOME/Library/LaunchAgents/$LABEL.plist}"

ACTION="${1:-install}"
if [[ $# -gt 1 ]]; then
  echo "用法：bash install.sh [install|uninstall|self-test]" >&2
  exit 2
fi

old_loaded() {
  launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1
}

stop_old_service() {
  if old_loaded; then launchctl bootout "$DOMAIN/$LABEL"; fi
}

app_pids() {
  ps -axo pid=,command= | awk '$2 ~ /\/(NetworkAuto\.app\/Contents\/MacOS\/NetworkAuto|CampusAutoLogin\.app\/Contents\/MacOS\/CampusAutoLogin)$/ { print $1 }'
}

legacy_apps() {
  local app
  for app in "$HOME/Applications/$LEGACY_NAME.app" "/Applications/$LEGACY_NAME.app"; do
    if [[ -x "$app/Contents/MacOS/$LEGACY_NAME" ]] &&
       [[ "$(plutil -extract CFBundleIdentifier raw -o - "$app/Contents/Info.plist" 2>/dev/null)" == "$LABEL" ]]; then
      printf '%s\n' "$app"
    fi
  done
}

wait_for_pids() {
  local pids="$1"
  local pid
  for _ in {1..20}; do
    local alive=false
    for pid in $pids; do
      if kill -0 "$pid" 2>/dev/null; then alive=true; fi
    done
    [[ "$alive" == false ]] && return 0
    sleep 0.25
  done
  return 1
}

quit_app() {
  local pids="$1"
  local app
  if [[ -x "$APP_EXEC" ]]; then
    "$APP_EXEC" --unregister >/dev/null 2>&1 || true
  fi
  while IFS= read -r app; do
    "$app/Contents/MacOS/$LEGACY_NAME" --unregister >/dev/null 2>&1 || true
  done < <(legacy_apps)
  osascript -e "tell application id \"$LABEL\" to quit" >/dev/null 2>&1 || true
  for pid in $pids; do
    kill -TERM "$pid" 2>/dev/null || true
  done
}

switch_app() {
  local staged="$1"
  local destination="$2"
  local previous="$3"

  rm -rf "$previous"
  if [[ -e "$destination" ]]; then
    if ! mv "$destination" "$previous"; then
      return 1
    fi
  fi
  if mv "$staged" "$destination"; then
    return 0
  fi

  rm -rf "$destination"
  if [[ -e "$previous" ]]; then
    mv "$previous" "$destination"
  fi
  return 1
}

run_self_test() {
  local root
  root="$(mktemp -d "${TMPDIR:-/tmp}/network-auto-install.XXXXXX")"
  mkdir -p "$root/destination/Contents" "$root/staged/Contents"
  printf 'old' > "$root/destination/Contents/version"
  printf 'new' > "$root/staged/Contents/version"

  switch_app "$root/staged" "$root/destination" "$root/previous"
  [[ "$(<"$root/destination/Contents/version")" == new ]]
  [[ "$(<"$root/previous/Contents/version")" == old ]]

  rm -rf "$root/destination"
  mkdir -p "$root/destination/Contents"
  printf 'old' > "$root/destination/Contents/version"
  if switch_app "$root/missing" "$root/destination" "$root/previous-failed" 2>/dev/null; then
    echo "安装事务 self-test 未捕获 staging 失败。" >&2
    rm -rf "$root"
    return 1
  fi
  [[ "$(<"$root/destination/Contents/version")" == old ]]
  rm -rf "$root"
  echo "install transaction self-test passed"
}

case "$ACTION" in
  self-test)
    run_self_test
    exit 0
    ;;
  uninstall)
    stop_old_service
    old_pids="$(app_pids)"
    quit_app "$old_pids"
    wait_for_pids "$old_pids" || true
    rm -rf "$APP_DEST"
    while IFS= read -r app; do rm -rf "$app"; done < <(legacy_apps)
    rm -f "$OLD_PLIST"
    echo "已卸载 App 和旧登录启动配置；配置与日志已保留。"
    exit 0
    ;;
  install) ;;
  *)
    echo "用法：bash install.sh [install|uninstall|self-test]" >&2
    exit 2
    ;;
esac

echo "正在构建 Csust-Network-Automation App..."
bash build.sh
[[ -x "$APP_SOURCE/Contents/MacOS/$APP_NAME" ]]

install -d -m 700 "$DATA_DIR" "$HOME/Applications"
STAGING_DIR="$(mktemp -d "$DATA_DIR/install.XXXXXX")"
NEW_APP="$STAGING_DIR/new-app"
PREVIOUS_APP="$STAGING_DIR/previous-app"
PREVIOUS_LOADED=false
SWITCH_STARTED=false
STOPPED_APPS=false

if old_loaded; then PREVIOUS_LOADED=true; fi

cleanup() {
  local result=$?
  if [[ $result -ne 0 && "$SWITCH_STARTED" == true ]]; then
    echo "安装失败，恢复此前的 App 和后台配置..." >&2
    quit_app "$(app_pids)"
    local current_pids
    current_pids="$(app_pids)"
    wait_for_pids "$current_pids" || true
    rm -rf "$APP_DEST"
    if [[ -d "$PREVIOUS_APP" ]]; then
      mv "$PREVIOUS_APP" "$APP_DEST"
    fi
    if [[ -f "$STAGING_DIR/previous.plist" ]]; then
      install -m 600 "$STAGING_DIR/previous.plist" "$OLD_PLIST"
      if [[ "$PREVIOUS_LOADED" == true ]]; then
        launchctl bootstrap "$DOMAIN" "$OLD_PLIST" || true
      fi
    fi
    if [[ -d "$APP_DEST" ]]; then
      open "$APP_DEST" >/dev/null 2>&1 || true
    else
      while IFS= read -r app; do open "$app" >/dev/null 2>&1 || true; done < <(legacy_apps)
    fi
  elif [[ $result -ne 0 && "$STOPPED_APPS" == true ]]; then
    if [[ -d "$APP_DEST" ]]; then
      open "$APP_DEST" >/dev/null 2>&1 || true
    else
      while IFS= read -r app; do open "$app" >/dev/null 2>&1 || true; done < <(legacy_apps)
    fi
  fi
  rm -rf "$STAGING_DIR"
  return "$result"
}
trap cleanup EXIT

# 先复制并校验新 App；任何 staging 失败都不会触碰现有安装。
ditto "$APP_SOURCE" "$NEW_APP"
[[ -x "$NEW_APP/Contents/MacOS/$APP_NAME" ]]
codesign --verify --deep --strict "$NEW_APP"
EXPECTED_VERSION="$(plutil -extract CFBundleVersion raw -o - "$NEW_APP/Contents/Info.plist")"

if [[ -f "$OLD_PLIST" ]]; then cp -p "$OLD_PLIST" "$STAGING_DIR/previous.plist"; fi

stop_old_service
old_pids="$(app_pids)"
STOPPED_APPS=true
quit_app "$old_pids"
wait_for_pids "$old_pids"

# switch_app 在新副本移动失败时会先恢复旧副本；成功后才进入后续可恢复阶段。
if ! switch_app "$NEW_APP" "$APP_DEST" "$PREVIOUS_APP"; then
  echo "无法切换 App，现有安装未改动。" >&2
  if [[ "$PREVIOUS_LOADED" == true && -f "$OLD_PLIST" ]]; then
    launchctl bootstrap "$DOMAIN" "$OLD_PLIST" || true
  fi
  exit 1
fi
SWITCH_STARTED=true

open "$APP_DEST"
new_pid=""
for _ in {1..10}; do
  candidate="$(app_pids | head -n 1)"
  if [[ -n "$candidate" ]]; then
    command_line="$(ps -p "$candidate" -o command= | sed 's/^[[:space:]]*//')"
    current_version="$(plutil -extract CFBundleVersion raw -o - "$APP_DEST/Contents/Info.plist")"
    if [[ "$command_line" == "$APP_EXEC" && "$current_version" == "$EXPECTED_VERSION" ]]; then
      new_pid="$candidate"
      break
    fi
  fi
  sleep 0.5
done
if [[ -z "$new_pid" ]]; then
  echo "App 未能启动或版本校验失败，请检查系统日志。" >&2
  exit 1
fi

rm -f "$OLD_PLIST"
while IFS= read -r app; do rm -rf "$app"; done < <(legacy_apps)
SWITCH_STARTED=false
echo "安装完成（PID ${new_pid}，版本 ${EXPECTED_VERSION}）。App 已启动，网络事件会触发自动登录。"
echo "配置：打开菜单栏的“Csust-Network-Automation” → 设置…"
echo "卸载：bash install.sh uninstall（配置与日志保留）"
