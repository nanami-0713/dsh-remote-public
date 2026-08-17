import 'dart:async';

import 'package:flutter/material.dart';

import 'screens/chat_screen.dart';
import 'screens/demo_chat_screen.dart';
import 'screens/home_screen.dart';
import 'services/bridge_notify.dart';
import 'services/dsh_api.dart';
import 'services/notification_settings.dart';
import 'services/phone_notifier.dart';

const kDshBlue = Color(0xFF4D6BFE);
const kBackground = Color(0xFFF9FAFB);
const kSurface = Color(0xFFFFFFFF);
const kBorder = Color(0xFFE5E7EB);
const kTextPrimary = Color(0xFF111827);
const kTextSecondary = Color(0xFF6B7280);

void main() {
  runApp(const DshRemoteApp());
}

class DshRemoteApp extends StatefulWidget {
  const DshRemoteApp({super.key});

  @override
  State<DshRemoteApp> createState() => _DshRemoteAppState();
}

class _DshRemoteAppState extends State<DshRemoteApp> {
  final _navigatorKey = GlobalKey<NavigatorState>();
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();
  StreamSubscription<BridgeNotify>? _notifySub;
  StreamSubscription<String>? _openSub;
  Timer? _bannerTimer;

  @override
  void initState() {
    super.initState();
    _notifySub = BridgeNotifyService.instance.stream.listen(_onBridgeNotify);
    _openSub = PhoneNotifier.instance.openRequests.listen(_openSessionById);
    NotificationSettingsStore.instance.load();
    PhoneNotifier.instance.ensureInitialized();
  }

  @override
  void dispose() {
    _notifySub?.cancel();
    _openSub?.cancel();
    _bannerTimer?.cancel();
    super.dispose();
  }

  /// PC popup copy arrives: honor the phone-side switches. On native with
  /// cross-window alerts enabled, post a real system notification (heads-up
  /// over other apps); otherwise fall back to the in-app top banner.
  void _onBridgeNotify(BridgeNotify notify) {
    final settings = NotificationSettingsStore.instance.current;
    if (!settings.kindEnabled(notify.kind)) return;
    if (PhoneNotifier.instance.supported && settings.systemAlerts) {
      PhoneNotifier.instance.show(notify);
      return;
    }
    _showBanner(notify);
  }

  void _showBanner(BridgeNotify notify) {
    final messenger = _messengerKey.currentState;
    if (messenger == null) return;
    _bannerTimer?.cancel();
    messenger.clearMaterialBanners();
    messenger.showMaterialBanner(
      MaterialBanner(
        leading: Icon(
          notify.kind == 'done' ? Icons.check_circle : Icons.help_outline,
          color: notify.kind == 'done' ? Colors.green : kDshBlue,
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              notify.title,
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
            ),
            if (notify.message.isNotEmpty)
              Text(
                notify.message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: kTextSecondary),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              messenger.hideCurrentMaterialBanner();
              _openSessionById(notify.sessionId);
            },
            child: const Text('查看'),
          ),
          TextButton(
            onPressed: () => messenger.hideCurrentMaterialBanner(),
            child: const Text('忽略'),
          ),
        ],
      ),
    );
    if (!notify.isSticky) {
      _bannerTimer = Timer(const Duration(seconds: 8), () {
        messenger.hideCurrentMaterialBanner();
      });
    }
  }

  /// Jump into the session that triggered the notification (in-app banner or
  /// system notification tap).
  void _openSessionById(String sessionId) {
    final baseUrl = BridgeNotifyService.instance.baseUrl;
    final token = BridgeNotifyService.instance.token;
    if (baseUrl == null || token == null || sessionId.isEmpty) return;
    final navigator = _navigatorKey.currentState;
    if (navigator == null) return;
    navigator.push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          api: DshApi(baseUrl: baseUrl, token: token),
          baseUrl: baseUrl,
          token: token,
          sessionId: sessionId,
          title: '会话 ${sessionId.length > 12 ? sessionId.substring(0, 12) : sessionId}',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: kDshBlue,
      primary: kDshBlue,
      surface: kSurface,
    );
    final isDemoChat = Uri.base.queryParameters['demo'] == 'chat';
    return MaterialApp(
      title: 'DSH Remote',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigatorKey,
      scaffoldMessengerKey: _messengerKey,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: colorScheme,
        scaffoldBackgroundColor: kBackground,
        appBarTheme: const AppBarTheme(
          backgroundColor: kSurface,
          foregroundColor: kTextPrimary,
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: false,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFFF3F4F6),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: kBorder),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: kDshBlue, width: 1.5),
          ),
        ),
        cardTheme: CardThemeData(
          color: kSurface,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: kBorder),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: kDshBlue,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
      ),
      home: isDemoChat ? const DemoChatScreen() : const HomeScreen(),
    );
  }
}
