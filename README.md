# 全屏消息 for Mac

适用于 Apple M 芯片 Mac 的菜单栏局域网消息工具。同一局域网内的 Mac 会自动发现彼此，无需账号和配对；任意一方发送消息后，接收方的全部显示器会同时全屏显示。

## 功能

- Dock 栏不显示图标，只在顶部菜单栏后台运行。
- 默认快捷消息：上班、吸烟、暗棋。
- 支持保存和删除自定义快捷消息。
- 发送端收到对方确认后才显示成功，失败自动重试三次。
- 接收方全部显示器同时全屏显示，按 ESC 一次关闭所有屏幕。
- 首页集中提供消息发送、快捷列表、开机启动、在线更新和运行状态。
- 支持应用内在线更新。

## 命令行安装

打开“终端”，执行：

```bash
curl -fsSL "https://github.com/hbiszxm/mac-fullscreen-message/releases/latest/download/install-latest.sh?cache=$(date +%s)" | /bin/bash
```

根据提示输入当前 Mac 的登录密码。脚本会下载最新版、覆盖旧版本并自动启动。

## 网页下载安装

1. 打开 [最新版本下载页面](https://github.com/hbiszxm/mac-fullscreen-message/releases/latest)。
2. 下载 `FullscreenMessage-AppleSilicon.pkg`。
3. 双击安装包并按提示安装。
4. 首次运行时允许访问“本地网络”。

只支持 Apple M 芯片 Mac，最低系统版本为 macOS 13。

## 打开首页

点击屏幕顶部菜单栏中的“上班”，选择“显示首页”。首页包含：

- 本机名称和在线电脑
- 自定义消息发送
- 接收电脑可选择单台或所有在线电脑
- 添加快捷消息
- 开机自动运行
- 检查在线更新
- 当前运行状态

## 在线更新

在顶部“上班”菜单或应用首页点击“检查在线更新”。程序会自动检查 GitHub 最新版本、下载安装包并打开 macOS 安装器。

## 命令行更新

更新和首次安装使用同一条命令：

```bash
curl -fsSL "https://github.com/hbiszxm/mac-fullscreen-message/releases/latest/download/install-latest.sh?cache=$(date +%s)" | /bin/bash
```

## 命令行卸载

执行：

```bash
curl -fsSL "https://github.com/hbiszxm/mac-fullscreen-message/releases/latest/download/uninstall.sh?cache=$(date +%s)" | /bin/bash
```

卸载脚本会清理后台进程、开机启动、应用文件和本地设置。

## 手动卸载

1. 点击顶部“上班”菜单，选择“退出全屏消息”。
2. 在“应用程序”文件夹删除“全屏消息.app”。
3. 如已启用开机启动，在“系统设置 → 通用 → 登录项与扩展”中将其关闭。

## 从源码构建

需要 Xcode 命令行开发环境：

```bash
./scripts/build.sh
```

构建产物位于 `build/`：

- `全屏消息.app`
- `全屏消息-Apple芯片-v3.5.5.pkg`
