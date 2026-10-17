import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../services/api_client.dart';
import '../services/nudity_scanner.dart';
import '../state/app_state.dart';
import 'hashtag.dart';

/// Upload flow: pick a video → preview → caption/hashtags/audio → post.
///
/// Music policy (Snapchat model, $0): no licensed catalog. Bring your own
/// audio — upload video with music baked in, or import an audio file from the
/// device. Imported audio is attributed "Original audio - @you" and reusable.
/// A rights affirmation is required at upload time.
class UploadScreen extends StatefulWidget {
  const UploadScreen({super.key});

  @override
  State<UploadScreen> createState() => _UploadScreenState();
}

class _UploadScreenState extends State<UploadScreen> {
  String? _filePath;
  VideoPlayerController? _preview;
  final _caption = TextEditingController();
  final _hashtags = TextEditingController();
  String? _audioPath;
  bool _rightsAffirmed = false;
  bool _posting = false;
  bool _scanning = false;

  Future<void> _pick() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.video);
    if (r == null || r.files.single.path == null) return;
    await _preview?.dispose();
    final c = VideoPlayerController.file(File(r.files.single.path!));
    await c.initialize();
    c.setLooping(true);
    c.play();
    setState(() {
      _filePath = r.files.single.path;
      _preview = c;
    });
  }

  Future<void> _pickAudio() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.audio);
    if (r != null && r.files.single.path != null) setState(() => _audioPath = r.files.single.path);
  }

  @override
  void dispose() {
    _preview?.dispose();
    _caption.dispose();
    _hashtags.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, title: const Text('Upload')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            GestureDetector(
              onTap: _pick,
              child: Container(
                height: 260,
                decoration: BoxDecoration(color: const Color(0xFF161616), borderRadius: BorderRadius.circular(12)),
                child: _preview != null && _preview!.value.isInitialized
                    ? ClipRRect(borderRadius: BorderRadius.circular(12), child: AspectRatio(aspectRatio: _preview!.value.aspectRatio, child: VideoPlayer(_preview!)))
                    : const Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.video_call_outlined, size: 56, color: Colors.white38),
                          SizedBox(height: 8),
                          Text('Tap to pick a video', style: TextStyle(color: Colors.white54)),
                        ],
                      ),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _caption,
              maxLength: 300,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(labelText: 'Caption', labelStyle: TextStyle(color: Colors.white54)),
            ),
            TextField(
              controller: _hashtags,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Hashtags (comma separated)',
                labelStyle: TextStyle(color: Colors.white54),
                hintText: 'nova,afrobeats,buildinpublic',
                hintStyle: TextStyle(color: Colors.white24),
              ),
            ),
            OutlinedButton.icon(
              onPressed: _pickAudio,
              icon: const Icon(Icons.audio_file_outlined, color: Color(0xFFFFC107)),
              label: Text(
                _audioPath == null ? 'Import audio from device (optional)' : 'Audio attached ✓ (Original audio - @you)',
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
            ),
            const SizedBox(height: 4),
            const Text('No licensed music catalog in v1 — bring your own audio. Uploaded audio is attributed to you and reusable by others.',
                style: TextStyle(color: Colors.white38, fontSize: 11)),
            const SizedBox(height: 8),
            CheckboxListTile(
              value: _rightsAffirmed,
              onChanged: (v) => setState(() => _rightsAffirmed = v ?? false),
              title: const Text('I own or have rights to this video and audio, and I accept takedowns for violations.',
                  style: TextStyle(color: Colors.white70, fontSize: 12)),
              activeColor: const Color(0xFFFFC107),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
            ),
            const SizedBox(height: 8),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFFC107), foregroundColor: Colors.black),
              onPressed: (_filePath == null || _posting || !_rightsAffirmed)
                  ? null
                  : () async {
                      setState(() { _posting = true; _scanning = true; });
                      try {
                        final state = context.read<AppState>();
                        // On-device safety scan BEFORE upload (strict, private).
                        String scanVerdict = '';
                        if (!state.isDemo) {
                          final scanner = NudityScanner();
                          final score = await scanner.scoreVideo(_filePath!);
                          final v = scanner.verdict(score);
                          scanner.dispose();
                          if (v == ScanVerdict.block) {
                            // Auto-block + file for a strike via the review queue.
                            await state.submitReport(targetType: 'user', targetId: state.me?.uid ?? '', reason: 'nudity');
                            if (mounted) {
                              setState(() { _posting = false; _scanning = false; });
                              showDialog(
                                context: context,
                                builder: (context) => const AlertDialog(
                                  backgroundColor: Color(0xFF1a1a1a),
                                  title: Text('Upload blocked', style: TextStyle(color: Colors.redAccent)),
                                  content: Text(
                                    'This video was flagged by the on-device safety scan with high confidence. It was not uploaded. A report has been filed — repeated violations lead to strikes and suspension.',
                                    style: TextStyle(color: Colors.white70),
                                  ),
                                ),
                              );
                            }
                            return;
                          }
                          if (v == ScanVerdict.quarantine) scanVerdict = 'borderline';
                        }
                        if (mounted) setState(() => _scanning = false);
                        final tags = _hashtags.text.split(',').map((e) => e.trim().replaceAll('#', '')).where((e) => e.isNotEmpty).toList();
                        // Tags written directly in the caption count too.
                        for (final t in extractHashtags(_caption.text)) {
                          if (!tags.contains(t)) tags.add(t);
                        }
                        await state.uploadVideo(
                              filePath: _filePath!,
                              caption: _caption.text.trim(),
                              hashtags: tags,
                              soundLabel: _audioPath == null ? '' : 'Original audio - @${state.me?.handle ?? 'you'}',
                              audioKey: _audioPath ?? '',
                              rightsAffirmed: _rightsAffirmed,
                              scanVerdict: scanVerdict,
                            );
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                              content: Text(scanVerdict == 'borderline'
                                  ? 'Uploaded — held for review before it appears in feeds.'
                                  : 'Posted to your feed.')));
                          _caption.clear();
                          _hashtags.clear();
                          setState(() {
                            _filePath = null;
                            _audioPath = null;
                            _rightsAffirmed = false;
                          });
                          await _preview?.dispose();
                          _preview = null;
                        }
                      } catch (e) {
                        // Never show raw exception text (e.g. ApiException(401,
                        // missing_bearer_token)) — ApiException.message is human.
                        final msg = e is ApiException ? e.message : 'Upload failed. Please try again.';
                        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
                      } finally {
                        if (mounted) setState(() { _posting = false; _scanning = false; });
                      }
                    },
              child: Text(_posting ? (_scanning ? 'Scanning…' : 'Posting…') : 'Post'),
            ),
          ],
        ),
      ),
    );
  }
}
