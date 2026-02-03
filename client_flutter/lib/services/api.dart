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
<<<<<<< HEAD
    final r = await http.get(
      _u('/channels/$channelId/messages'),
      headers: {'authorization': 'Bearer $authToken'},
    );
    if (r.statusCode != 200) throw Exception('getMessages failed: ${r.statusCode} ${r.body}');
    final j = jsonDecode(r.body) as Map<String, dynamic>;
=======
    // Prefer Discord-like endpoint, but keep legacy /messages for compatibility.
    Future<http.Response> doGet(String path) => http.get(
          _u(path),
          headers: {'authorization': 'Bearer $authToken'},
        );

    http.Response r = await doGet('/channels/$channelId/messages?limit=50');
    if (r.statusCode == 404) {
      // Fallback to older endpoint.
      r = await doGet('/messages?channelId=$channelId&limit=50');
    }

    if (r.statusCode != 200) {
      throw Exception('getMessages failed: ${r.statusCode} ${r.body}');
    }

    final body = r.body.trim();
    if (body.isEmpty) return <ChatMessage>[];

    final j = jsonDecode(body) as Map<String, dynamic>;
>>>>>>> 894ea6ff02671f77549563e5b245232d3536327a
    final items = (j['items'] as List).cast<Map<String, dynamic>>();
    return items.map(ChatMessage.fromJson).toList();
  }

  Future<ChatMessage> sendMessage({
    required String authToken,
    required String channelId,
    required String content,
    String kind = 'text',
    Map<String, dynamic>? media,
  }) async {
<<<<<<< HEAD
    final r = await http.post(
      _u('/channels/$channelId/messages'),
      headers: {'content-type': 'application/json', 'authorization': 'Bearer $authToken'},
      body: jsonEncode({'content': content, 'kind': kind, 'media': media}),
<<<<<<< HEAD
=======
=======
    Future<http.Response> doPost(String path, Map<String, dynamic> payload) => http.post(
          _u(path),
          headers: {'content-type': 'application/json', 'authorization': 'Bearer $authToken'},
          body: jsonEncode(payload),
        );

    // Prefer Discord-like endpoint.
    http.Response r = await doPost(
      '/channels/$channelId/messages',
      {'content': content, 'kind': kind, 'media': media},
>>>>>>> 894ea6ff02671f77549563e5b245232d3536327a
>>>>>>> 9527b8b752fbe685206f7cdb39f1f288dce5e352
    );
    if (r.statusCode == 404) {
      // Fallback to older endpoint.
      r = await doPost(
        '/messages',
        {'channelId': channelId, 'content': content, 'kind': kind, 'media': media},
      );
    }
    if (r.statusCode != 200) throw Exception('sendMessage failed: ${r.statusCode} ${r.body}');
    final body = r.body.trim();
    if (body.isEmpty) {
      // Older servers may respond empty; return a synthetic message.
      return ChatMessage(id: '0', channelId: channelId, authorId: 'me', content: content, kind: kind, media: media, ts: DateTime.now().millisecondsSinceEpoch);
    }
    final j = jsonDecode(body) as Map<String, dynamic>;
    if (j['item'] is Map) {
      return ChatMessage.fromJson((j['item'] as Map).cast<String, dynamic>());
    }
    // Fallback: no item field.
    return ChatMessage(id: '0', channelId: channelId, authorId: 'me', content: content, kind: kind, media: media, ts: DateTime.now().millisecondsSinceEpoch);
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
