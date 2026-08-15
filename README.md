# DSH-Remote

手机远程控制本机 DeepSeek Harness (DSH) 的项目。  
本项目基于 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 构建，是 DSH 专用远程控制客户端。

> 这是一个脱敏后的公开版本，不包含任何个人 Token、IP、设备信息或本地绝对路径。

## 项目简介

DSH 默认只监听 `127.0.0.1:3080`，并且官方禁止直接 `--host 0.0.0.0`。  
本项目提供两层能力：

1. **dsh-remote 插件**：一条命令装进 DSH，DSH 页面右下角出现「手机遥控」按钮，点开即生成配对二维码、桌面确认、设备列表和吊销管理。
2. **带鉴权的 bridge**：插件自动托管（或独立运行）的桥接服务，默认拒绝式 API 白名单 + 每台手机独立设备 token。

手机侧不用再手填地址和 Token：**扫码 → 电脑点允许 → 完成**。没装 App 也可以直接用系统相机扫二维码打开手机网页版。

## 架构

```text
DSH Web 页面
  └─ dsh-remote 插件「手机遥控」按钮（二维码 / 桌面确认 / 设备吊销）
       ↓ loopback
bridge (0.0.0.0:8787)
  ├─ 手机 Flutter App  ── 设备专属 Token ──→ /api/*（默认拒绝 + 白名单）
  ├─ 手机浏览器（网页版） ← QR 链接 → /app/
  └─ /pair/* 一次性配对码、设备 token 注册表
       ↓ 转发
DSH (127.0.0.1:3080，只监听 loopback，绝不外露)
```

手机扫码后：配对码 → 桌面确认 → 签发该设备专属 token → 自动连接。二维码只含 3 分钟有效的一次性配对码，永不含永久 token。

## 与 Agents Anywhere 的区别

[Agents Anywhere](https://github.com/anywhere-labs/Agents-Anywhere) 是一个多 Agent 远程控制平台，目标是统一控制 Codex、Claude Code 等编程 Agent，并提供文件浏览、远程终端、多设备配对等能力。

本项目定位不同：

| 维度 | DSH-Remote | Agents Anywhere |
|---|---|---|
| 控制对象 | 只控制 DeepSeek Harness (DSH) | Codex、Claude Code 等多个 Agent |
| 定位 | DSH 专用轻量手机遥控器 | 多 Agent、多设备通用控制平台 |
| 架构 | DSH 插件 + 本地 Node bridge + Flutter App | FastAPI 后端 + Connector + Web/Android |
| 文件/终端 | 暂不支持 | 支持远程文件、shell、终端 |
| 多设备 | 本机 + 多台已配对手机 | 支持多台设备接入 |
| 适合场景 | 个人远程控制自己的 DSH | 多 Agent、团队/自托管场景 |

简单说：**DSH-Remote 是为 DSH 量身定做的专用遥控器；Agents Anywhere 是面向多种 Agent 的通用平台。**

## 目录结构

| 路径 | 说明 |
|---|---|
| `bridge/` | Node.js 桥接服务（可独立运行，也是插件的托管对象） |
| `app/` | Flutter 手机 App（原生 + Web 双端） |
| `index.js` / `client.js` / `cordis.patch.yml` / `package.json` | dsh-remote 插件本体 |
| `docs/` | 公网访问方案 |
| `start_dsh_remote.sh` | 一键启动 DSH + bridge（独立运行模式） |

## 快速开始

### 方式 A：DSH 插件（推荐）

先发布/本地安装插件：

```bash
# 发布到 npm 后：
npx -y --package @deepseek-ai/dsh dsh plugin --profile web add dsh-remote

# 本地开发包：
npx -y --package @deepseek-ai/dsh dsh plugin --profile web add /path/to/dsh-remote-public
```

重启 `dsh web` 并硬刷新，DSH 页面右下角出现「📱 手机遥控」按钮。插件会自动托管 bridge（检测到已有健康 bridge 就复用）。

### 方式 B：独立 bridge

```bash
cd bridge
npm install
cp config.example.json config.json
# 修改 config.json 里的 token，建议用：
# openssl rand -hex 32
npm start
```

### 手机扫码绑定

电脑端（插件面板或独立配对页 `http://127.0.0.1:8787/pair/qr`）生成二维码：

- **没装 App**：手机系统相机直接扫码 → 打开网页版 `http://<电脑IP>:8787/app/` → 自动配对连接。
- **装了 App**：打开 DSH-Remote App 点「扫码绑定设备」扫同一张码 → 自动保存设备专属 token 并连接。

网页版需要先构建一次：

```bash
cd app
flutter build web --release --base-href /app/
```

扫码后在电脑端点「允许」，之后**不需要手填任何地址或 Token**。

### 运行 Flutter App

```bash
cd app
flutter pub get
flutter run
```

## 手机 App 功能

- 扫码绑定：自动获取设备专属 token（原生端存 Keychain/Keystore）
- 自动连接：下次打开直接连回已绑定设备，可一键忘记
- 查看 DSH 会话列表、新建会话、发送指令
- 实时查看 DSH 执行过程 / 流式输出
- 手机上批准 DSH 审批请求、回答 DSH 提问
- 手动配置（高级）：仍可手填桥接地址和 Token
- Web 版兜底：系统相机扫码直接打开并自动配对

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

Release 标签（`v*`）会通过 GitHub Actions 自动构建 APK 并附到 Release；npm 发布任务带私密路径守卫，只允许在脱敏仓库执行。

> 当前 release 包使用 debug 签名，方便安装测试；上架应用商店前需要换成正式签名。

## 验证

```bash
# bridge 健康检查
curl http://127.0.0.1:8787/health

# 配对全流程回归测试（自动起隔离实例）
cd bridge
bash test_pairing.sh

# Flutter 静态检查与测试
cd ../app
flutter analyze
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
- 二维码只携带一次性配对码（3 分钟有效、单次使用），永远不携带永久 token；默认需电脑端点「允许」。
- 每台手机签发独立设备 token，散列存储，可在配对页单独吊销。
- bridge 对 DSH 方法默认拒绝，只放行 `session.*` 与 `respond`。
- 开启 bridge 的 IP 白名单和限流。
- `bridge/config.json` 和 `bridge/devices.json` 已加入 `.gitignore`，不要提交真实 Token 或设备表。
