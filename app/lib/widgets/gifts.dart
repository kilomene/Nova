import 'dart:math';

import 'package:flutter/material.dart';

/// Verification badge shown next to verified handles.
/// type: 'personal' (blue) | 'business' (pink) | 'company' (gold).
class VerifiedBadge extends StatelessWidget {
  final double size;
  final String type;
  const VerifiedBadge({super.key, this.size = 14, this.type = 'personal'});

  @override
  Widget build(BuildContext context) {
    final color = switch (type) {
      'business' => const Color(0xFFFF2E63), // pink — business verification ($65/mo)
      'company' => Color(0xFFD4AF37), // gold — company verification ($100/mo)
      _ => const Color(0xFF20D5EC), // blue — personal verification
    };
    return Icon(Icons.verified, size: size, color: color);
  }
}

/// Full-screen animated gift effect. All art is original Nova artwork drawn
/// with CustomPainter — no copied assets.
class GiftAnimationOverlay extends StatefulWidget {
  final String animation; // coin_burst | nova_heart | rocket | crown
  final String senderHandle;
  const GiftAnimationOverlay({super.key, required this.animation, required this.senderHandle});

  @override
  State<GiftAnimationOverlay> createState() => _GiftAnimationOverlayState();
}

class _GiftAnimationOverlayState extends State<GiftAnimationOverlay> with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 2600))..forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = _c.value;
        final opacity = t > 0.8 ? (1 - (t - 0.8) / 0.2) : 1.0;
        return Opacity(
          opacity: opacity.clamp(0.0, 1.0),
          child: CustomPaint(
            painter: _GiftPainter(widget.animation, t),
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 120),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)),
                  child: Text('${widget.senderHandle} sent a ${_label()}',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  String _label() {
    switch (widget.animation) {
      case 'coin_burst':
        return 'Coin Burst';
      case 'nova_heart':
        return 'Nova Heart';
      case 'rocket':
        return 'Rocket';
      case 'crown':
        return 'Golden Crown';
      default:
        return 'Gift';
    }
  }
}

class _GiftPainter extends CustomPainter {
  final String kind;
  final double t;
  final Random _r = Random(7);

  _GiftPainter(this.kind, this.t);

  @override
  void paint(Canvas canvas, Size size) {
    switch (kind) {
      case 'coin_burst':
        _coinBurst(canvas, size);
        break;
      case 'nova_heart':
        _heart(canvas, size);
        break;
      case 'rocket':
        _rocket(canvas, size);
        break;
      case 'crown':
        _crown(canvas, size);
        break;
    }
  }

