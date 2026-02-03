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
  bool _micMuted = false;

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

  LocalTrackPublication? _micPublication(Room room) {
    final lp = room.localParticipant;
    if (lp == null) return null;

    // In LiveKit Flutter SDK, audioTrackPublications contains LocalTrackPublication(s)
    // for the currently published microphone track.
    final pubs = lp.audioTrackPublications;
    if (pubs.isNotEmpty) return pubs.first;
    return null;
  }

  Future<void> _join() async {
    setState(() { _connecting = true; _error = null; });
    try {
      final join = await widget.api.joinVoice(authToken: widget.authToken, room: widget.room);
      final room = Room();

      await room.connect(_normalizeLiveKitUrl(join.url), join.token);
      await room.localParticipant?.setMicrophoneEnabled(true);

      // Prefer soft-mute via track publication, so we don't affect the system-wide mic state.
      final pub = _micPublication(room);
      _micMuted = pub?.muted ?? false;

      setState(() => _room = room);
    } catch (e) {
      setState(() => _error = 'Voice error: $e');
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  Future<void> _toggleMic() async {
    final room = _room;
    if (room == null) return;
    final pub = _micPublication(room);

    if (pub != null) {
      pub.muted = !pub.muted;
      setState(() => _micMuted = pub.muted);
      return;
    }

    // Fallback: if publication isn't available for some reason.
    final enabled = room.localParticipant?.isMicrophoneEnabled() ?? false;
    await room.localParticipant?.setMicrophoneEnabled(!enabled);
    setState(() => _micMuted = enabled);
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
                ElevatedButton.icon(
                  onPressed: _room == null ? null : _toggleMic,
                  icon: Icon(_micMuted ? Icons.mic_off : Icons.mic),
                  label: Text(_micMuted ? 'Mic muted' : 'Mic on'),
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
