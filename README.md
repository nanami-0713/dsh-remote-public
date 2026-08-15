# DSH-Remote

手机远程控制本机 DeepSeek Harness (DSH) 的项目。

> 这是一个脱敏后的公开版本，不包含任何个人 Token、IP、设备信息或本地绝对路径。

## 项目简介

DSH 默认只监听 `127.0.0.1:3080`，并且官方禁止直接 `--host 0.0.0.0`。  
本项目通过一个带 Token 鉴权的本地桥接服务，让手机 App 在局域网或公网（Tailscale / Cloudflare Tunnel / ngrok / frp）安全地远程给 DSH 发送指令，并实时查看执行过程。

## 架构

```text
手机 Flutter App
  ↓ HTTPS / Token
Tailscale / Cloudflare Tunnel / 局域网
  ↓
bridge (本机, 0.0.0.0:8787)
  ↓ Token 校验 + 转发
DSH (127.0.0.1:3080)
```

## 目录结构

| 目录 | 说明 |
|---|---|
| `bridge/` | Node.js 本地桥接服务 |
| `app/` | Flutter 手机 App |
| `docs/` | 公网访问方案 |
| `start_dsh_remote.sh` | 一键启动脚本（需按实际路径修改） |

## 快速开始

### 1. 启动 DSH

```bash
dsh web
```

### 2. 启动 bridge

```bash
cd bridge
npm install
cp config.example.json config.json
# 修改 config.json 里的 token，建议用：
# openssl rand -hex 32
npm start
```

### 3. 运行 Flutter App

```bash
cd app
flutter pub get
flutter run
```

### 4. 手机 App 填写

```text
服务器地址: http://<你的 Mac IP 或 Tailscale IP>:8787
Token: 你生成的 token
```

## 手机 App 功能

- 配置桥接服务地址和 Token
- 查看 DSH 会话列表
- 新建会话
- 向指定会话发送指令
- 实时查看 DSH 执行过程 / 流式输出
- 手机上批准 DSH 审批请求、回答 DSH 提问

## 打包 Android APK

需要 JDK 17 和 Android SDK。

```bash
cd app
export JAVA_HOME=/path/to/jdk-17
export ANDROID_HOME=/path/to/android-sdk
flutter build apk --release
```

APK 输出到：

```text
build/app/outputs/flutter-apk/app-release.apk
```

> 当前 release 包使用 debug 签名，方便安装测试；上架应用商店前需要换成正式签名。

## 验证

```bash
# bridge 健康检查
curl http://127.0.0.1:8787/health

# Flutter 静态检查
cd app
flutter analyze

# Flutter 测试
flutter test

# 端到端联调（需要 DSH + bridge 已启动）
dart run tool/bridge_integration_test.dart
```

## 公网访问

详见 [docs/public-access.md](docs/public-access.md)。

## 安全提醒

- DSH API 可以驱动 agent 执行 shell / 文件操作，风险极高。
- 不要把 DSH 的 `3080` 端口直接暴露到公网。
- 公网必须 HTTPS + Token。
- 开启 bridge 的 IP 白名单和限流。
- `bridge/config.json` 已加入 `.gitignore`，不要提交真实 Token。