  void _coinBurst(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final baseY = size.height * 0.75;
    for (var i = 0; i < 26; i++) {
      final a = (i / 26) * 2 * pi + _r.nextDouble();
      final dist = t * (120 + _r.nextDouble() * 160);
      final x = cx + cos(a) * dist;
      final y = baseY - sin(a.abs()) * dist - t * 60;
      final r = 10 + _r.nextDouble() * 10;
      final paint = Paint()..color = Color.lerp(const Color(0xFFFFD54F), const Color(0xFFFF8F00), _r.nextDouble())!;
      canvas.drawCircle(Offset(x, y), r * (1 - t * 0.4), paint);
      // shine
      canvas.drawCircle(Offset(x - r * 0.3, y - r * 0.3), r * 0.35, Paint()..color = Colors.white70);
    }
    // big central coin
    final cr = 46 * (1 + 0.15 * sin(t * 12));
    canvas.drawCircle(Offset(cx, baseY - t * 120), cr, Paint()..color = const Color(0xFFFFC107));
    canvas.drawCircle(Offset(cx, baseY - t * 120), cr * 0.72, Paint()..color = const Color(0xFFFF8F00));
    final tp = TextPainter(
      text: const TextSpan(text: 'N', style: TextStyle(color: Colors.white, fontSize: 34, fontWeight: FontWeight.bold)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(cx - tp.width / 2, baseY - t * 120 - tp.height / 2));
  }

  void _heart(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height * 0.45;
    final s = 90 * (1 + 0.18 * sin(t * 10)) * (0.6 + 0.4 * min(1, t * 3));
    final paint = Paint()..color = const Color(0xFFFF4D6D);
    final path = Path();
    path.moveTo(cx, cy + s * 0.9);
    path.cubicTo(cx - s * 1.4, cy - s * 0.1, cx - s * 0.7, cy - s * 1.1, cx, cy - s * 0.35);
    path.cubicTo(cx + s * 0.7, cy - s * 1.1, cx + s * 1.4, cy - s * 0.1, cx, cy + s * 0.9);
    canvas.drawPath(path, paint);
    // sparkles
    for (var i = 0; i < 14; i++) {
      final a = _r.nextDouble() * 2 * pi;
      final d = s * (1.2 + t * 1.5);
      canvas.drawCircle(
        Offset(cx + cos(a) * d, cy + sin(a) * d * 0.8),
        3 + _r.nextDouble() * 3,
        Paint()..color = Colors.white.withValues(alpha: 0.8 * (1 - t)),
      );
    }
  }

  void _rocket(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final y = size.height * (0.85 - t * 0.55);
    final paint = Paint()..color = const Color(0xFFE0E0E0);
    // body
    final body = Path()
      ..moveTo(cx, y - 70)
      ..quadraticBezierTo(cx + 34, y - 20, cx + 26, y + 30)
      ..lineTo(cx - 26, y + 30)
      ..quadraticBezierTo(cx - 34, y - 20, cx, y - 70);
    canvas.drawPath(body, paint);
    // window
    canvas.drawCircle(Offset(cx, y - 25), 12, Paint()..color = const Color(0xFF29B6F6));
    // fins
    final fin = Paint()..color = const Color(0xFFFF5252);
    canvas.drawPath(Path()..moveTo(cx - 26, y + 10)..lineTo(cx - 44, y + 44)..lineTo(cx - 26, y + 34)..close(), fin);
    canvas.drawPath(Path()..moveTo(cx + 26, y + 10)..lineTo(cx + 44, y + 44)..lineTo(cx + 26, y + 34)..close(), fin);
    // flame
    final flameLen = 30 + 18 * sin(t * 30).abs();
    final flame = Path()
      ..moveTo(cx - 14, y + 32)
      ..quadraticBezierTo(cx, y + 32 + flameLen + 24, cx + 14, y + 32)
      ..close();
    canvas.drawPath(flame, Paint()..color = const Color(0xFFFFB300));
    // trail particles
    for (var i = 0; i < 20; i++) {
      final py = y + 40 + _r.nextDouble() * 160 * t + 20;
      canvas.drawCircle(Offset(cx + (_r.nextDouble() - 0.5) * 60, py), 2 + _r.nextDouble() * 4,
          Paint()..color = Colors.orange.withValues(alpha: 0.7 * (1 - t * 0.5)));
    }
  }

  void _crown(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final drop = Curves.easeOut.transform(min(1, t * 2.2));
    final cy = size.height * 0.15 + drop * size.height * 0.25;
    final w = 150.0;
    final h = 90.0;
    final paint = Paint()..color = const Color(0xFFFFD54F);
    final path = Path()
      ..moveTo(cx - w / 2, cy + h / 2)
      ..lineTo(cx - w / 2, cy - h * 0.1)
      ..lineTo(cx - w * 0.28, cy + h * 0.08)
      ..lineTo(cx - w * 0.14, cy - h / 2)
      ..lineTo(cx, cy - h * 0.05)
      ..lineTo(cx + w * 0.14, cy - h / 2)
      ..lineTo(cx + w * 0.28, cy + h * 0.08)
      ..lineTo(cx + w / 2, cy - h * 0.1)
      ..lineTo(cx + w / 2, cy + h / 2)
      ..close();
    canvas.drawPath(path, paint);
    // jewels
    final jewel = Paint()..color = const Color(0xFFD32F2F);
    for (final dx in [-0.28, 0.0, 0.28]) {
      canvas.drawCircle(Offset(cx + w * dx, cy + h * 0.18), 9, jewel);
    }
    // sparkles
    for (var i = 0; i < 18; i++) {
      final a = _r.nextDouble() * 2 * pi;
      final d = 60 + t * 130;
      canvas.drawCircle(Offset(cx + cos(a) * d, cy + sin(a) * d),
          2.5 + _r.nextDouble() * 3, Paint()..color = Colors.white.withValues(alpha: 0.85 * (1 - t * 0.6)));
    }
  }

  @override
  bool shouldRepaint(covariant _GiftPainter old) => old.t != t || old.kind != kind;
}

/// Bottom-sheet gift picker used in LIVE rooms.
class GiftPickerSheet extends StatelessWidget {
  final int balance;
  final List<dynamic> gifts; // GiftItem
  final void Function(dynamic gift) onPick;
  const GiftPickerSheet({super.key, required this.balance, required this.gifts, required this.onPick});

  static const _emoji = {'coin_burst': '🪙', 'nova_heart': '💛', 'rocket': '🚀', 'crown': '👑'};

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: const BoxDecoration(
        color: Color(0xFF161616),
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Send a gift', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(color: Colors.amber.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(20)),
                child: Text('🪙 $balance', style: const TextStyle(color: Colors.amber, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          GridView.builder(
            shrinkWrap: true,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 4, childAspectRatio: 0.85),
            itemCount: gifts.length,
            itemBuilder: (context, i) {
              final g = gifts[i] as dynamic;
              final affordable = balance >= (g.coinPrice as int);
              return GestureDetector(
                onTap: affordable ? () => onPick(g) : null,
                child: Opacity(
                  opacity: affordable ? 1 : 0.4,
                  child: Column(
                    children: [
                      Text(_emoji[g.id] ?? '🎁', style: const TextStyle(fontSize: 40)),
                      Text(g.name as String, style: const TextStyle(color: Colors.white, fontSize: 11)),
                      Text('🪙 ${g.coinPrice}', style: const TextStyle(color: Colors.amber, fontSize: 11)),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
