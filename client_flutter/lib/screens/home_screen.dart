import 'dart:async';

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:livekit_client/livekit_client.dart';

import '../services/api.dart';
import 'chat_screen.dart';

/// Discord-like shell:
/// - Left: servers (guilds)
/// - Middle: channel list
/// - Right: chat (text channels) or voice panel (voice channels)
/// Voice stays connected while you browse.
class HomeScreen extends StatefulWidget {
  final ApiClient api;
  final String authToken;
  final String userId;

  const HomeScreen({super.key, required this.api, required this.authToken, required this.userId});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // Servers + channels (fetched from API)
  List<ServerInfo> _servers = const [];
  ServerInfo? _selectedServer;
  List<ChannelInfo> _channels = const [];
  ChannelInfo? _selectedChannel;

  bool _loading = true;
  String? _loadError;

  // Voice session state
  Room? _voiceRoom;
  String? _voiceRoomName;
  String? _voiceChannelLabel;
  String? _voiceChatChannelId;
  bool _voiceConnecting = false;
  String? _voiceError;
  bool _micMuted = false;
  Future<void> Function()? _roomUnsub;

  // Voice-channel embedded chat UI state
  // Pinned = dock chat panel inside the voice view.
  // Collapsed = hide chat while keeping the voice view.
  // Height = resizable bottom-sheet height when not pinned.
  bool _voiceChatPinned = false;
  bool _voiceChatCollapsed = false;
  double _voiceChatHeight = 340.0;

  @override
  void initState() {
    super.initState();
    _loadInitial();
  }

