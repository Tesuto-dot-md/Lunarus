import 'dart:async';
import 'package:flutter/material.dart';
import '../services/api.dart';
import '../services/gateway.dart';
import 'voice_screen.dart';

class ChatScreen extends StatefulWidget {
  final ApiClient api;
  final String authToken;
  final String userId;
  /// Which text channel to show. The backend treats this as an arbitrary channel id.
  final String channelId;

  /// When true, renders without its own Scaffold/AppBar so it can be embedded
  /// into a multi-column layout (Discord-like).
  final bool embedded;

  const ChatScreen({
    super.key,
    required this.api,
    required this.authToken,
    required this.userId,
    this.channelId = 'general',
    this.embedded = false,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _input = TextEditingController();
  final _items = <ChatMessage>[];
  GatewayClient? _gw;
  StreamSubscription? _sub;

  late String _channelId;

  @override
  void initState() {
    super.initState();
    _channelId = widget.channelId;
    _loadHistory();
    _connectGateway();
  }

  @override
  void didUpdateWidget(covariant ChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.channelId != oldWidget.channelId) {
      _switchChannel(widget.channelId);
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _gw?.dispose();
    _input.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    final history = await widget.api.getMessages(authToken: widget.authToken, channelId: _channelId);
    setState(() {
      _items
        ..clear()
        ..addAll(history);
    });
  }

  Future<void> _switchChannel(String next) async {
    setState(() {
      _channelId = next;
      _items.clear();
    });
    // Subscribe via gateway (best-effort) and reload history.
    _gw?.subscribe(_channelId);
    await _loadHistory();
  }

  Future<void> _connectGateway() async {
    final gw = GatewayClient(
      wsUrl: widget.api.gatewayWsUrl(),
      token: widget.authToken,
      initialChannelId: _channelId,
    );
    await gw.connect();
    _sub = gw.events.listen((evt) {
      if (evt.type == 'MESSAGE_CREATE') {
        final m = ChatMessage.fromJson(evt.data as Map<String, dynamic>);
        setState(() => _items.add(m));
      }
    });
    setState(() => _gw = gw);
  }

  Future<void> _sendText() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    await widget.api.sendMessage(authToken: widget.authToken, channelId: _channelId, content: text);
  }

  Future<void> _sendImage() async {
    final controller = TextEditingController();
    final choice = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Send image'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: 'URL (https://...) или локальный путь (/home/.../img.png)',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('Send')),
        ],
      ),
    );
    if (choice == null || choice.isEmpty) return;

    if (choice.startsWith('http://') || choice.startsWith('https://')) {
      await widget.api.sendMessage(
        authToken: widget.authToken,
        channelId: _channelId,
        content: '',
        kind: 'image',
        media: {'url': choice},
      );
      return;
    }

    // treat as file path -> upload to server
    final up = await widget.api.uploadFile(authToken: widget.authToken, filePath: choice);
    await widget.api.sendMessage(
      authToken: widget.authToken,
      channelId: _channelId,
      content: '',
      kind: 'image',
      media: {'url': up.url, 'mime': up.mime, 'size': up.size},
    );
  }

  Future<void> _sendGif() async {
    final qController = TextEditingController(text: 'excited');
    List<TenorGifItem> items = [];
    bool loading = false;
    String? err;

    Future<void> doSearch(StateSetter setStateDialog) async {
      setStateDialog(() { loading = true; err = null; });
      try {
        items = await widget.api.tenorSearch(authToken: widget.authToken, q: qController.text.trim(), limit: 18);
      } catch (e) {
        err = e.toString();
      } finally {
        setStateDialog(() { loading = false; });
      }
    }

    final selected = await showDialog<TenorGifItem>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setStateDialog) => AlertDialog(
          title: const Text('Tenor GIF'),
          content: SizedBox(
            width: 720,
            height: 480,
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(child: TextField(controller: qController, decoration: const InputDecoration(hintText: 'Search...'))),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: loading ? null : () => doSearch(setStateDialog),
                      child: Text(loading ? '...' : 'Search'),
                    ),
                  ],
                ),
                if (err != null) ...[
                  const SizedBox(height: 8),
                  Text(err!, style: const TextStyle(color: Colors.red)),
                ],
                const SizedBox(height: 8),
                Expanded(
                  child: items.isEmpty
                      ? const Center(child: Text('Введите запрос и нажмите Search'))
                      : GridView.builder(
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            mainAxisSpacing: 8,
                            crossAxisSpacing: 8,
                          ),
                          itemCount: items.length,
                          itemBuilder: (_, i) {
                            final it = items[i];
                            return InkWell(
                              onTap: () => Navigator.pop(context, it),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.network(it.previewUrl, fit: BoxFit.cover),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
          ],
        ),
      ),
    );

    if (selected == null) return;

    await widget.api.sendMessage(
      authToken: widget.authToken,
      channelId: _channelId,
      content: '',
      kind: 'gif',
      media: {'url': selected.url, 'provider': 'tenor', 'id': selected.id},
    );
  }

  Widget _renderMessage(ChatMessage m) {
    final title = Text(m.authorId, style: const TextStyle(fontWeight: FontWeight.w600));

    if (m.kind == 'text') {
      return ListTile(title: title, subtitle: Text(m.content), dense: true);
    }

    final url = (m.media?['url'] ?? '').toString();
    final caption = (m.content.isNotEmpty) ? Text(m.content) : null;

    return ListTile(
      title: title,
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (caption != null) caption,
          const SizedBox(height: 6),
          if (url.isNotEmpty)
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.network(url, fit: BoxFit.cover),
            )
          else
            const Text('[media missing]'),
        ],
      ),
      dense: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final body = Column(
      children: [
        Expanded(
          child: ListView.builder(
            itemCount: _items.length,
            itemBuilder: (_, i) => _renderMessage(_items[i]),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Send image',
                onPressed: _sendImage,
                icon: const Icon(Icons.image),
              ),
              IconButton(
                tooltip: 'Send GIF (Tenor)',
                onPressed: _sendGif,
                icon: const Icon(Icons.gif_box),
              ),
              Expanded(
                child: TextField(
                  controller: _input,
                  onSubmitted: (_) => _sendText(),
                  decoration: const InputDecoration(hintText: 'Сообщение...'),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(onPressed: _sendText, child: const Text('Send')),
            ],
          ),
        ),
      ],
    );

    if (widget.embedded) {
      return body;
    }

    return Scaffold(
      appBar: AppBar(
        title: Text('#$_channelId'),
        actions: [
          IconButton(
            tooltip: 'Reload history',
            onPressed: _loadHistory,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Voice (demo)',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => VoiceScreen(api: widget.api, authToken: widget.authToken, room: 'demo-room'),
                ),
              );
            },
            icon: const Icon(Icons.headset_mic),
          ),
        ],
      ),
      body: body,
    );
  }
}
