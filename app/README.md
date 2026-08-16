# dsh-remote Flutter App

手机端 Flutter App，通过 `dsh-remote-bridge` 远程控制本机 DSH。

## 功能

- 扫码绑定：扫电脑配对二维码，自动获取设备专属 token（原生端存 Keychain/Keystore）
- 多电脑支持：保存所有配对过的电脑，扫新电脑自动追加；「电脑列表」可切换、单独忘记
- 自动连接：下次打开直接连回上次选中的电脑
- 查看 DSH 会话列表
- 新建会话
- 向指定会话发送指令
- 通过 WebSocket 实时查看 DSH 执行过程 / 流式输出
- 支持在手机上批准 DSH 的审批请求、回答 DSH 的提问
- 手动配置（高级）：仍可手填桥接地址和 Token
- Web 版兜底：系统相机扫二维码直接打开 `/app/` 并自动配对

## 运行

需要先安装 Flutter SDK，然后：

```bash
cd app
# 如果还没有 android/ ios/ 等平台目录，先生成：
flutter create . --platforms=android,ios
flutter pub get
flutter run
```

真机调试时，手机和 Mac 需要能访问到桥接服务地址（例如 `http://<your-mac-ip>:8787`）。

## 打包 Android APK

需要 JDK 17 和 Android SDK。当前项目已生成 `android/` 工程，直接执行：

```bash
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
# 静态检查
flutter analyze

# Widget 测试
flutter test

# 编译 Web 版本（不需要 Android/iOS 工具链，可用来快速验证代码可编译）
flutter create . --platforms=web
flutter build web --release

# 端到端联调（需要 bridge 已启动）
dart run tool/bridge_integration_test.dart
```

## 目录结构

```text
lib/
  main.dart
  screens/
    home_screen.dart      # 连接配置 + 会话列表
    chat_screen.dart      # 会话聊天 / 指令 / 实时输出
  services/
    dsh_api.dart          # REST API 客户端
    dsh_stream.dart       # WebSocket 实时事件流客户端
tool/
  bridge_integration_test.dart  # 端到端联调脚本
```

## 安全

- Token 只保存在 App 本地，不要写死在代码里。
- 公网使用时建议用 Cloudflare Tunnel / ngrok / frp 套 HTTPS。