  Future<void> _loadInitial() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });

    try {
      final servers = await widget.api.getServers(authToken: widget.authToken);
      if (servers.isEmpty) throw Exception('no servers returned');
      final selected = servers.first;

      final channels = await widget.api.getServerChannels(authToken: widget.authToken, serverId: selected.id);

      ChannelInfo? initialText = channels.where((c) => c.type == 'text' && !_isHiddenTextChannel(c)).cast<ChannelInfo?>().firstWhere((x) => x != null, orElse: () => null);
      initialText ??= channels.where((c) => c.type == 'text').cast<ChannelInfo?>().firstWhere((x) => x != null, orElse: () => null);
      // If still null, pick any channel.
      initialText ??= channels.isNotEmpty ? channels.first : null;

      setState(() {
        _servers = servers;
        _selectedServer = selected;
        _channels = channels;
        _selectedChannel = initialText;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _loadError = e.toString();
      });
    }
  }

  bool _isHiddenTextChannel(ChannelInfo c) {
    // Voice-linked internal chat channels shouldn't clutter the left channel list.
    // Convention: lobby-chat is linked from voice-lobby. In future, use linkedTextChannelId to infer.
    return c.id.endsWith('-chat') && _channels.any((x) => x.type == 'voice' && x.linkedTextChannelId == c.id);
  }

  List<ChannelInfo> get _textChannels => _channels.where((c) => c.type == 'text' && !_isHiddenTextChannel(c)).toList();
  List<ChannelInfo> get _voiceChannels => _channels.where((c) => c.type == 'voice').toList();
  List<ChannelInfo> get _forumChannels => _channels.where((c) => c.type == 'forum').toList();

  @override
  void dispose() {
    _roomUnsub?.call();
    _voiceRoom?.disconnect();
    super.dispose();
  }

  String _normalizeLiveKitUrl(String url) {
    // LiveKit Flutter SDK expects ws/wss URL for signaling.
    if (url.startsWith('http://')) return 'ws://' + url.substring('http://'.length);
    if (url.startsWith('https://')) return 'wss://' + url.substring('https://'.length);
    return url;
  }

  LocalTrackPublication<LocalAudioTrack>? _micPublication(Room room) {
    final lp = room.localParticipant;
    if (lp == null) return null;
    final pubs = lp.audioTrackPublications;
    if (pubs.isEmpty) return null;
    return pubs.first;
  }

  Future<void> _joinVoice({required String roomName, required String channelLabel, String? chatChannelId}) async {
    setState(() {
      _voiceConnecting = true;
      _voiceError = null;
    });

    try {
      // Disconnect previous
      await _leaveVoice();

      final join = await widget.api.joinVoice(authToken: widget.authToken, room: roomName);
      final room = Room();
      await room.connect(_normalizeLiveKitUrl(join.url), join.token);
      await room.localParticipant?.setMicrophoneEnabled(true);

      final pub = _micPublication(room);
      _micMuted = pub?.muted ?? false;

      _roomUnsub = room.events.listen((_) {
        if (mounted) setState(() {});
      });

      setState(() {
        _voiceRoom = room;
        _voiceRoomName = roomName;
        _voiceChannelLabel = channelLabel;
        _voiceChatChannelId = (chatChannelId != null && chatChannelId.trim().isNotEmpty) ? chatChannelId.trim() : null;
      });
    } catch (e) {
      setState(() {
        _voiceError = e.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _voiceConnecting = false;
        });
      }
    }
  }

  Future<void> _leaveVoice() async {
    await _roomUnsub?.call();
    _roomUnsub = null;
    await _voiceRoom?.disconnect();
    _voiceRoom = null;
    _voiceRoomName = null;
    _voiceChannelLabel = null;
    _voiceChatChannelId = null;
    _voiceChatPinned = false;
    _voiceChatCollapsed = false;
    _micMuted = false;
    _voiceError = null;
  }

  Future<void> _openVoiceChatSheet() async {
    final chatId = _voiceChatChannelId;
    if (chatId == null || chatId.isEmpty) return;

    // If pinned chat is enabled, we don't need a sheet.
    if (_voiceChatPinned) return;

    final h = MediaQuery.of(context).size.height;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return DraggableScrollableSheet(
          initialChildSize: 0.55,
          minChildSize: 0.25,
          maxChildSize: 0.95,
          builder: (ctx, scrollController) {
            return Container(
              height: h,
              decoration: BoxDecoration(
                color: Theme.of(ctx).colorScheme.surface,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
              ),
              child: Column(
                children: [
                  const SizedBox(height: 10),
                  Container(
                    width: 42,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Theme.of(ctx).colorScheme.onSurface.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: ChatScreen(
                      api: widget.api,
                      userId: widget.userId,
                      authToken: widget.authToken,
                      channelId: chatId,
                      embedded: true,
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _toggleMic() async {
    final room = _voiceRoom;
    if (room == null) return;
    final pub = _micPublication(room);

    if (pub == null) {
      final lp = room.localParticipant;
      if (lp == null) return;
      final enabled = lp.isMicrophoneEnabled();
      await lp.setMicrophoneEnabled(!enabled);
      setState(() => _micMuted = enabled);
      return;
    }

    final nextMuted = !pub.muted;
    if (nextMuted) {
      await pub.mute();
    } else {
      await pub.unmute();
    }
    setState(() => _micMuted = nextMuted);
  }

  Future<void> _selectServer(ServerInfo s) async {
    setState(() {
      _selectedServer = s;
      _channels = const [];
      _selectedChannel = null;
      _loading = true;
      _loadError = null;
    });

    try {
      final channels = await widget.api.getServerChannels(authToken: widget.authToken, serverId: s.id);
      ChannelInfo? initialText = channels.where((c) => c.type == 'text' && !_isHiddenTextChannel(c)).cast<ChannelInfo?>().firstWhere((x) => x != null, orElse: () => null);
      initialText ??= channels.isNotEmpty ? channels.first : null;

      setState(() {
        _channels = channels;
        _selectedChannel = initialText;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _loadError = e.toString();
      });
    }
  }

  Future<void> _reloadServersAndSelect(String serverId) async {
    final servers = await widget.api.getServers(authToken: widget.authToken);
    final selected = servers.firstWhere((x) => x.id == serverId, orElse: () => servers.first);
    final channels = await widget.api.getServerChannels(authToken: widget.authToken, serverId: selected.id);
    ChannelInfo? initialText = channels.where((c) => c.type == 'text' && !_isHiddenTextChannel(c)).cast<ChannelInfo?>().firstWhere((x) => x != null, orElse: () => null);
    initialText ??= channels.isNotEmpty ? channels.first : null;
    setState(() {
      _servers = servers;
      _selectedServer = selected;
      _channels = channels;
      _selectedChannel = initialText;
    });
  }

  Future<void> _openAddServerDialog() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.add_circle_outline),
                title: const Text('Создать сервер'),
                onTap: () => Navigator.pop(ctx, 'create'),
              ),
              ListTile(
                leading: const Icon(Icons.link),
                title: const Text('Войти по приглашению'),
                onTap: () => Navigator.pop(ctx, 'join'),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );

    if (choice == 'create') {
      await _openCreateServerDialog();
    } else if (choice == 'join') {
      await _openJoinServerDialog();
    }
  }

  Future<void> _openCreateServerDialog() async {
    String name = '';
    String icon = '';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Создать сервер'),
          content: StatefulBuilder(
            builder: (ctx, setLocal) {
              return SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      decoration: const InputDecoration(labelText: 'Название'),
                      onChanged: (v) => setLocal(() => name = v),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      decoration: const InputDecoration(labelText: 'Иконка (эмодзи/URL, опционально)'),
                      onChanged: (v) => setLocal(() => icon = v),
                    ),
                  ],
                ),
              );
            },
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Создать')),
          ],
        );
      },
    );

    if (ok != true) return;
    try {
      final created = await widget.api.createServer(authToken: widget.authToken, name: name.trim(), icon: icon.trim().isEmpty ? null : icon.trim());
      await _reloadServersAndSelect(created.id);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не удалось создать сервер: $e')));
    }
  }

  Future<void> _openJoinServerDialog() async {
    String code = '';
    InvitePreview? preview;
    String? error;

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            Future<void> loadPreview() async {
              setLocal(() {
                preview = null;
                error = null;
              });
              try {
                final p = await widget.api.getInvitePreview(authToken: widget.authToken, codeOrUrl: code);
                setLocal(() => preview = p);
              } catch (e) {
                setLocal(() => error = e.toString());
              }
            }

            return AlertDialog(
              title: const Text('Войти по приглашению'),
              content: SizedBox(
                width: 460,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      decoration: const InputDecoration(labelText: 'Код или ссылка'),
                      onChanged: (v) => setLocal(() => code = v),
                      onSubmitted: (_) => loadPreview(),
                    ),
                    const SizedBox(height: 10),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: code.trim().isEmpty ? null : loadPreview,
                        icon: const Icon(Icons.search),
                        label: const Text('Проверить'),
                      ),
                    ),
                    if (error != null) Text(error!, style: const TextStyle(color: Colors.redAccent)),
                    if (preview != null)
                      ListTile(
                        leading: CircleAvatar(child: Text(preview!.serverName.characters.first.toUpperCase())),
                        title: Text(preview!.serverName),
                        subtitle: Text('Код: ${preview!.code}'),
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Закрыть')),
                ElevatedButton(
                  onPressed: preview == null
                      ? null
                      : () async {
                          try {
                            final srv = await widget.api.joinInvite(authToken: widget.authToken, codeOrUrl: preview!.code);
                            if (context.mounted) Navigator.pop(ctx);
                            await _reloadServersAndSelect(srv.id);
                          } catch (e) {
                            setLocal(() => error = e.toString());
                          }
                        },
                  child: const Text('Войти'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _selectChannel(ChannelInfo c) async {
    // Voice behavior: if already connected to this room, don't reconnect.
    if (c.type == 'voice') {
      // NOTE: some DB rows may contain empty string for room/linked chat.
      // Treat empty as null so we don't end up joining backend default 'demo-room'.
      final roomName = (c.room != null && c.room!.trim().isNotEmpty) ? c.room!.trim() : c.id;
      final chatId = (c.linkedTextChannelId != null && c.linkedTextChannelId!.trim().isNotEmpty) ? c.linkedTextChannelId!.trim() : null;
      final already = (_voiceRoomName == roomName) && (_voiceConnecting || _voiceRoom?.connectionState == ConnectionState.connected);
      setState(() => _selectedChannel = c);

      if (!already) {
        await _joinVoice(roomName: roomName, channelLabel: c.name, chatChannelId: chatId);
      }
      return;
    }

    setState(() => _selectedChannel = c);
  }

  Future<void> _editChannel(ChannelInfo c) async {
    String icon = c.icon ?? '';
    bool nsfw = c.nsfw;
    bool isPrivate = c.isPrivate;
    String type = c.type;

    final res = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text('Настройки канала: ${c.name}'),
          content: StatefulBuilder(
            builder: (ctx, setLocal) {
              return SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      decoration: const InputDecoration(
                        labelText: 'Значок (эмодзи/текст/URL)',
                        hintText: 'Напр. # или 💬 или https://...',
                      ),
                      controller: TextEditingController(text: icon),
                      onChanged: (v) => setLocal(() => icon = v),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Checkbox(value: nsfw, onChanged: (v) => setLocal(() => nsfw = v ?? false)),
                        const Text('NSFW'),
                        const SizedBox(width: 16),
                        Checkbox(value: isPrivate, onChanged: (v) => setLocal(() => isPrivate = v ?? false)),
                        const Text('Приватный (🔒)'),
                      ],
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      value: type,
                      decoration: const InputDecoration(labelText: 'Тип'),
                      items: const [
                        DropdownMenuItem(value: 'text', child: Text('Текстовый')),
                        DropdownMenuItem(value: 'voice', child: Text('Голосовой')),
                        DropdownMenuItem(value: 'forum', child: Text('Форум')),
                      ],
                      onChanged: (v) => setLocal(() => type = v ?? type),
                    ),
                    if (type == 'voice') ...[
                      const SizedBox(height: 8),
                      Text('Room: ${c.room ?? c.id}', style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ],
                ),
              );
            },
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Отмена')),
            ElevatedButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Сохранить')),
          ],
        );
      },
    );

    if (res != true) return;

    try {
      final updated = await widget.api.patchChannel(
        authToken: widget.authToken,
        channelId: c.id,
        icon: icon.trim().isEmpty ? '#' : icon.trim(),
        nsfw: nsfw,
        isPrivate: isPrivate,
        type: type,
      );

      setState(() {
        _channels = _channels.map((x) => x.id == updated.id ? updated : x).toList();
        if (_selectedChannel?.id == updated.id) _selectedChannel = updated;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не удалось сохранить: $e')));
    }
  }

  Widget _serverButton(ServerInfo s, bool selected) {
    final icon = s.icon;
    Widget child;
    if (icon != null && icon.trim().isNotEmpty) {
      if (icon.startsWith('http://') || icon.startsWith('https://')) {
        child = ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.network(icon, width: 40, height: 40, fit: BoxFit.cover),
        );
      } else {
        child = Center(child: Text(icon, style: const TextStyle(fontSize: 20)));
      }
    } else {
      child = Center(child: Text(s.name.characters.take(1).toString().toUpperCase(), style: const TextStyle(fontSize: 18)));
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: InkWell(
        onTap: () => _selectServer(s),
        borderRadius: BorderRadius.circular(14),
        child: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: selected ? Colors.white10 : Colors.white.withOpacity(0.04),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: selected ? Colors.white24 : Colors.transparent),
          ),
          child: child,
        ),
      ),
    );
  }

  Widget _channelLeading(ChannelInfo c) {
    final raw = (c.icon ?? '').trim();
    final fallback = c.type == 'voice' ? '🔊' : (c.type == 'forum' ? '🗂️' : '#');
    final v = raw.isEmpty ? fallback : raw;

    if (v.startsWith('http://') || v.startsWith('https://')) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image.network(v, width: 18, height: 18, fit: BoxFit.cover),
      );
    }

    return Text(v, style: const TextStyle(fontSize: 14, color: Colors.white70));
  }

  Widget _channelBadges(ChannelInfo c) {
    final chips = <Widget>[];
    if (c.isPrivate) {
      chips.add(const Icon(Icons.lock, size: 14, color: Colors.white60));
    }
    if (c.nsfw) {
      chips.add(Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.red.withOpacity(0.18),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Colors.red.withOpacity(0.35)),
        ),
        child: const Text('NSFW', style: TextStyle(fontSize: 10, color: Colors.redAccent)),
      ));
    }
    if (c.type == 'forum') {
      chips.add(const Icon(Icons.forum, size: 14, color: Colors.white60));
    }
    if (chips.isEmpty) return const SizedBox.shrink();
    return Row(children: [
      const SizedBox(width: 8),
      ...chips.expand((w) => [w, const SizedBox(width: 6)]).toList(),
    ]);
  }

  Widget _channelTile(ChannelInfo c) {
    final selected = _selectedChannel?.id == c.id;

    return InkWell(
      onTap: () => _selectChannel(c),
      onLongPress: () => _editChannel(c),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? Colors.white10 : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            _channelLeading(c),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                c.name,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: selected ? Colors.white : Colors.white70, fontSize: 14),
              ),
            ),
            _channelBadges(c),
          ],
        ),
      ),
    );
  }

  Widget _channelSection(String title, List<ChannelInfo> items) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Text(title.toUpperCase(), style: const TextStyle(fontSize: 11, color: Colors.white54, letterSpacing: 0.6)),
          ),
          ...items.map(_channelTile),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: SafeArea(
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }
    if (_loadError != null) {
      return Scaffold(
        body: SafeArea(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Ошибка загрузки: $_loadError'),
                const SizedBox(height: 12),
                ElevatedButton(onPressed: _loadInitial, child: const Text('Повторить')),
              ],
            ),
          ),
        ),
      );
    }

    final server = _selectedServer!;
    final selected = _selectedChannel;

    final rightPane = Column(
      children: [
        _TopBar(
          title: (selected == null)
              ? server.name
              : (selected.type == 'voice'
                  ? '🔊 ${selected.name}'
                  : (selected.type == 'forum' ? '🗂️ ${selected.name}' : '#${selected.name}')),
        ),
        Expanded(
  child: (selected == null)
      ? const Center(child: Text('Нет каналов'))
      : (selected.type == 'voice'
          ? _VoiceWithChatPanel(
              api: widget.api,
              authToken: widget.authToken,
              userId: widget.userId,
              channel: selected,
              roomName: (_voiceChannelLabel ?? _voiceRoomName ?? selected.name).toString(),
              room: _voiceRoom,
              connecting: _voiceConnecting,
              error: _voiceError,
              pinned: _voiceChatPinned,
              collapsed: _voiceChatCollapsed,
              chatHeight: _voiceChatHeight,
              onToggleCollapsed: () => setState(() => _voiceChatCollapsed = !_voiceChatCollapsed),
              onResize: (h) => setState(() => _voiceChatHeight = h),
            )
          : ChatScreen(
              api: widget.api,
              authToken: widget.authToken,
              userId: widget.userId,
              channelId: selected.id,
              embedded: false,
            )),
),
        if (_voiceRoomName != null)
          _VoiceBar(
            roomName: (_voiceChannelLabel ?? _voiceRoomName!).toString(),
            room: _voiceRoom,
            connecting: _voiceConnecting,
            error: _voiceError,
            micMuted: _micMuted,
            onToggleMic: _toggleMic,
            hasChat: _voiceChatChannelId != null,
            chatPinned: _voiceChatPinned,
            onOpenChat: _openVoiceChatSheet,
	            onTogglePinned: () => setState(() => _voiceChatPinned = !_voiceChatPinned),
            onLeave: () async {
              await _leaveVoice();
              if (mounted) setState(() {});
            },
          ),
      ],
    );

    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            // Servers rail
            Container(
              width: 64,
              decoration: BoxDecoration(color: Colors.black.withOpacity(0.25)),
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    const SizedBox(height: 8),
                    ..._servers.map((s) => _serverButton(s, s.id == server.id)),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: InkWell(
                        onTap: _openAddServerDialog,
                        borderRadius: BorderRadius.circular(14),
                        child: Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.06),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: Colors.white12),
                          ),
                          child: const Icon(Icons.add, color: Colors.white70),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ),

            // Channel list
            Container(
              width: 260,
              decoration: BoxDecoration(color: Colors.black.withOpacity(0.18)),
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        child: Text(server.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                      ),
                      _channelSection('Text', _textChannels),
                      _channelSection('Voice', _voiceChannels),
                      _channelSection('Forum', _forumChannels),
                      const SizedBox(height: 12),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Text(
                          'Long-press channel to edit icon/flags',
                          style: TextStyle(fontSize: 11, color: Colors.white.withOpacity(0.35)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // Main content
            Expanded(child: rightPane),
          ],
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  final String title;
  const _TopBar({required this.title});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(color: Colors.black.withOpacity(0.15), border: Border(bottom: BorderSide(color: Colors.white.withOpacity(0.06)))),
      alignment: Alignment.centerLeft,
      child: Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
    );
  }
}


