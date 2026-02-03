import 'dart:async';

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:livekit_client/livekit_client.dart';

import '../services/api.dart';
import 'chat_screen.dart';

enum ChannelType { text, voice }

class Guild {
  final String id;
  final String name;
  final List<Channel> channels;
  const Guild({required this.id, required this.name, required this.channels});
}

class Channel {
  final String id;
  final String name;
  final ChannelType type;

  /// For voice channels: LiveKit room name.
  final String? room;

  /// Optional: chat channel to open when voice channel is selected.
  final String? linkedChatChannelId;

  const Channel({
    required this.id,
    required this.name,
    required this.type,
    this.room,
    this.linkedChatChannelId,
  });
}

/// Discord-like shell: left guild rail, middle channel list, right chat.
/// Voice stays connected while you keep browsing channels and chatting.
class HomeScreen extends StatefulWidget {
  final ApiClient api;
  final String authToken;
  final String userId;

  const HomeScreen({super.key, required this.api, required this.authToken, required this.userId});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final List<Guild> _guilds;
  late Guild _selectedGuild;
  late Channel _selectedChannel;

  // Voice session state
  Room? _voiceRoom;
  String? _voiceRoomName;
  String? _voiceChatChannelId;
  bool _voiceConnecting = false;
  String? _voiceError;
  bool _micMuted = false;
  // livekit_client's room.events.listen(...) returns an unsubscribe callback
  // (Future<void> Function()), not a StreamSubscription.
  Future<void> Function()? _roomUnsub;

  // Voice presence for rendering participants under voice channels
  Map<String, List<VoiceParticipant>> _voicePresence = {};
  Timer? _voicePresenceTimer;

  @override
  void initState() {
    super.initState();

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
  }

  @override
  void dispose() {
    // best-effort unsubscribe (ignore result in dispose)
    _roomUnsub?.call();
    _roomUnsub = null;
    _voicePresenceTimer?.cancel();
    _voiceRoom?.disconnect();
    super.dispose();
  }

  String _normalizeLiveKitUrl(String url) {
    // LiveKit Flutter SDK expects ws/wss URL for signaling.
    // Allow backend to return http/https and normalize it.
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

      // Prefer soft-mute on the publication (does not toggle system mic state).
      final pub = _micPublication(room);
      _micMuted = pub?.muted ?? false;

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

Future<void> _leaveVoice({bool clearUi = true}) async {
    // best-effort unsubscribe
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

    // If we can't find a publication yet, fallback to enabling/disabling mic.
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
      return;
    }

    await _joinVoice(roomName: roomName, chatChannelId: chatChannelId);
    if (mounted) setState(() => _selectedChannel = c);
    return;
  }

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


  @override
  Widget build(BuildContext context) {
    final textChannels = _selectedGuild.channels.where((c) => c.type == ChannelType.text).toList();
    final voiceChannels = _selectedGuild.channels.where((c) => c.type == ChannelType.voice).toList();

    final isVoice = _selectedChannel.type == ChannelType.voice;
    final title = isVoice ? '🔊 ${_selectedChannel.name}' : '#${_selectedChannel.name}';
    final rightPane = Column(
      children: [
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
      ],
    );

    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            // Guild rail
            SizedBox(
              width: 72,
              child: _GuildRail(
                guilds: _guilds,
                selected: _selectedGuild,
                onSelect: _selectGuild,
              ),
            ),
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
              ),
            ),
            const VerticalDivider(width: 1),
            // Chat
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
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      alignment: Alignment.centerLeft,
      child: Text(title, style: Theme.of(context).textTheme.titleMedium),
    );
  }
}


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

  const _GuildRail({required this.guilds, required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 12),
      children: [
        for (final g in guilds)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
            child: Tooltip(
              message: g.name,
              child: InkWell(
                onTap: () => onSelect(g),
                borderRadius: BorderRadius.circular(18),
                child: Container(
                  height: 48,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    color: g.id == selected.id ? Colors.white12 : Colors.white10,
                    border: Border.all(
                      color: g.id == selected.id ? Colors.white24 : Colors.transparent,
                    ),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    (g.name.isNotEmpty ? g.name[0] : '?').toUpperCase(),
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ),
          ),
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
  final Future<void> Function() onToggleMic;
  final VoidCallback onOpenChat;
  final Future<void> Function() onDisconnect;

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
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Colors.white12)),
      ),
      child: Row(
        children: [
          const Icon(Icons.headset_mic, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Voice: $roomName', overflow: TextOverflow.ellipsis),
                Text(
                  error != null
                      ? 'Error: $error'
                      : connecting
                          ? 'Connecting...'
                          : 'Participants: $participantsCount',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Colors.white60),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Open voice chat',
            onPressed: onOpenChat,
            icon: const Icon(Icons.chat_bubble_outline),
          ),
          IconButton(
            tooltip: micMuted ? 'Unmute mic' : 'Mute mic',
            onPressed: connecting ? null : () => onToggleMic(),
            icon: Icon(micMuted ? Icons.mic_off : Icons.mic),
          ),
          IconButton(
            tooltip: 'Disconnect',
            onPressed: () => onDisconnect(),
            icon: const Icon(Icons.call_end),
          ),
        ],
      ),
    );
  }
}
