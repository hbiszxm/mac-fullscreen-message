# 全屏信息云端转发服务

测试服务器：`18.0.2.83:18443`（TLS）。`57983` 是 SSH 管理端口，不是客户端端口。

部署目录：`/root/zxm-xiangm/全屏信息服务/`。Python 3.6 及以上，无第三方依赖，systemd 开机启动并在异常退出后重启。

## 默认互联

客户端自动连接服务器，没有账号、加入码或人工配对。所有连接该服务器的新版客户端在同一个在线列表中。设备首次连接时自动注册随机身份凭据，以后的连接校验该凭据；同一身份的新连接会替换旧连接。它用于避免冒用已有设备，不限制新设备自动加入。

客户端固定校验服务器证书 SHA-256，TLS 最低为 1.2。服务端持有证书私钥，客户端与仓库只包含证书指纹。更换证书时需要同步更新客户端指纹。

## 目录

- `relay.py`：在线状态、转发及确认处理。
- `fullscreen-message-relay.service`：服务定义。
- `private/config.json`：监听地址、证书和身份注册表路径。
- `private/server.crt` / `private/server.key`：服务证书和私钥。
- `private/devices.json`：设备凭据摘要（不包含明文凭据）。

`private/` 不提交到 Git。服务不保存聊天/全屏消息正文，也不记录正文日志。它只能转发给当前在线设备；离线发送立即失败。接收客户端处理并持久化待查看消息后发 ACK，服务端才向发送端报告送达；10 秒未确认则失败。收到/拒绝属于独立回执，通过相同路径转发。

## 管理命令

```bash
systemctl status fullscreen-message-relay
systemctl restart fullscreen-message-relay
journalctl -u fullscreen-message-relay -n 50 --no-pager
ss -lntp | grep 18443
```

客户端每 10 秒发送心跳，服务端 35 秒收不到任何数据就断开并广播离线。TCP 正常断开时立即更新。客户端使用 1～30 秒退避重连，重新上线后恢复发现。云端和局域网中的同一设备按稳定身份合并，优先使用云端；云端不可用时，同一局域网可以本地发送。

## 从头部署

将 `relay.py` 和 service 文件复制到部署目录，创建权限为 700 的 `private` 子目录。生成专用 TLS 证书，并把 DER 证书 SHA-256 配置到客户端 `CloudRelay.certificateSHA256`。

`private/config.json` 示例：

```json
{"host":"0.0.0.0","port":18443,"key":"private/server.key","cert":"private/server.crt","registry":"private/devices.json"}
```

将 service 文件放入 `/etc/systemd/system/`，执行 `systemctl daemon-reload` 和 `systemctl enable --now fullscreen-message-relay`，只开放 TCP 18443。SSH 密码和 TLS 私钥都不进入源码或安装包。

## 验证

`Tests/CloudRelayLive` 使用真实测试服务器验证发现、消息、收到/拒绝回执、连续发送、离线、重连、无 ACK 超时、身份和证书校验。

`Tests/CloudMessengerLive` 禁用 Bonjour，在生产收发入口验证云端发现、重复消息去重、回执、移除后重新上线以及心跳。测试只发送到自建的临时测试身份，不给真实用户发送消息。
