import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../models.dart';
import '../state/app_state.dart';
import '../widgets/gifts.dart';

/// Full hashtag system: taggable in captions, tappable tags, hashtag pages,
/// trending on discovery, hashtag search, tags as FYP interest signals.

final _tagRe = RegExp(r'#([A-Za-z0-9_]+)');

/// Extract #tags from a caption (lowercased, deduped).
List<String> extractHashtags(String caption) {
  final out = <String>[];
  for (final m in _tagRe.allMatches(caption)) {
    final t = m.group(1)!.toLowerCase();
    if (!out.contains(t)) out.add(t);
  }
  return out;
}

/// Caption text with tappable hashtags.
class HashtagText extends StatelessWidget {
  final String text;
  final TextStyle? style;
  final int? maxLines;
  const HashtagText(this.text, {super.key, this.style, this.maxLines});

  @override
  Widget build(BuildContext context) {
    final spans = <TextSpan>[];
    var last = 0;
    for (final m in _tagRe.allMatches(text)) {
      if (m.start > last) spans.add(TextSpan(text: text.substring(last, m.start)));
      final tag = m.group(1)!;
      spans.add(TextSpan(
        text: m.group(0),
        style: const TextStyle(fontWeight: FontWeight.w700, color: Colors.white),
        recognizer: TapGestureRecognizer()
          ..onTap = () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => HashtagScreen(tag: tag.toLowerCase()))),
      ));
      last = m.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
    return RichText(
      maxLines: maxLines,
      overflow: maxLines == null ? TextOverflow.clip : TextOverflow.ellipsis,
      text: TextSpan(style: style ?? const TextStyle(color: Colors.white), children: spans),
    );
  }
}

/// Tappable hashtag chip.
class HashtagChip extends StatelessWidget {
  final String tag;
  final int? uses;
  const HashtagChip({super.key, required this.tag, this.uses});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => HashtagScreen(tag: tag))),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF1a1a1a),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFFFFC107).withValues(alpha: 0.4)),
        ),
        child: Text('#$tag${uses != null ? ' · $uses' : ''}', style: const TextStyle(color: Color(0xFFFFC107), fontWeight: FontWeight.w600)),
      ),
    );
  }
}

/// Hashtag page: reverse-chron feed of videos carrying the tag.
class HashtagScreen extends StatefulWidget {
  final String tag;
  const HashtagScreen({super.key, required this.tag});

  @override
  State<HashtagScreen> createState() => _HashtagScreenState();
}

class _HashtagScreenState extends State<HashtagScreen> {
  List<NovaVideo> _videos = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final vids = await context.read<AppState>().hashtagVideos(widget.tag);
    if (mounted) setState(() { _videos = vids; _loading = false; });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, title: Text('#${widget.tag}')),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFFFFC107)))
          : _videos.isEmpty
              ? const Center(child: Text('No videos with this tag yet.', style: TextStyle(color: Colors.white54)))
              : GridView.builder(
                  padding: const EdgeInsets.all(2),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, crossAxisSpacing: 2, mainAxisSpacing: 2, childAspectRatio: 0.75),
                  itemCount: _videos.length,
                  itemBuilder: (context, i) {
                    final v = _videos[i];
                    return GestureDetector(
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => VideoViewerScreen(videos: _videos, initialIndex: i))),
                      child: Container(
                        color: const Color(0xFF161616),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.play_circle_outline, color: Colors.white54, size: 32),
                            const SizedBox(height: 4),
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 4),
                              child: Text(v.caption.isEmpty ? '#${widget.tag}' : v.caption,
                                  maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, fontSize: 11)),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}

/// Reusable fullscreen swipeable video viewer.
class VideoViewerScreen extends StatefulWidget {
  final List<NovaVideo> videos;
  final int initialIndex;
  const VideoViewerScreen({super.key, required this.videos, this.initialIndex = 0});

  @override
  State<VideoViewerScreen> createState() => _VideoViewerScreenState();
}

class _VideoViewerScreenState extends State<VideoViewerScreen> {
  late final PageController _pc;

  @override
  void initState() {
    super.initState();
    _pc = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.transparent, elevation: 0, leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.of(context).pop())),
      extendBodyBehindAppBar: true,
      body: PageView.builder(
        controller: _pc,
        scrollDirection: Axis.vertical,
        itemCount: widget.videos.length,
        itemBuilder: (context, i) => _ViewerCard(video: widget.videos[i]),
      ),
    );
  }
}

class _ViewerCard extends StatefulWidget {
  final NovaVideo video;
  const _ViewerCard({required this.video});

  @override
  State<_ViewerCard> createState() => _ViewerCardState();
}

class _ViewerCardState extends State<_ViewerCard> {
  VideoPlayerController? _c;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final url = widget.video.mediaUrl;
    try {
      final c = url.startsWith('http')
          ? VideoPlayerController.networkUrl(Uri.parse(url))
          : VideoPlayerController.asset(url);
      await c.initialize();
      c.setLooping(true);
      c.play();
      if (mounted) setState(() => _c = c);
    } catch (_) {}
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.video;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (_c != null && _c!.value.isInitialized)
          FittedBox(fit: BoxFit.cover, child: SizedBox(width: _c!.value.size.width, height: _c!.value.size.height, child: VideoPlayer(_c!)))
        else
          const Center(child: CircularProgressIndicator(color: Color(0xFFFFC107))),
        Positioned(
          left: 12, right: 12, bottom: 24,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Text('@${v.handle}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                if (v.isVerified) ...[const SizedBox(width: 4), const VerifiedBadge(size: 14)],
              ]),
              const SizedBox(height: 6),
              if (v.caption.isNotEmpty) HashtagText(v.caption),
            ],
          ),
        ),
      ],
    );
  }
}
