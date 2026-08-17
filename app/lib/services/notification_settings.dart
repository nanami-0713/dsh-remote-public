import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Phone-side notification preferences (independent from the PC notifier
/// switches): whether to show phone alerts at all, which kinds, and whether
/// to use cross-window system notifications on native platforms.
@immutable
class NotificationSettings {
  const NotificationSettings({
    required this.enabled,
    required this.done,
    required this.question,
    required this.systemAlerts,
  });

  /// 总开关：接收 PC 推来的手机提醒。
  final bool enabled;

  /// 任务完成提醒。
  final bool done;

  /// 需要你回答提醒。
  final bool question;

  /// 跨窗口系统通知（Android heads-up / iOS 横幅）；网页版自动退回应用内横幅。
  final bool systemAlerts;

  static const defaults = NotificationSettings(
    enabled: true,
    done: true,
    question: true,
    systemAlerts: true,
  );

  bool kindEnabled(String kind) {
    if (!enabled) return false;
    if (kind == 'done') return done;
    if (kind == 'question') return question;
    return false;
  }

  NotificationSettings copyWith({
    bool? enabled,
    bool? done,
    bool? question,
    bool? systemAlerts,
  }) {
    return NotificationSettings(
      enabled: enabled ?? this.enabled,
      done: done ?? this.done,
      question: question ?? this.question,
      systemAlerts: systemAlerts ?? this.systemAlerts,
    );
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'done': done,
        'question': question,
        'systemAlerts': systemAlerts,
      };

  static NotificationSettings fromJson(Map<String, dynamic> json) {
    bool b(String key, bool fallback) {
      final value = json[key];
      return value is bool ? value : fallback;
    }

    return NotificationSettings(
      enabled: b('enabled', defaults.enabled),
      done: b('done', defaults.done),
      question: b('question', defaults.question),
      systemAlerts: b('systemAlerts', defaults.systemAlerts),
    );
  }
}

/// Persists [NotificationSettings] in SharedPreferences and exposes a
/// [ValueNotifier] so the UI and the notification dispatcher stay in sync.
class NotificationSettingsStore {
  NotificationSettingsStore._();

  static final NotificationSettingsStore instance = NotificationSettingsStore._();

  static const _prefsKey = 'notification_settings_v1';

  final ValueNotifier<NotificationSettings> notifier =
      ValueNotifier(NotificationSettings.defaults);

  bool _loaded = false;

  NotificationSettings get current => notifier.value;

  Future<NotificationSettings> load() async {
    if (_loaded) return current;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw != null) {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          notifier.value = NotificationSettings.fromJson(decoded);
        }
      }
    } catch (_) {
      // 解析失败就用默认值。
    }
    _loaded = true;
    return current;
  }

  Future<void> save(NotificationSettings settings) async {
    notifier.value = settings;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, jsonEncode(settings.toJson()));
    } catch (_) {
      // 保存失败不影响本次会话内的开关状态。
    }
  }
}
