import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'bridge_notify.dart';

/// Cross-window phone alerts (native only).
///
/// On Android/iOS this posts real system notifications (high-importance
/// heads-up banner / lock screen / notification shade), which stay visible
/// above whatever app the user is looking at — the phone-side equivalent of
/// the PC's floating panel. Web has no system notification surface, so it is
/// unsupported there and the app falls back to the in-app banner.
class PhoneNotifier {
  PhoneNotifier._();

  static final PhoneNotifier instance = PhoneNotifier._();

  static const _channelId = 'dsh_remote_alerts';
  static const _channelName = 'DSH 远程提醒';

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  /// sessionId of notifications the user tapped; main.dart navigates on these.
  final StreamController<String> _openRequests = StreamController<String>.broadcast();

  Stream<String> get openRequests => _openRequests.stream;

  bool _initialized = false;
  int _nextId = 1;

  /// Real system notifications only exist on Android/iOS; web and test hosts
  /// fall back to the in-app banner.
  bool get supported {
    if (kIsWeb) return false;
    try {
      return Platform.isAndroid || Platform.isIOS;
    } catch (_) {
      return false;
    }
  }

  Future<void> ensureInitialized() async {
    if (_initialized || !supported) return;
    _initialized = true;
    try {
      const android = AndroidInitializationSettings('@mipmap/ic_launcher');
      const darwin = DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      );
      await _plugin.initialize(
        settings: const InitializationSettings(android: android, iOS: darwin),
        onDidReceiveNotificationResponse: _onTap,
      );
    } catch (_) {
      // 插件初始化失败就退回应用内横幅。
      _initialized = false;
    }
  }

  /// Ask for Android 13+ POST_NOTIFICATIONS / iOS alert permission.
  Future<bool> requestPermission() async {
    if (!supported) return false;
    await ensureInitialized();
    if (!_initialized) return false;
    try {
      if (Platform.isAndroid) {
        return await _plugin
                .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
                ?.requestNotificationsPermission() ??
            false;
      }
      return await _plugin
              .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
              ?.requestPermissions(alert: true, badge: true, sound: true) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Post a heads-up system notification for [notify].
  Future<void> show(BridgeNotify notify) async {
    if (!supported) return;
    await ensureInitialized();
    if (!_initialized) return;
    try {
      final payload = jsonEncode({'sessionId': notify.sessionId});
      await _plugin.show(
        id: _nextId++,
        title: notify.title,
        body: notify.message.isEmpty ? 'DSH Remote' : notify.message,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            channelDescription: 'PC DSH 弹窗提醒的跨窗口副本',
            importance: Importance.max,
            priority: Priority.high,
            category: AndroidNotificationCategory.status,
            playSound: true,
            enableVibration: true,
          ),
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentBanner: true,
            presentSound: true,
            interruptionLevel: InterruptionLevel.active,
          ),
        ),
        payload: payload,
      );
    } catch (_) {
      // 通知失败不影响 App 本身。
    }
  }

  void _onTap(NotificationResponse response) {
    final payload = response.payload;
    if (payload == null || payload.isEmpty) return;
    try {
      final decoded = jsonDecode(payload);
      final sessionId = (decoded as Map<String, dynamic>)['sessionId'] as String?;
      if (sessionId != null && sessionId.isNotEmpty) {
        _openRequests.add(sessionId);
      }
    } catch (_) {
      // 旧版本 payload 不是 JSON 时忽略。
    }
  }
}
