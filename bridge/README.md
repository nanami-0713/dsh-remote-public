# dsh-remote-bridge

手机远程控制本机 DSH 的本地桥接服务。

## 为什么需要它

DSH 默认只监听 `127.0.0.1:3080`，并且官方禁止 `--host 0.0.0.0`，防止直接把可执行命令的 API 暴露到网络。  
这个桥接服务运行在 Mac 上，负责：

1. 监听手机可以访问的地址（默认 `0.0.0.0:8787`）
2. 用 Token 做鉴权（支持主 token + 每台手机独立的设备 token）
3. 把允许清单内的 `/api/*` 转发到本机 DSH `127.0.0.1:3080`
4. 把 DSH 的实时事件流 `/api/events.mux` 转成 WebSocket 给手机 App
5. 用一次性配对码 + 桌面确认完成手机扫码绑定

## 多设备支持

- **一台手机控制多台电脑**：在每台电脑上各运行一个 bridge（各自代理各自的 DSH），手机 App 会保存所有配对过的电脑；扫新电脑的二维码只会追加，不会覆盖旧电脑。
- **一台电脑配多台手机**：`devices.json` 为每台手机签发独立设备 token，配对页可分别允许、查看最近活跃和吊销。

## 快速开始

```bash
cd bridge
npm install
cp config.example.json config.json
# 修改 config.json 里的 token，建议用：
# openssl rand -hex 32
npm start
```

然后在本机浏览器打开配对页：

```text
http://127.0.0.1:8787/pair/qr
```

页面会生成二维码。默认二维码是 `dshremote://` 链接，以 App 为第一入口：

- **已装 App（推荐）**：打开 DSH-Remote App 点「扫码绑定设备」扫二维码。
- **未装 App**：配对页点「复制网页版链接」，在手机浏览器打开 `http://<电脑IP>:8787/app/?code=...`，同样自动配对。

扫码后 App/网页会发起配对，你在电脑页面点「允许」，之后手机保存的是**这台设备专属的 token**。二维码里只有一次性配对码（3 分钟有效、单次使用），永远不含永久 token。

手机网页版需要先构建：

```bash
cd ../app
flutter build web --release --base-href /app/
```

bridge 会自动探测 `app/build/web` 并托管在 `http://<电脑IP>:8787/app/`；也可以用 `webRoot` 配置指定其他目录。

环境变量也可以覆盖配置：

```bash
BRIDGE_TOKEN=xxx BRIDGE_PORT=8787 npm start
```

可选配置（`config.json`）：

```json
{
  "allowedIps": ["192.168.1.0/24", "100.64.0.0/10"],
  "trustProxy": true,
  "pairTtlMs": 180000,
  "pairPendingTtlMs": 600000,
  "pairRequireApproval": true,
  "devicesFile": "devices.json",
  "bridgeName": "My-Mac",
  "webRoot": "",
  "rateLimit": {
    "windowMs": 60000,
    "max": 120
  }
}
```

- `allowedIps`：留空表示允许所有 IP；填写后只允许这些 IP 访问（支持 IPv4 CIDR）。
- `trustProxy`：如果 bridge 前面有反代/隧道，开启后会读取 `X-Forwarded-For` 作为客户端 IP。
- `pairTtlMs`：配对二维码有效期，默认 3 分钟。
- `pairPendingTtlMs`：手机发起配对后等待确认的窗口，默认 10 分钟。
- `pairRequireApproval`：是否要求电脑端点击「允许」，安全起见默认开启。
- `devicesFile`：设备 token 注册表文件，只保存 sha256 散列，不保存明文。
- `bridgeName`：这台电脑显示在手机 App「电脑列表」里的名字；留空时自动使用系统主机名。
- `webRoot`：手机网页版静态目录；留空时自动探测 `webapp/` 或 `../app/build/web`。
- `rateLimit`：简单限流，默认每分钟 120 次请求。

## 验证

```bash
# 健康检查
curl http://127.0.0.1:8787/health

# 配对回归测试（自动起一个隔离实例走完整配对流程）
bash test_pairing.sh

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
- 配对二维码只携带一次性配对码，**永远不携带永久 token**；配对码单次有效、默认 3 分钟过期，默认还需电脑端点「允许」。
- API 采用默认拒绝策略，只放行手机 App 需要的 `session.list/create/models/selectModel/prompt/cancel/history`、`agentPreset.list`、`llm.models`、`workspace.list`（只读，用于选择工作文件夹）与 `respond` 方法；`credentials.*`、`settings.*`、`host.*` 等一律 403。
- 设备 token 可单独吊销（配对页设备列表），吊销立即生效。
