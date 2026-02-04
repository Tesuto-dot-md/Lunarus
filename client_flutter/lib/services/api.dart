import 'dart:convert';

import 'package:http/http.dart' as http;

/// Human-friendly API error.
class ApiException implements Exception {
  final String message;
  final int? statusCode;
  final String? bodySnippet;

  ApiException(this.message, {this.statusCode, this.bodySnippet});

  @override
  String toString() {
    final sc = (statusCode == null) ? '' : ' (HTTP $statusCode)';
    final snip = (bodySnippet == null || bodySnippet!.isEmpty) ? '' : "\nBody: ${bodySnippet!}";
    return 'ApiException: $message$sc$snip';
  }
}

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

class ServerInfo {
  final String id;
  final String name;
  final String? icon; // emoji or url
  final String? ownerId;
  ServerInfo({required this.id, required this.name, required this.icon, required this.ownerId});

  factory ServerInfo.fromJson(Map<String, dynamic> j) => ServerInfo(
        id: j['id'].toString(),
        name: j['name'].toString(),
        icon: (j['icon'] == null) ? null : j['icon'].toString(),
        ownerId: (j['ownerId'] == null) ? null : j['ownerId'].toString(),
      );
}

class InvitePreview {
  final String code;
  final String serverId;
  final String serverName;
  final String? serverIcon;
  final String? channelId;
  InvitePreview({
    required this.code,
    required this.serverId,
    required this.serverName,
    required this.serverIcon,
    required this.channelId,
  });

  factory InvitePreview.fromJson(Map<String, dynamic> j) => InvitePreview(
        code: j['code'].toString(),
        serverId: j['serverId'].toString(),
        serverName: j['serverName'].toString(),
        serverIcon: (j['serverIcon'] == null) ? null : j['serverIcon'].toString(),
        channelId: (j['channelId'] == null) ? null : j['channelId'].toString(),
      );
}

class ChannelInfo {
  final String id;
  final String serverId;
  final String name;
  final String type; // text | voice | forum
  final int position;
  final String? icon; // emoji/custom/url
  final bool nsfw;
  final bool isPrivate;
  final String? linkedTextChannelId;
  final String? room; // voice room name (optional)
  ChannelInfo({
    required this.id,
    required this.serverId,
    required this.name,
    required this.type,
    required this.position,
    required this.icon,
    required this.nsfw,
    required this.isPrivate,
    required this.linkedTextChannelId,
    required this.room,
  });

  factory ChannelInfo.fromJson(Map<String, dynamic> j) => ChannelInfo(
        id: j['id'].toString(),
        serverId: j['serverId'].toString(),
        name: j['name'].toString(),
        type: (j['type'] ?? 'text').toString(),
        position: (j['position'] as num?)?.toInt() ?? 0,
        icon: (j['icon'] == null) ? null : j['icon'].toString(),
        nsfw: (j['nsfw'] as bool?) ?? false,
        isPrivate: (j['isPrivate'] as bool?) ?? false,
        linkedTextChannelId: (j['linkedTextChannelId'] == null) ? null : j['linkedTextChannelId'].toString(),
        room: (j['room'] == null) ? null : j['room'].toString(),
      );
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

  String _snip(String s, {int max = 400}) {
    final t = s.trim();
    if (t.length <= max) return t;
    return '${t.substring(0, max)}…';
  }

