import 'package:flutter/services.dart';

/// Bridges the `dshremote://` URL scheme from the Android activity into Dart.
/// Web and platforms without the channel get `null`/no-op behavior.
class DeepLinkService {
  DeepLinkService._();

  static const MethodChannel _channel = MethodChannel('dshremote/deeplink');

  static Future<String?> initialLink() async {
    try {
      return await _channel.invokeMethod<String>('getInitialLink');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  static void listen(void Function(String link) onLink) {
    try {
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'onDeepLink') {
          final link = call.arguments as String?;
          if (link != null && link.isNotEmpty) onLink(link);
        }
      });
    } on MissingPluginException {
      // Web and other platforms without the native channel.
    } on PlatformException {
      // Ignore.
    }
  }
}
