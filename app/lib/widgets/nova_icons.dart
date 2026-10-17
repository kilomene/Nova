import 'package:flutter/material.dart';

/// Nova's premium icon set: hand-drawn with CustomPainter, gold gradient
/// fills and a soft glow. Never stock Material icons on primary surfaces.
///
/// Usage: `NovaIcon.home(active: true, size: 28)` etc.
class NovaIcon extends StatelessWidget {
  final NovaIconKind kind;
  final bool active;
  final double size;
  final Color? color;

  const NovaIcon({
    super.key,
    required this.kind,
    this.active = false,
    this.size = 26,
    this.color,
  });

  // Convenience constructors
  const NovaIcon.home({super.key, this.active = false, this.size = 26, this.color})
      : kind = NovaIconKind.home;
  const NovaIcon.shop({super.key, this.active = false, this.size = 26, this.color})
      : kind = NovaIconKind.shop;
  const NovaIcon.inbox({super.key, this.active = false, this.size = 26, this.color})
      : kind = NovaIconKind.inbox;
  const NovaIcon.profile({super.key, this.active = false, this.size = 26, this.color})
      : kind = NovaIconKind.profile;
  const NovaIcon.search({super.key, this.active = false, this.size = 26, this.color})
      : kind = NovaIconKind.search;
  const NovaIcon.heart({super.key, this.active = false, this.size = 26, this.color})
      : kind = NovaIconKind.heart;
  const NovaIcon.comment({super.key, this.active = false, this.size = 26, this.color})
      : kind = NovaIconKind.comment;
  const NovaIcon.share({super.key, this.active = false, this.size = 26, this.color})
      : kind = NovaIconKind.share;
  const NovaIcon.play({super.key, this.active = false, this.size = 26, this.color})
      : kind = NovaIconKind.play;
  const NovaIcon.live({super.key, this.active = false, this.size = 26, this.color})
      : kind = NovaIconKind.live;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final isDark = brightness == Brightness.dark;
    final base = color ??
        (active
            ? const Color(0xFFFFC107)
            : (isDark ? Colors.white70 : Colors.black87));

    return CustomPaint(
      size: Size(size, size),
      painter: _NovaIconPainter(kind: kind, active: active, base: base),
    );
  }
}

enum NovaIconKind { home, shop, inbox, profile, search, heart, comment, share, play, live }

class _NovaIconPainter extends CustomPainter {
  final NovaIconKind kind;
  final bool active;
  final Color base;

  _NovaIconPainter({required this.kind, required this.active, required this.base});

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width; // assume square
    final cx = s / 2;
    final cy = s / 2;