  void _ensureOk(http.Response r, String ctx) {
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw ApiException('$ctx failed', statusCode: r.statusCode, bodySnippet: _snip(r.body));
    }
  }

  dynamic _decodeJson(http.Response r, String ctx) {
    final body = r.body.trim();
    if (body.isEmpty) {
      throw ApiException('Empty response from API for $ctx', statusCode: r.statusCode);
    }
    try {
      return jsonDecode(body);
    } on FormatException catch (e) {
      throw ApiException('Invalid JSON for $ctx: ${e.message}', statusCode: r.statusCode, bodySnippet: _snip(body));
    }
  }

  Future<LoginResult> login({required String username}) async {
    final r = await http.post(
      _u('/auth/login'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({'username': username, 'password': 'demo'}),
    );
    _ensureOk(r, 'login');
    final j = (_decodeJson(r, 'login') as Map).cast<String, dynamic>();
    final token = j['token'] as String;
    final user = (j['user'] as Map).cast<String, dynamic>();
    return LoginResult(token: token, userId: user['id'].toString());
  }

  // ---- Messages ----

  Future<List<ChatMessage>> getMessages({required String authToken, required String channelId}) async {
    Future<http.Response> doGet(String path) => http.get(
          _u(path),
          headers: {'authorization': 'Bearer $authToken'},
        );

    http.Response r = await doGet('/channels/$channelId/messages?limit=50');
    if (r.statusCode == 404) {
      r = await doGet('/messages?channelId=$channelId&limit=50');
    }
    _ensureOk(r, 'getMessages');

    final body = r.body.trim();
    if (body.isEmpty) return <ChatMessage>[];

    final j = (_decodeJson(r, 'getMessages') as Map).cast<String, dynamic>();
    final itemsRaw = (j['items'] as List? ?? const <dynamic>[]);
    final items = itemsRaw.map((e) => (e as Map).cast<String, dynamic>()).toList();
    return items.map(ChatMessage.fromJson).toList();
  }

  Future<ChatMessage> sendMessage({
    required String authToken,
    required String channelId,
    required String content,
    String kind = 'text',
    Map<String, dynamic>? media,
  }) async {
    Future<http.Response> doPost(String path, Map<String, dynamic> payload) => http.post(
          _u(path),
          headers: {'content-type': 'application/json', 'authorization': 'Bearer $authToken'},
          body: jsonEncode(payload),
        );

    http.Response r = await doPost(
      '/channels/$channelId/messages',
      {'content': content, 'kind': kind, 'media': media},
    );
    if (r.statusCode == 404) {
      r = await doPost(
        '/messages',
        {'channelId': channelId, 'content': content, 'kind': kind, 'media': media},
      );
    }
    _ensureOk(r, 'sendMessage');

    final body = r.body.trim();
    if (body.isEmpty) {
      // Older servers may respond empty; return a synthetic message.
      return ChatMessage(
        id: '0',
        channelId: channelId,
        authorId: 'me',
        content: content,
        kind: kind,
        media: media,
        ts: DateTime.now().millisecondsSinceEpoch,
      );
    }

    final j = (_decodeJson(r, 'sendMessage') as Map).cast<String, dynamic>();
    if (j['item'] is Map) {
      return ChatMessage.fromJson((j['item'] as Map).cast<String, dynamic>());
    }
    return ChatMessage(
      id: '0',
      channelId: channelId,
      authorId: 'me',
      content: content,
      kind: kind,
      media: media,
      ts: DateTime.now().millisecondsSinceEpoch,
    );
  }

  // ---- Uploads / GIFs ----

  Future<UploadResult> uploadFile({required String authToken, required String filePath}) async {
    final req = http.MultipartRequest('POST', _u('/upload'));
    req.headers['authorization'] = 'Bearer $authToken';
    req.files.add(await http.MultipartFile.fromPath('file', filePath));

    final resp = await req.send();
    final body = await resp.stream.bytesToString();
    final r = http.Response(body, resp.statusCode);
    _ensureOk(r, 'upload');
    final j = (_decodeJson(r, 'upload') as Map).cast<String, dynamic>();
    return UploadResult(
      url: j['url'].toString(),
      mime: j['mime'].toString(),
      size: (j['size'] as num).toInt(),
    );
  }

  Future<List<TenorGifItem>> tenorSearch({required String authToken, required String q, int limit = 16}) async {
    final r = await http.get(
      _u('/tenor/search?q=${Uri.encodeQueryComponent(q)}&limit=$limit'),
      headers: {'authorization': 'Bearer $authToken'},
    );
    _ensureOk(r, 'tenorSearch');
    final j = (_decodeJson(r, 'tenorSearch') as Map).cast<String, dynamic>();
    final itemsRaw = (j['items'] as List? ?? const <dynamic>[]);
    final items = itemsRaw.map((e) => (e as Map).cast<String, dynamic>()).toList();
    return items.map(TenorGifItem.fromJson).toList();
  }

  // ---- Servers / Channels / Invites ----

  Future<List<ServerInfo>> getServers({required String authToken}) async {
    final r = await http.get(
      _u('/servers'),
      headers: {'authorization': 'Bearer $authToken'},
    );
    _ensureOk(r, 'getServers');
    final j = (_decodeJson(r, 'getServers') as Map).cast<String, dynamic>();
    final itemsRaw = (j['items'] as List? ?? const <dynamic>[]);
    final items = itemsRaw.map((e) => (e as Map).cast<String, dynamic>()).toList();
    return items.map(ServerInfo.fromJson).toList();
  }

  Future<ServerInfo> createServer({required String authToken, required String name, String? icon}) async {
    final r = await http.post(
      _u('/servers'),
      headers: {'content-type': 'application/json', 'authorization': 'Bearer $authToken'},
      body: jsonEncode({'name': name, 'icon': icon}),
    );
    _ensureOk(r, 'createServer');
    final j = (_decodeJson(r, 'createServer') as Map).cast<String, dynamic>();
    return ServerInfo.fromJson((j['item'] as Map).cast<String, dynamic>());
  }

  Future<List<ChannelInfo>> getServerChannels({required String authToken, required String serverId}) async {
    final r = await http.get(
      _u('/servers/$serverId/channels'),
      headers: {'authorization': 'Bearer $authToken'},
    );
    _ensureOk(r, 'getServerChannels');
    final j = (_decodeJson(r, 'getServerChannels') as Map).cast<String, dynamic>();
    final itemsRaw = (j['items'] as List? ?? const <dynamic>[]);
    final items = itemsRaw.map((e) => (e as Map).cast<String, dynamic>()).toList();
    return items.map(ChannelInfo.fromJson).toList();
  }

  Future<ChannelInfo> createChannel({
    required String authToken,
    required String serverId,
    required String name,
    required String type,
    String? icon,
    bool nsfw = false,
    bool isPrivate = false,
  }) async {
    final r = await http.post(
      _u('/servers/$serverId/channels'),
      headers: {'content-type': 'application/json', 'authorization': 'Bearer $authToken'},
      body: jsonEncode({'name': name, 'type': type, 'icon': icon, 'nsfw': nsfw, 'isPrivate': isPrivate}),
    );
    _ensureOk(r, 'createChannel');
    final j = (_decodeJson(r, 'createChannel') as Map).cast<String, dynamic>();
    return ChannelInfo.fromJson((j['item'] as Map).cast<String, dynamic>());
  }

  Future<ChannelInfo> patchChannel({
    required String authToken,
    required String channelId,
    String? name,
    String? icon,
    bool? nsfw,
    bool? isPrivate,
    String? type,
    int? position,
    String? linkedTextChannelId,
    String? room,
  }) async {
    final payload = <String, dynamic>{};
    if (name != null) payload['name'] = name;
    if (icon != null) payload['icon'] = icon;
    if (nsfw != null) payload['nsfw'] = nsfw;
    if (isPrivate != null) payload['isPrivate'] = isPrivate;
    if (type != null) payload['type'] = type;
    if (position != null) payload['position'] = position;
    if (linkedTextChannelId != null) payload['linkedTextChannelId'] = linkedTextChannelId;
    if (room != null) payload['room'] = room;

    final r = await http.patch(
      _u('/channels/$channelId'),
      headers: {'content-type': 'application/json', 'authorization': 'Bearer $authToken'},
      body: jsonEncode(payload),
    );
    _ensureOk(r, 'patchChannel');
    final j = (_decodeJson(r, 'patchChannel') as Map).cast<String, dynamic>();
    return ChannelInfo.fromJson((j['item'] as Map).cast<String, dynamic>());
  }

  Future<void> deleteChannel({required String authToken, required String channelId}) async {
    final r = await http.delete(
      _u('/channels/$channelId'),
      headers: {'authorization': 'Bearer $authToken'},
    );
    _ensureOk(r, 'deleteChannel');
  }

  Future<String> createInvite({required String authToken, required String serverId, String? channelId}) async {
    final r = await http.post(
      _u('/servers/$serverId/invites'),
      headers: {'content-type': 'application/json', 'authorization': 'Bearer $authToken'},
      body: jsonEncode({'channelId': channelId}),
    );
    _ensureOk(r, 'createInvite');
    final j = (_decodeJson(r, 'createInvite') as Map).cast<String, dynamic>();
    return (j['item'] as Map)['code'].toString();
  }

  Future<InvitePreview> getInvitePreview({required String authToken, required String codeOrUrl}) async {
    final raw = codeOrUrl.trim();
    String code = raw;
    try {
      final u = Uri.parse(raw);
      if (u.pathSegments.isNotEmpty) code = u.pathSegments.last;
    } catch (_) {}

    final r = await http.get(
      _u('/invites/$code'),
      headers: {'authorization': 'Bearer $authToken'},
    );
    _ensureOk(r, 'getInvitePreview');
    final j = (_decodeJson(r, 'getInvitePreview') as Map).cast<String, dynamic>();
    return InvitePreview.fromJson((j['item'] as Map).cast<String, dynamic>());
  }

  Future<ServerInfo> joinInvite({required String authToken, required String codeOrUrl}) async {
    final raw = codeOrUrl.trim();
    String code = raw;
    try {
      final u = Uri.parse(raw);
      if (u.pathSegments.isNotEmpty) code = u.pathSegments.last;
    } catch (_) {}

    final r = await http.post(
      _u('/invites/$code/join'),
      headers: {'content-type': 'application/json', 'authorization': 'Bearer $authToken'},
      body: jsonEncode({}),
    );
    _ensureOk(r, 'joinInvite');
    final j = (_decodeJson(r, 'joinInvite') as Map).cast<String, dynamic>();
    return ServerInfo.fromJson((j['item'] as Map).cast<String, dynamic>());
  }

  // ---- Voice ----

  Future<VoiceJoin> joinVoice({required String authToken, required String room}) async {
    final r = await http.post(
      _u('/voice/join'),
      headers: {'content-type': 'application/json', 'authorization': 'Bearer $authToken'},
      body: jsonEncode({'room': room}),
    );
    _ensureOk(r, 'joinVoice');
    final j = (_decodeJson(r, 'joinVoice') as Map).cast<String, dynamic>();
    return VoiceJoin(url: j['url'].toString(), token: j['token'].toString(), room: j['room'].toString());
  }
}
