# dsh-remote-bridge

手机远程控制本机 DSH 的本地桥接服务。

## 为什么需要它

DSH 默认只监听 `127.0.0.1:3080`，并且官方禁止 `--host 0.0.0.0`，防止直接把可执行命令的 API 暴露到网络。  
这个桥接服务运行在 Mac 上，负责：

1. 监听手机可以访问的地址（默认 `0.0.0.0:8787`）
2. 用 Token 做鉴权
3. 把 `/api/*` 转发到本机 DSH `127.0.0.1:3080`
4. 把 DSH 的实时事件流 `/api/events.mux` 转成 WebSocket 给手机 App

## 快速开始

```bash
cd bridge
npm install
cp config.example.json config.json
# 修改 config.json 里的 token，建议用：
# openssl rand -hex 32
npm start
```

环境变量也可以覆盖配置：

```bash
BRIDGE_TOKEN=xxx BRIDGE_PORT=8787 npm start
```

可选配置（`config.json`）：

```json
{
  "allowedIps": ["192.168.1.0/24", "100.64.0.0/10"],
  "trustProxy": true,
  "rateLimit": {
    "windowMs": 60000,
    "max": 120
  }
}
```

- `allowedIps`：留空表示允许所有 IP；填写后只允许这些 IP 访问（支持 IPv4 CIDR）。
- `trustProxy`：如果 bridge 前面有反代/隧道，开启后会读取 `X-Forwarded-For` 作为客户端 IP。
- `rateLimit`：简单限流，默认每分钟 120 次请求。

## 验证

```bash
# 健康检查
curl http://127.0.0.1:8787/health

# 调用 DSH API（需要 token）
curl -X POST http://127.0.0.1:8787/api/session.list \
  -H "Authorization: Bearer <TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{"type":"client-request","rpcId":"1","method":"session.list","payload":{}}'

# WebSocket 实时流（可用 wscat 测试）
wscat -c "ws://127.0.0.1:8787/ws/events.mux?token=<TOKEN>"
```

## 安全提醒

- 不要直接把 DSH 的 `3080` 端口映射到公网。
- 公网访问时，桥接服务前面必须再加一层 HTTPS（Cloudflare Tunnel / ngrok / frp + TLS）。
- Token 要够长、够随机；建议开启 IP 白名单和限流。
