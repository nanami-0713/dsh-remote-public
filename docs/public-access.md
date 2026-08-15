# 公网访问方案

> 目标：手机在外面也能访问 Mac 上的 `dsh-remote-bridge`。
> 原则：**永远不要把 DSH 的 3080 直接暴露到公网**。只暴露带 Token 鉴权的 bridge（8787），并且要套 HTTPS。

## 方式一：Cloudflare Tunnel（推荐）

1. 安装 `cloudflared`：

```bash
brew install cloudflared
```

2. 登录并创建隧道：

```bash
cloudflared tunnel login
cloudflared tunnel create dsh-remote
```

3. 写配置文件 `~/.cloudflared/config.yml`：

```yaml
tunnel: dsh-remote
credentials-file: ~/.cloudflared/<TUNNEL_ID>.json

ingress:
  - hostname: dsh.example.com
    service: http://127.0.0.1:8787
  - service: http_status:404
```

4. 配置 DNS：

```bash
cloudflared tunnel route dns dsh-remote dsh.example.com
```

5. 启动：

```bash
cloudflared tunnel run dsh-remote
```

6. 手机 App 里填：

```text
服务器地址: https://dsh.example.com
Token: bridge config.json 里的 token
```

Cloudflare Tunnel 会自动提供 HTTPS。

## 方式二：ngrok

```bash
brew install ngrok
ngrok http 8787
```

把 ngrok 给你的 `https://xxxx.ngrok-free.app` 填到 App 里即可。  
免费版域名会变，建议用固定域名（需付费）。

## 方式三：frp

适合你有自己的云服务器时。

在云服务器上运行 frps：

```ini
# frps.toml
bindPort = 7000
```

在 Mac 上运行 frpc：

```ini
# frpc.toml
serverAddr = "your-server-ip"
serverPort = 7000

[[proxies]]
name = "dsh-remote"
type = "tcp"
localIP = "127.0.0.1"
localPort = 8787
remotePort = 8787
```

然后用 Nginx/Caddy 在云服务器上给 `8787` 套 HTTPS 并反代到 frps 的 `8787`。

## 方式四：Tailscale（推荐给私人使用）

如果只是你自己几台设备用，Tailscale 是最省心的：

```bash
brew install tailscale
tailscale up
```

手机装 Tailscale App 并登录同一个账号后，直接用 Mac 的 Tailscale IP 访问：

```text
服务器地址: http://100.x.x.x:8787
```

Tailscale 自带加密，不需要额外 HTTPS。

## 安全清单

- [ ] Token 长度至少 32 字节随机值
- [ ] 公网必须 HTTPS
- [ ] 不要开放 DSH 3080
- [ ] 开启 bridge 的 `allowedIps` 和 `rateLimit`
- [ ] 定期更换 Token