    // Premium treatment: soft outer glow when active.
    final glowPaint = Paint()
      ..color = const Color(0xFFFFC107).withValues(alpha: active ? 0.35 : 0.0)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);

    // Gold gradient for active state, flat base color otherwise.
    final fill = Paint()
      ..shader = active
          ? const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFFFFD54F), Color(0xFFFF8F00)],
            ).createShader(Rect.fromLTWH(0, 0, s, s))
          : null
      ..color = active ? Colors.white : base
      ..style = PaintingStyle.fill;

    final stroke = Paint()
      ..shader = active
          ? const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFFFFD54F), Color(0xFFFF8F00)],
            ).createShader(Rect.fromLTWH(0, 0, s, s))
          : null
      ..color = active ? Colors.white : base
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.075
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    if (active) {
      // Draw glow silhouette first (approximated with a blurred circle).
      canvas.drawCircle(Offset(cx, cy), s * 0.42, glowPaint);
    }

    switch (kind) {
      case NovaIconKind.home:
        _home(canvas, s, active ? fill : stroke, stroke);
        break;
      case NovaIconKind.shop:
        _shop(canvas, s, active ? fill : stroke, stroke);
        break;
      case NovaIconKind.inbox:
        _inbox(canvas, s, active ? fill : stroke, stroke);
        break;
      case NovaIconKind.profile:
        _profile(canvas, s, active ? fill : stroke, stroke);
        break;
      case NovaIconKind.search:
        _search(canvas, s, stroke);
        break;
      case NovaIconKind.heart:
        _heart(canvas, s, active ? fill : stroke);
        break;
      case NovaIconKind.comment:
        _comment(canvas, s, active ? fill : stroke, stroke);
        break;
      case NovaIconKind.share:
        _share(canvas, s, stroke);
        break;
      case NovaIconKind.play:
        _play(canvas, s, fill);
        break;
      case NovaIconKind.live:
        _live(canvas, s, fill, stroke);
        break;
    }
  }

  void _home(Canvas c, double s, Paint p, Paint stroke) {
    final path = Path()
      ..moveTo(s * 0.15, s * 0.52)
      ..lineTo(s * 0.5, s * 0.18)
      ..lineTo(s * 0.85, s * 0.52)
      ..lineTo(s * 0.72, s * 0.52)
      ..lineTo(s * 0.72, s * 0.85)
      ..lineTo(s * 0.28, s * 0.85)
      ..lineTo(s * 0.28, s * 0.52)
      ..close();
    // Active: filled house with cut-out door for depth.
    c.drawPath(path, p);
    if (p.style == PaintingStyle.fill) {
      final door = Path()
        ..addRRect(RRect.fromRectAndRadius(
            Rect.fromLTWH(s * 0.43, s * 0.58, s * 0.14, s * 0.27),
            Radius.circular(s * 0.03)));
      c.drawPath(door, Paint()..color = Colors.black.withValues(alpha: 0.55));
    }
  }

  void _shop(Canvas c, double s, Paint p, Paint stroke) {
    // Shopping bag with gold sheen.
    final bag = Path()
      ..moveTo(s * 0.25, s * 0.38)
      ..lineTo(s * 0.75, s * 0.38)
      ..lineTo(s * 0.68, s * 0.85)
      ..lineTo(s * 0.32, s * 0.85)
      ..close();
    c.drawPath(bag, p);
    // Handle
    final handle = Path()
      ..moveTo(s * 0.35, s * 0.38)
      ..cubicTo(s * 0.35, s * 0.18, s * 0.65, s * 0.18, s * 0.65, s * 0.38);
    c.drawPath(handle, stroke);
    if (p.style == PaintingStyle.fill) {
      // Sheen stripe for premium depth.
      c.drawPath(
        Path()
          ..moveTo(s * 0.38, s * 0.42)
          ..lineTo(s * 0.48, s * 0.42)
          ..lineTo(s * 0.44, s * 0.82)
          ..lineTo(s * 0.36, s * 0.82)
          ..close(),
        Paint()..color = Colors.white.withValues(alpha: 0.25),
      );
    }
  }

  void _inbox(Canvas c, double s, Paint p, Paint stroke) {
    // Chat bubble with tail.
    final bubble = Path()
      ..addRRect(RRect.fromRectAndRadius(
          Rect.fromLTWH(s * 0.15, s * 0.2, s * 0.7, s * 0.52),
          Radius.circular(s * 0.14)))
      ..moveTo(s * 0.32, s * 0.7)
      ..lineTo(s * 0.28, s * 0.86)
      ..lineTo(s * 0.48, s * 0.72)
      ..close();
    c.drawPath(bubble, p);
    if (p.style == PaintingStyle.fill) {
      // Three dots for depth.
      final dot = Paint()..color = Colors.black.withValues(alpha: 0.6);
      for (final dx in [-0.12, 0.0, 0.12]) {
        c.drawCircle(Offset(s * (0.5 + dx), s * 0.46), s * 0.035, dot);
      }
    }
  }

  void _profile(Canvas c, double s, Paint p, Paint stroke) {
    // Head + shoulders silhouette.
    c.drawCircle(Offset(s * 0.5, s * 0.36), s * 0.18, p);
    final shoulders = Path()
      ..moveTo(s * 0.2, s * 0.85)
      ..cubicTo(s * 0.2, s * 0.62, s * 0.35, s * 0.58, s * 0.5, s * 0.58)
      ..cubicTo(s * 0.65, s * 0.58, s * 0.8, s * 0.62, s * 0.8, s * 0.85)
      ..close();
    c.drawPath(shoulders, p);
  }

  void _search(Canvas c, double s, Paint stroke) {
    c.drawCircle(Offset(s * 0.44, s * 0.44), s * 0.26, stroke);
    c.drawLine(Offset(s * 0.63, s * 0.63), Offset(s * 0.84, s * 0.84), stroke);
  }

  void _heart(Canvas c, double s, Paint p) {
    final path = Path()
      ..moveTo(s * 0.5, s * 0.82)
      ..cubicTo(s * 0.18, s * 0.58, s * 0.12, s * 0.3, s * 0.32, s * 0.22)
      ..cubicTo(s * 0.44, s * 0.17, s * 0.5, s * 0.28, s * 0.5, s * 0.32)
      ..cubicTo(s * 0.5, s * 0.28, s * 0.56, s * 0.17, s * 0.68, s * 0.22)
      ..cubicTo(s * 0.88, s * 0.3, s * 0.82, s * 0.58, s * 0.5, s * 0.82)
      ..close();
    c.drawPath(path, p);
  }

  void _comment(Canvas c, double s, Paint p, Paint stroke) {
    final bubble = Path()
      ..addOval(Rect.fromLTWH(s * 0.14, s * 0.24, s * 0.72, s * 0.46));
    c.drawPath(bubble, p.style == PaintingStyle.fill ? p : stroke);
    final tail = Path()
      ..moveTo(s * 0.36, s * 0.66)
      ..lineTo(s * 0.3, s * 0.84)
      ..lineTo(s * 0.5, s * 0.68)
      ..close();
    c.drawPath(tail, p.style == PaintingStyle.fill ? p : stroke);
  }

  void _share(Canvas c, double s, Paint stroke) {
    // Three nodes connected.
    final nodes = [Offset(s * 0.78, s * 0.24), Offset(s * 0.24, s * 0.5), Offset(s * 0.78, s * 0.76)];
    c.drawLine(nodes[0], nodes[1], stroke);
    c.drawLine(nodes[1], nodes[2], stroke);
    for (final n in nodes) {
      c.drawCircle(n, s * 0.11, stroke);
    }
  }

  void _play(Canvas c, double s, Paint fill) {
    final path = Path()
      ..moveTo(s * 0.36, s * 0.24)
      ..lineTo(s * 0.74, s * 0.5)
      ..lineTo(s * 0.36, s * 0.76)
      ..close();
    c.drawPath(path, fill);
  }

  void _live(Canvas c, double s, Paint fill, Paint stroke) {
    // Broadcast: dot + radiating arcs.
    c.drawCircle(Offset(s * 0.5, s * 0.5), s * 0.1, fill);
    for (final r in [0.22, 0.34]) {
      c.drawArc(Rect.fromCircle(center: Offset(s * 0.5, s * 0.5), radius: s * r),
          -0.9, 1.8, false, stroke);
      c.drawArc(Rect.fromCircle(center: Offset(s * 0.5, s * 0.5), radius: s * r),
          3.14 - 0.9, 1.8, false, stroke);
    }
  }

  @override
  bool shouldRepaint(covariant _NovaIconPainter old) =>
      old.kind != kind || old.active != active || old.base != base;
}

/// The signature "+" create button: layered gold disc with depth and glow,
/// more premium than a flat Material icon.
class NovaCreateButton extends StatelessWidget {
  final double size;
  const NovaCreateButton({super.key, this.size = 46});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFFFD54F), Color(0xFFFFB300), Color(0xFFFF8F00)],
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFFFC107).withValues(alpha: 0.45),
            blurRadius: 14,
            spreadRadius: 1,
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 6,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Inner highlight for glassy depth.
          Container(
            width: size * 0.78,
            height: size * 0.78,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.white.withValues(alpha: 0.35), Colors.white.withValues(alpha: 0.0)],
              ),
            ),
          ),
          Icon(Icons.add, color: Colors.black87, size: size * 0.58),
        ],
      ),
    );
  }
}