class _VoiceWithChatPanel extends StatelessWidget {
  final ApiClient api;
  final String authToken;
  final String userId;
  final ChannelInfo channel;
  final String? roomName;
  final Room? room;
  final bool connecting;
  final String? error;

  final bool pinned;
  final bool collapsed;
  final double chatHeight;
  final VoidCallback onToggleCollapsed;
  final ValueChanged<double> onResize;

  const _VoiceWithChatPanel({
    required this.api,
    required this.authToken,
    required this.userId,
    required this.channel,
    required this.roomName,
    required this.room,
    required this.connecting,
    required this.error,
    required this.pinned,
    required this.collapsed,
    required this.chatHeight,
    required this.onToggleCollapsed,
    required this.onResize,
  });

  @override
  Widget build(BuildContext context) {
    final chatChannelId = channel.linkedTextChannelId;

    return LayoutBuilder(
      builder: (context, c) {
        final minH = 160.0;
        final maxH = (c.maxHeight * 0.7).clamp(240.0, 520.0);
        final clampedH = chatHeight.clamp(minH, maxH);

        return Column(
          children: [
            Expanded(
              child: _VoicePanel(
                roomName: (roomName == null || roomName!.isEmpty) ? 'Голосовой' : roomName!,
                room: room,
                connecting: connecting,
                error: error,
              ),
            ),

            if (pinned && chatChannelId != null)
              _PinnedChat(
                api: api,
                authToken: authToken,
                userId: userId,
                channelId: chatChannelId,
                collapsed: collapsed,
                height: clampedH,
                minHeight: minH,
                maxHeight: maxH,
                onToggleCollapsed: onToggleCollapsed,
                onResize: onResize,
              ),
          ],
        );
      },
    );
  }
}

