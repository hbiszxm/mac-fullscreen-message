#!/bin/bash
set -euo pipefail

REPO="hbiszxm/mac-fullscreen-message"
PKG_NAME="FullscreenMessage-AppleSilicon-v3.4.pkg"
DOWNLOAD_URL="https://github.com/$REPO/releases/latest/download/$PKG_NAME"
WORK_DIR="$(mktemp -d /private/tmp/fullscreen-message-install.XXXXXX)"
PKG_PATH="$WORK_DIR/$PKG_NAME"
trap 'rm -rf "$WORK_DIR"' EXIT

if [ "$(uname -m)" != "arm64" ]; then
  echo "此安装包只支持 Apple M 芯片 Mac。" >&2
  exit 1
fi

echo "正在下载全屏消息最新版…"
curl --fail --location --progress-bar "$DOWNLOAD_URL" --output "$PKG_PATH"
echo "正在安装，需要输入当前 Mac 的登录密码…"
sudo /usr/sbin/installer -pkg "$PKG_PATH" -target /
echo "安装或升级完成。"
