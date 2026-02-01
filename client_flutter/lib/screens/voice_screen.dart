import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import '../services/api.dart';

class VoiceScreen extends StatefulWidget {
  final ApiClient api;
  final String authToken;
  final String room;

  const VoiceScreen({super.key, required this.api, required this.authToken, required this.room});

  @override
  State<VoiceScreen> createState() => _VoiceScreenState();
}

class _VoiceScreenState extends State<VoiceScreen> {
  Room? _room;
  String? _error;
  bool _connecting = true;

  @override
  void initState() {
    super.initState();
    _join();
  }

  @override
  void dispose() {
    _room?.disconnect();
    super.dispose();
  }

  

String _normalizeLiveKitUrl(String url) {
  // LiveKit Flutter SDK expects ws/wss URL for signaling.
  // Allow server to return http/https and normalize it.
  if (url.startsWith('http://')) return 'ws://' + url.substring('http://'.length);
  if (url.startsWith('https://')) return 'wss://' + url.substring('https://'.length);
  return url;
}

Future<void> _join() async {
    setState(() { _connecting = true; _error = null; });
    try {
      final join = await widget.api.joinVoice(authToken: widget.authToken, room: widget.room);
      final room = Room();

      await room.connect(_normalizeLiveKitUrl(join.url), join.token);
      await room.localParticipant?.setMicrophoneEnabled(true);

      setState(() => _room = room);
    } catch (e) {
      setState(() => _error = 'Voice error: $e');
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final participants = _room?.remoteParticipants ?? <String, RemoteParticipant>{};
    return Scaffold(
      appBar: AppBar(title: Text('Voice: ${widget.room}')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_connecting) const Text('Connecting...'),
            if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
            const SizedBox(height: 12),
            Text('Participants: ${participants.length + (_room?.localParticipant != null ? 1 : 0)}'),
            const SizedBox(height: 12),
            Expanded(
              child: ListView(
                children: [
                  if (_room?.localParticipant != null)
                    const ListTile(title: Text('(you)'), subtitle: Text('local participant')),
                  for (final p in participants.values)
                    ListTile(
                      title: Text(p.identity),
                      subtitle: Text(p.isSpeaking ? 'speaking' : 'idle'),
                    ),
                ],
              ),
            ),
            Row(
              children: [
                ElevatedButton(
                  onPressed: _room == null ? null : () async {
                    final enabled = _room!.localParticipant?.isMicrophoneEnabled() ?? false;
                    await _room!.localParticipant?.setMicrophoneEnabled(!enabled);
                    setState(() {});
                  },
                  child: const Text('Toggle Mic'),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: () {
                    Navigator.of(context).pop();
                  },
                  child: const Text('Back'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
