import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

class DshStream {
  final String baseUrl;
  final String token;
  WebSocketChannel? _channel;
  StreamSubscription? _sub;

  DshStream({required this.baseUrl, required this.token});

  String get _wsUrl {
    final wsBase = baseUrl.replaceFirst('http://', 'ws://').replaceFirst('https://', 'wss://');
    return '$wsBase/ws/events.mux?token=${Uri.encodeQueryComponent(token)}';
  }

  /// Start listening. [onFrame] receives each parsed JSON frame from the bridge.
  void connect(void Function(Map<String, dynamic> frame) onFrame) {
    disconnect();
    _channel = WebSocketChannel.connect(Uri.parse(_wsUrl));
    _sub = _channel!.stream.listen(
      (data) {
        try {
          final decoded = jsonDecode(data as String) as Map<String, dynamic>;
          onFrame(decoded);
        } catch (_) {}
      },
      onError: (Object e) {
        // Stream errors are handled by the UI through connection state if needed.
      },
      onDone: () {},
      cancelOnError: true,
    );
  }

  void disconnect() {
    _sub?.cancel();
    _sub = null;
    _channel?.sink.close();
    _channel = null;
  }
}
