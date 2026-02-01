import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as status;

class GatewayEvent {
  final String type;
  final Object? data;
  GatewayEvent(this.type, this.data);
}

class GatewayClient {
  final String wsUrl;
  final String token;
  final String initialChannelId;

  WebSocketChannel? _ch;
  final _controller = StreamController<GatewayEvent>.broadcast();

  Stream<GatewayEvent> get events => _controller.stream;

  GatewayClient({required this.wsUrl, required this.token, required this.initialChannelId});

  Future<void> connect() async {
    final uri = Uri.parse(wsUrl).replace(queryParameters: {
      'token': token,
      'channelId': initialChannelId,
    });
    _ch = WebSocketChannel.connect(uri);

    _ch!.stream.listen((msg) {
      try {
        final j = jsonDecode(msg as String) as Map<String, dynamic>;
        final t = j['t']?.toString() ?? 'UNKNOWN';
        final d = j['d'];
        _controller.add(GatewayEvent(t, d));
      } catch (_) {}
    }, onDone: () {
      _controller.add(GatewayEvent('DISCONNECTED', null));
    }, onError: (_) {
      _controller.add(GatewayEvent('DISCONNECTED', null));
    });
  }

  void subscribe(String channelId) {
    _ch?.sink.add(jsonEncode({'op': 'SUBSCRIBE', 'd': {'channelId': channelId}}));
  }

  void typing(String channelId) {
    _ch?.sink.add(jsonEncode({'op': 'TYPING', 'd': {'channelId': channelId}}));
  }

  void dispose() {
    _ch?.sink.close(status.goingAway);
    _controller.close();
  }
}
