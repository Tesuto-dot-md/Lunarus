import 'dart:convert';
import 'package:http/http.dart' as http;

class LoginResult {
  final String token;
  final String userId;
  LoginResult({required this.token, required this.userId});
}

class VoiceJoin {
  final String url;
  final String token;
  final String room;
  VoiceJoin({required this.url, required this.token, required this.room});
}

class ChatMessage {
  final String id;
  final String channelId;
  final String authorId;
  final String content;
  final String kind; // text | image | gif
  final Map<String, dynamic>? media;
  final int ts;

  ChatMessage({
    required this.id,
    required this.channelId,
    required this.authorId,
    required this.content,
    required this.kind,
    required this.media,
    required this.ts,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
        id: j['id'].toString(),
        channelId: j['channelId'].toString(),
        authorId: j['authorId'].toString(),
        content: (j['content'] ?? '').toString(),
        kind: (j['kind'] ?? 'text').toString(),
        media: (j['media'] is Map) ? (j['media'] as Map).cast<String, dynamic>() : null,
        ts: (j['ts'] as num).toInt(),
      );
}

class TenorGifItem {
  final String id;
  final String url;
  final String previewUrl;
  TenorGifItem({required this.id, required this.url, required this.previewUrl});

  factory TenorGifItem.fromJson(Map<String, dynamic> j) => TenorGifItem(
        id: j['id'].toString(),
        url: j['url'].toString(),
        previewUrl: (j['previewUrl'] ?? j['url']).toString(),
      );
}

class UploadResult {
  final String url;
  final String mime;
  final int size;
  UploadResult({required this.url, required this.mime, required this.size});
}

class ApiClient {
  final String baseUrl; // http(s)://host[:port]
  ApiClient({required String baseUrl}) : baseUrl = baseUrl.replaceAll(RegExp(r'/+$'), '');

  Uri _u(String p) => Uri.parse('$baseUrl$p');

  // Build ws(s)://.../gateway from baseUrl
  String gatewayWsUrl() {
    final u = Uri.parse(baseUrl);
    final scheme = (u.scheme == 'https') ? 'wss' : 'ws';
    return u.replace(scheme: scheme, path: '/gateway', query: '').toString();
  }

  Future<LoginResult> login({required String username}) async {
    final r = await http.post(
      _u('/auth/login'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({'username': username, 'password': 'demo'}),
    );
    if (r.statusCode != 200) {
      throw Exception('login failed: ${r.statusCode} ${r.body}');
    }
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    final token = j['token'] as String;
    final user = (j['user'] as Map<String, dynamic>);
    return LoginResult(token: token, userId: user['id'].toString());
  }

  Future<List<ChatMessage>> getMessages({required String authToken, required String channelId}) async {
    final r = await http.get(
      _u('/messages?channelId=$channelId'),
      headers: {'authorization': 'Bearer $authToken'},
    );
    if (r.statusCode != 200) throw Exception('getMessages failed: ${r.statusCode} ${r.body}');
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    final items = (j['items'] as List).cast<Map<String, dynamic>>();
    return items.map(ChatMessage.fromJson).toList();
  }

  Future<void> sendMessage({
    required String authToken,
    required String channelId,
    required String content,
    String kind = 'text',
    Map<String, dynamic>? media,
  }) async {
    final r = await http.post(
      _u('/messages'),
      headers: {'content-type': 'application/json', 'authorization': 'Bearer $authToken'},
      body: jsonEncode({'channelId': channelId, 'content': content, 'kind': kind, 'media': media}),
    );
    if (r.statusCode != 200) throw Exception('sendMessage failed: ${r.statusCode} ${r.body}');
  }

  Future<UploadResult> uploadFile({required String authToken, required String filePath}) async {
    final req = http.MultipartRequest('POST', _u('/upload'));
    req.headers['authorization'] = 'Bearer $authToken';
    req.files.add(await http.MultipartFile.fromPath('file', filePath));

    final resp = await req.send();
    final body = await resp.stream.bytesToString();
    if (resp.statusCode != 200) throw Exception('upload failed: ${resp.statusCode} $body');
    final j = jsonDecode(body) as Map<String, dynamic>;
    return UploadResult(url: j['url'].toString(), mime: j['mime'].toString(), size: (j['size'] as num).toInt());
  }

  Future<List<TenorGifItem>> tenorSearch({required String authToken, required String q, int limit = 16}) async {
    final r = await http.get(
      _u('/tenor/search?q=${Uri.encodeQueryComponent(q)}&limit=$limit'),
      headers: {'authorization': 'Bearer $authToken'},
    );
    if (r.statusCode != 200) throw Exception('tenor search failed: ${r.statusCode} ${r.body}');
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    final items = (j['items'] as List).cast<Map<String, dynamic>>();
    return items.map(TenorGifItem.fromJson).toList();
  }

  Future<VoiceJoin> joinVoice({required String authToken, required String room}) async {
    final r = await http.post(
      _u('/voice/join'),
      headers: {'content-type': 'application/json', 'authorization': 'Bearer $authToken'},
      body: jsonEncode({'room': room}),
    );
    if (r.statusCode != 200) throw Exception('voice/join failed: ${r.statusCode} ${r.body}');
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return VoiceJoin(url: j['url'].toString(), token: j['token'].toString(), room: j['room'].toString());
  }
}