class _PinnedChat extends StatelessWidget {
  final ApiClient api;
  final String authToken;
  final String userId;
  final String channelId;

  final bool collapsed;
  final double height;
  final double minHeight;
  final double maxHeight;

  final VoidCallback onToggleCollapsed;
  final ValueChanged<double> onResize;

  const _PinnedChat({
    required this.api,
    required this.authToken,
    required this.userId,
    required this.channelId,
    required this.collapsed,
    required this.height,
    required this.minHeight,
    required this.maxHeight,
    required this.onToggleCollapsed,
    required this.onResize,
  });

  @override
  Widget build(BuildContext context) {
    final border = BorderSide(color: Colors.white.withOpacity(0.08));

    if (collapsed) {
      return Container(
        height: 44,
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.25),
          border: Border(top: border),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(
          children: [
            const Icon(Icons.chat_bubble_outline, size: 18),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                'Чат (свернут)',
                style: TextStyle(fontWeight: FontWeight.w600),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              tooltip: 'Развернуть',
              onPressed: onToggleCollapsed,
              icon: const Icon(Icons.keyboard_arrow_up),
            ),
          ],
        ),
      );
    }

    return SizedBox(
      height: height,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.25),
          border: Border(top: border),
        ),
        child: Column(
          children: [
            // Resize handle + header
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onVerticalDragUpdate: (d) {
                final next = (height - d.delta.dy).clamp(minHeight, maxHeight);
                onResize(next);
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: Row(
                  children: [
                    Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.18),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                    const SizedBox(width: 10),
                    const Icon(Icons.chat_bubble_outline, size: 18),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Чат',
                        style: TextStyle(fontWeight: FontWeight.w600),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Свернуть',
                      onPressed: onToggleCollapsed,
                      icon: const Icon(Icons.keyboard_arrow_down),
                    ),
                  ],
                ),
              ),
            ),
            const Divider(height: 1, thickness: 1),
            Expanded(
              child: ChatScreen(
                api: api,
                authToken: authToken,
                userId: userId,
                channelId: channelId,
                embedded: true,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VoicePanel extends StatelessWidget {
  final String roomName;
  final Room? room;
  final bool connecting;
  final String? error;

  const _VoicePanel({required this.roomName, required this.room, required this.connecting, required this.error});

  @override
  Widget build(BuildContext context) {
    final participants = <Participant>[];
    if (room?.localParticipant != null) participants.add(room!.localParticipant!);
    participants.addAll(room?.remoteParticipants.values ?? const Iterable.empty());

    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Voice: $roomName', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          if (connecting) const Text('Подключение...', style: TextStyle(color: Colors.white70)),
          if (error != null) Text('Ошибка: $error', style: const TextStyle(color: Colors.redAccent)),
          const SizedBox(height: 12),
          const Text('Участники', style: TextStyle(fontSize: 13, color: Colors.white70)),
          const SizedBox(height: 8),
          Expanded(
            child: ListView.builder(
              itemCount: participants.length,
              itemBuilder: (ctx, i) {
                final p = participants[i];
                final name = (p.name.isNotEmpty ? p.name : p.identity);
                return ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(child: Text(name.isNotEmpty ? name.characters.first.toUpperCase() : '?')),
                  title: Text(name, style: const TextStyle(fontSize: 14)),
                  subtitle: Text(p is LocalParticipant ? 'Вы' : 'В голосовом', style: const TextStyle(fontSize: 11, color: Colors.white54)),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _VoiceBar extends StatelessWidget {
  final String roomName;
  final Room? room;
  final bool connecting;
  final String? error;
  final bool micMuted;
  final bool hasChat;
  final bool chatPinned;
  final VoidCallback onOpenChat;
  final VoidCallback onTogglePinned;
  final VoidCallback onToggleMic;
  final VoidCallback onLeave;

  const _VoiceBar({
    required this.roomName,
    required this.room,
    required this.connecting,
    required this.error,
    required this.micMuted,
    required this.hasChat,
    required this.chatPinned,
    required this.onOpenChat,
    required this.onTogglePinned,
    required this.onToggleMic,
    required this.onLeave,
  });

  @override
  Widget build(BuildContext context) {
    final local = room?.localParticipant;
    final remoteCount = room?.remoteParticipants.length ?? 0;
    final participantsCount = (local == null ? 0 : 1) + remoteCount;

    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(color: Colors.black.withOpacity(0.25), border: Border(top: BorderSide(color: Colors.white.withOpacity(0.06)))),
      child: Row(
        children: [
          const Icon(Icons.graphic_eq, size: 18, color: Colors.white70),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('В голосовом: $roomName', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(
                  error != null
                      ? 'Ошибка подключения'
                      : (connecting ? 'Подключение…' : 'Участников: $participantsCount'),
                  style: TextStyle(fontSize: 11, color: error != null ? Colors.redAccent : Colors.white60),
                ),
              ],
            ),
          ),
          if (hasChat)
            IconButton(
              tooltip: 'Чат голосового канала',
              onPressed: onOpenChat,
              icon: const Icon(Icons.chat_bubble_outline, color: Colors.white70),
            ),
          if (hasChat)
            IconButton(
              tooltip: chatPinned ? 'Открепить чат' : 'Закрепить чат',
              onPressed: onTogglePinned,
              icon: Icon(chatPinned ? Icons.push_pin : Icons.push_pin_outlined, color: Colors.white70),
            ),
          IconButton(
            tooltip: micMuted ? 'Включить микрофон' : 'Выключить микрофон',
            onPressed: onToggleMic,
            icon: Icon(micMuted ? Icons.mic_off : Icons.mic, color: Colors.white70),
          ),
          IconButton(
            tooltip: 'Отключиться',
            onPressed: onLeave,
            icon: const Icon(Icons.call_end, color: Colors.redAccent),
          ),
        ],
      ),
    );
  }
}
