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
  String? _voiceChatChannelId;
  bool _voiceConnecting = false;
  String? _voiceError;
  bool _micMuted = false;
  Future<void> Function()? _roomUnsub;

  // Voice presence for rendering participants under voice channels
  Map<String, List<VoiceParticipant>> _voicePresence = {};
  Timer? _voicePresenceTimer;

  @override
  void initState() {
    super.initState();
<<<<<<< HEAD
    _loadInitial();
=======

    // MVP: local mock guilds/channels.
    // Later we can replace this with API calls (GET /guilds, GET /guilds/:id/channels).
    _guilds = const [
      Guild(
        id: 'lunarus',
        name: 'Lunarus',
        channels: [
          Channel(id: 'general', name: 'general', type: ChannelType.text),
          Channel(id: 'random', name: 'random', type: ChannelType.text),
          Channel(
            id: 'voice-lobby',
            name: 'Lobby',
            type: ChannelType.voice,
            room: 'lobby',
            linkedChatChannelId: 'lobby-chat',
          ),
        ],
      ),
    ];

    _selectedGuild = _guilds.first;
    _selectedChannel = _selectedGuild.channels.firstWhere((c) => c.type == ChannelType.text);

    // Poll voice presence so the channel list can show who is in voice (Discord-like).
    _refreshVoicePresence();
    _voicePresenceTimer = Timer.periodic(const Duration(seconds: 5), (_) => _refreshVoicePresence());
>>>>>>> 6f623283521c0e62b92a6d0d8af121fa4149c58d
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
<<<<<<< HEAD
=======
    _roomUnsub = null;
    _voicePresenceTimer?.cancel();
>>>>>>> 6f623283521c0e62b92a6d0d8af121fa4149c58d
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

  Future<void> _joinVoice({required String roomName, required String chatChannelId}) async {
    // Show the voice bar immediately while we connect.
    setState(() {
      _voiceRoomName = roomName;
      _voiceChatChannelId = chatChannelId;
      _voiceConnecting = true;
      _voiceError = null;
    });

    try {
      // Disconnect previous (but keep UI state until new room is ready)
      await _leaveVoice(clearUi: false);

      final join = await widget.api.joinVoice(authToken: widget.authToken, room: roomName);
      final room = Room();

      // Rebuild on any room event (participants speaking/join/leave, etc.)
      _roomUnsub = room.events.listen((_) {
        if (mounted) setState(() {});
      });

      await room.connect(_normalizeLiveKitUrl(join.url), join.token);
      await room.localParticipant?.setMicrophoneEnabled(true);

      final pub = _micPublication(room);
      _micMuted = pub?.muted ?? false;

<<<<<<< HEAD
      _roomUnsub = room.events.listen((_) {
        if (mounted) setState(() {});
      });

=======
>>>>>>> 6f623283521c0e62b92a6d0d8af121fa4149c58d
      setState(() {
        _voiceRoom = room;
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

<<<<<<< HEAD
  Future<void> _leaveVoice() async {
=======
Future<void> _leaveVoice({bool clearUi = true}) async {
    // best-effort unsubscribe
>>>>>>> 6f623283521c0e62b92a6d0d8af121fa4149c58d
    await _roomUnsub?.call();
    _roomUnsub = null;
    await _voiceRoom?.disconnect();
    _voiceRoom = null;
    _micMuted = false;
    _voiceError = null;
    if (clearUi) {
      _voiceRoomName = null;
      _voiceChatChannelId = null;
    }
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

<<<<<<< HEAD
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

  Future<void> _selectChannel(ChannelInfo c) async {
    // Voice behavior: if already connected to this room, don't reconnect.
    if (c.type == 'voice') {
      final roomName = c.room ?? c.id;
      final already = (_voiceRoomName == roomName) && (_voiceConnecting || _voiceRoom?.connectionState == ConnectionState.connected);
      setState(() => _selectedChannel = c);

      if (!already) {
        await _joinVoice(roomName);
      }
=======

  Future<void> _refreshVoicePresence() async {
    // Fetch participants for each voice room so we can render them under the voice channel (Discord-like).
    final guild = _selectedGuild;
    final voiceChannels = guild.channels.where((c) => c.type == ChannelType.voice).toList();
    if (voiceChannels.isEmpty) return;

    final next = <String, List<VoiceParticipant>>{};
    for (final c in voiceChannels) {
      final room = c.room ?? c.id;
      try {
        final items = await widget.api.getVoiceParticipants(
          authToken: widget.authToken,
          room: room,
        );
        next[room] = items;
      } catch (_) {
        // Keep the previous list on transient errors.
        next[room] = _voicePresence[room] ?? const <VoiceParticipant>[];
      }
    }

    if (!mounted) return;
    setState(() => _voicePresence = next);
  }


void _selectGuild(Guild g) {
  setState(() {
    _selectedGuild = g;
    _selectedChannel = g.channels.firstWhere(
      (c) => c.type == ChannelType.text,
      orElse: () => g.channels.first,
    );
  });
}

Future<void> _selectChannel(Channel c) async {
  if (c.type == ChannelType.voice) {
    final roomName = c.room ?? c.id;
    final chatChannelId = c.linkedChatChannelId ?? c.id;

    // If we're already connected (or connecting) to this voice room, don't reconnect.
    if (_voiceRoomName == roomName &&
        (_voiceConnecting || _voiceRoom?.connectionState == ConnectionState.connected)) {
      if (mounted) setState(() => _selectedChannel = c);
>>>>>>> 6f623283521c0e62b92a6d0d8af121fa4149c58d
      return;
    }

    await _joinVoice(roomName: roomName, chatChannelId: chatChannelId);
    if (mounted) setState(() => _selectedChannel = c);
    return;
  }

<<<<<<< HEAD
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
=======
  setState(() => _selectedChannel = c);
}

void _openVoiceChatSheet() {
  final chatChannelId = _voiceChatChannelId;
  if (chatChannelId == null) return;

  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      minChildSize: 0.35,
      maxChildSize: 0.95,
      builder: (context, scrollController) => Material(
        child: Column(
          children: [
            Container(
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              alignment: Alignment.centerLeft,
              child: Row(
                children: [
                  const Icon(Icons.chat_bubble_outline, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Voice chat',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ChatScreen(
                api: widget.api,
                authToken: widget.authToken,
                userId: widget.userId,
                channelId: chatChannelId,
                embedded: true,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

>>>>>>> 6f623283521c0e62b92a6d0d8af121fa4149c58d

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

    final isVoice = _selectedChannel.type == ChannelType.voice;
    final title = isVoice ? '🔊 ${_selectedChannel.name}' : '#${_selectedChannel.name}';
    final rightPane = Column(
      children: [
<<<<<<< HEAD
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
                  ? _VoicePanel(roomName: selected.room ?? selected.id, room: _voiceRoom, connecting: _voiceConnecting, error: _voiceError)
                  : ChatScreen(
                      api: widget.api,
                      authToken: widget.authToken,
                      userId: widget.userId,
                      channelId: selected.id,
                      embedded: true,
                    )),
        ),
        if (_voiceRoomName != null)
          _VoiceBar(
            roomName: _voiceRoomName!,
            connecting: _voiceConnecting,
            error: _voiceError,
            micMuted: _micMuted,
            participantsCount: (_voiceRoom?.remoteParticipants.length ?? 0) + (_voiceRoom?.localParticipant != null ? 1 : 0),
            onToggleMic: _toggleMic,
            onDisconnect: () async {
              await _leaveVoice();
              if (mounted) setState(() {});
            },
          ),
=======
        _TopBar(title: title),
        Expanded(
          child: isVoice
              ? _VoiceDetails(
                  room: _voiceRoom,
                  roomName: _voiceRoomName,
                  connecting: _voiceConnecting,
                  error: _voiceError,
                  onOpenChat: _openVoiceChatSheet,
                )
              : ChatScreen(
                  api: widget.api,
                  authToken: widget.authToken,
                  userId: widget.userId,
                  channelId: _selectedChannel.id,
                  embedded: true,
                ),
        ),
        if (_voiceRoomName != null) _VoiceBar(
          roomName: _voiceRoomName!,
          connecting: _voiceConnecting,
          error: _voiceError,
          micMuted: _micMuted,
          participantsCount: (_voiceRoom?.remoteParticipants.length ?? 0) + (_voiceRoom?.localParticipant != null ? 1 : 0),
          onToggleMic: _toggleMic,
          onOpenChat: _openVoiceChatSheet,
          onDisconnect: () async {
            await _leaveVoice();
            if (mounted) setState(() {});
          },
        ),
>>>>>>> 6f623283521c0e62b92a6d0d8af121fa4149c58d
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
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ),
<<<<<<< HEAD

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
=======
            const VerticalDivider(width: 1),
            // Channels
            SizedBox(
              width: 240,
              child: _ChannelsPane(
                guildName: _selectedGuild.name,
                textChannels: textChannels,
                voiceChannels: voiceChannels,
                selected: _selectedChannel,
                onSelect: _selectChannel,
                voiceActiveRoom: _voiceRoomName,
                voicePresence: _voicePresence,
>>>>>>> 6f623283521c0e62b92a6d0d8af121fa4149c58d
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

<<<<<<< HEAD
class _VoicePanel extends StatelessWidget {
  final String roomName;
  final Room? room;
  final bool connecting;
  final String? error;
=======

class _VoiceDetails extends StatelessWidget {
  final Room? room;
  final String? roomName;
  final bool connecting;
  final String? error;
  final VoidCallback onOpenChat;

  const _VoiceDetails({
    required this.room,
    required this.roomName,
    required this.connecting,
    required this.error,
    required this.onOpenChat,
  });

  String _displayName(Participant p) {
    final n = (p.name ?? '').trim();
    if (n.isNotEmpty) return n;
    final id = (p.identity).trim();
    return id.isNotEmpty ? id : 'user';
  }

  Widget _avatarFor(String name) {
    final letter = name.isNotEmpty ? name[0].toUpperCase() : '?';
    return CircleAvatar(
      radius: 16,
      child: Text(letter, style: const TextStyle(fontWeight: FontWeight.bold)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final r = room;
    final locals = <Participant>[];
    if (r?.localParticipant != null) locals.add(r!.localParticipant!);
    final remotes = (r?.remoteParticipants.values.toList() ?? <RemoteParticipant>[]);
    final all = [...locals, ...remotes];

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.headset_mic, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  roomName == null ? 'Voice' : 'Voice: $roomName',
                  style: Theme.of(context).textTheme.titleMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              TextButton.icon(
                onPressed: onOpenChat,
                icon: const Icon(Icons.chat_bubble_outline, size: 18),
                label: const Text('Chat'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (error != null)
            Text('Error: $error', style: const TextStyle(color: Colors.red)),
          if (connecting && error == null) const Text('Connecting...'),
          const SizedBox(height: 12),
          Text('Participants (${all.length})', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Expanded(
            child: all.isEmpty
                ? const Center(child: Text('No participants yet'))
                : ListView.separated(
                    itemCount: all.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final p = all[i];
                      final name = _displayName(p);
                      final speaking = (p is RemoteParticipant) ? p.isSpeaking : false;
                      final subtitle = speaking ? 'speaking' : 'idle';
                      return ListTile(
                        leading: _avatarFor(name),
                        title: Text(name, overflow: TextOverflow.ellipsis),
                        subtitle: Text(subtitle),
                        dense: true,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _GuildRail extends StatelessWidget {
  final List<Guild> guilds;
  final Guild selected;
  final ValueChanged<Guild> onSelect;
>>>>>>> 6f623283521c0e62b92a6d0d8af121fa4149c58d

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
<<<<<<< HEAD
        ],
=======
      ],
    );
  }
}

class _ChannelsPane extends StatelessWidget {
  final String guildName;
  final List<Channel> textChannels;
  final List<Channel> voiceChannels;
  final Channel selected;
  final Future<void> Function(Channel) onSelect;
  final String? voiceActiveRoom;
  final Map<String, List<VoiceParticipant>> voicePresence;

  const _ChannelsPane({
    required this.guildName,
    required this.textChannels,
    required this.voiceChannels,
    required this.selected,
    required this.onSelect,
    required this.voiceActiveRoom,
    required this.voicePresence,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          height: 56,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          alignment: Alignment.centerLeft,
          child: Text(guildName, style: Theme.of(context).textTheme.titleMedium),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              _SectionHeader('Text Channels'),
              for (final c in textChannels)
                _ChannelTile(
                  leading: const Icon(Icons.tag, size: 18),
                  title: c.name,
                  selected: c.id == selected.id,
                  onTap: () => onSelect(c),
                ),
              const SizedBox(height: 12),
              _SectionHeader('Voice Channels'),
              for (final c in voiceChannels)
                _VoiceChannelTileWithPresence(
                  channel: c,
                  selected: c.id == selected.id,
                  activeRoom: voiceActiveRoom,
                  participants: voicePresence[c.room ?? c.id] ?? const [],
                  onTap: () => onSelect(c),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String text;
  const _SectionHeader(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
      child: Text(
        text.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Colors.white54),
      ),
    );
  }
}


class _VoiceChannelTileWithPresence extends StatelessWidget {
  final Channel channel;
  final bool selected;
  final String? activeRoom;
  final List<VoiceParticipant> participants;
  final VoidCallback onTap;

  const _VoiceChannelTileWithPresence({
    required this.channel,
    required this.selected,
    required this.activeRoom,
    required this.participants,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final roomName = channel.room ?? channel.id;
    final isActive = activeRoom == roomName;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ChannelTile(
            leading: Icon(isActive ? Icons.graphic_eq : Icons.volume_up, size: 18),
            title: channel.name,
            selected: selected,
            onTap: onTap,
          ),
          if (participants.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 18, top: 4, bottom: 6),
              child: Column(
                children: [
                  for (final p in participants.take(6))
                    _VoiceParticipantRow(name: p.name),
                  if (participants.length > 6)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '+${participants.length - 6} more',
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Colors.white54),
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _VoiceParticipantRow extends StatelessWidget {
  final String name;
  const _VoiceParticipantRow({required this.name});

  @override
  Widget build(BuildContext context) {
    final initial = name.isNotEmpty ? name.trim()[0].toUpperCase() : '?';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          CircleAvatar(radius: 10, child: Text(initial, style: const TextStyle(fontSize: 11))),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              name,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.white70),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChannelTile extends StatelessWidget {
  final Widget leading;
  final String title;
  final bool selected;
  final VoidCallback onTap;
  const _ChannelTile({required this.leading, required this.title, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            color: selected ? Colors.white12 : Colors.transparent,
          ),
          child: Row(
            children: [
              leading,
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: selected ? Colors.white : Colors.white70),
                ),
              ),
            ],
          ),
        ),
>>>>>>> 6f623283521c0e62b92a6d0d8af121fa4149c58d
      ),
    );
  }
}

class _VoiceBar extends StatelessWidget {
  final String roomName;
  final bool connecting;
  final String? error;
  final bool micMuted;
  final int participantsCount;
<<<<<<< HEAD
  final VoidCallback onToggleMic;
  final VoidCallback onDisconnect;
=======
  final Future<void> Function() onToggleMic;
  final VoidCallback onOpenChat;
  final Future<void> Function() onDisconnect;
>>>>>>> 6f623283521c0e62b92a6d0d8af121fa4149c58d

  const _VoiceBar({
    required this.roomName,
    required this.connecting,
    required this.error,
    required this.micMuted,
    required this.participantsCount,
    required this.onToggleMic,
    required this.onOpenChat,
    required this.onDisconnect,
  });

  @override
  Widget build(BuildContext context) {
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
          IconButton(
<<<<<<< HEAD
            tooltip: micMuted ? 'Включить микрофон' : 'Выключить микрофон',
            onPressed: onToggleMic,
            icon: Icon(micMuted ? Icons.mic_off : Icons.mic, color: Colors.white70),
=======
            tooltip: 'Open voice chat',
            onPressed: onOpenChat,
            icon: const Icon(Icons.chat_bubble_outline),
          ),
          IconButton(
            tooltip: micMuted ? 'Unmute mic' : 'Mute mic',
            onPressed: connecting ? null : () => onToggleMic(),
            icon: Icon(micMuted ? Icons.mic_off : Icons.mic),
>>>>>>> 6f623283521c0e62b92a6d0d8af121fa4149c58d
          ),
          IconButton(
            tooltip: 'Отключиться',
            onPressed: onDisconnect,
            icon: const Icon(Icons.call_end, color: Colors.redAccent),
          ),
        ],
      ),
    );
  }
}
