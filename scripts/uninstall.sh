#!/bin/bash
set -euo pipefail

APP_PATH="/Applications/全屏消息.app"
BUNDLE_ID="cn.local.fullscreen-message"
CONSOLE_USER="$(stat -f '%Su' /dev/console)"

echo "正在卸载全屏消息…"

if [ -x "$APP_PATH/Contents/MacOS/FullscreenMessage" ]; then
  if [ -n "$CONSOLE_USER" ] && [ "$CONSOLE_USER" != "root" ]; then
    USER_ID="$(id -u "$CONSOLE_USER")"
    launchctl asuser "$USER_ID" sudo -u "$CONSOLE_USER" \
      "$APP_PATH/Contents/MacOS/FullscreenMessage" --unregister-login-item >/dev/null 2>&1 || true
  fi
fi

pkill -x FullscreenMessage 2>/dev/null || true
sleep 1
sudo rm -rf "$APP_PATH"

if [ -n "$CONSOLE_USER" ] && [ "$CONSOLE_USER" != "root" ]; then
  launchctl asuser "$(id -u "$CONSOLE_USER")" sudo -u "$CONSOLE_USER" \
    defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
fi

echo "全屏消息已完全卸载。"

