import 'package:flutter/material.dart';

/// Default profile picture — gray person silhouette (Facebook/WhatsApp/TikTok style).
/// Shown when the user hasn't uploaded a profile picture.
class DefaultAvatar extends StatelessWidget {
  final double radius;
  const DefaultAvatar({super.key, this.radius = 48});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: radius * 2,
      height: radius * 2,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: isDark ? const Color(0xFF3A3A3A) : const Color(0xFFD9D9D9),
      ),
      child: CustomPaint(
        painter: _PersonSilhouettePainter(
          headColor: isDark ? const Color(0xFF6B6B6B) : const Color(0xFFF5F5F5),
          bodyColor: isDark ? const Color(0xFF6B6B6B) : const Color(0xFFF5F5F5),
        ),
      ),
    );
  }
}

class _PersonSilhouettePainter extends CustomPainter {
  final Color headColor;
  final Color bodyColor;
  _PersonSilhouettePainter({required this.headColor, required this.bodyColor});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final headPaint = Paint()..color = headColor;
    final bodyPaint = Paint()..color = bodyColor;

    // Head: circle in upper-middle
    canvas.drawCircle(
      Offset(w * 0.5, h * 0.38),
      w * 0.18,
      headPaint,
    );

    // Body: arc at bottom
    final bodyPath = Path()
      ..moveTo(w * 0.5 - w * 0.32, h)
      ..quadraticBezierTo(
        w * 0.5 - w * 0.32, h * 0.62,
        w * 0.5, h * 0.62,
      )
      ..quadraticBezierTo(
        w * 0.5 + w * 0.32, h * 0.62,
        w * 0.5 + w * 0.32, h,
      )
      ..close();
    // Clip to circle
    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromLTWH(0, 0, w, h)));
    canvas.drawPath(bodyPath, bodyPaint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Avatar that shows the user's photo, or the default silhouette if none.
class UserAvatar extends StatelessWidget {
  final String avatarUrl;
  final double radius;
  final VoidCallback? onLongPress;
  const UserAvatar({
    super.key,
    required this.avatarUrl,
    this.radius = 48,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    if (avatarUrl.isEmpty) {
      return GestureDetector(
        onLongPress: onLongPress,
        child: DefaultAvatar(radius: radius),
      );
    }
    return GestureDetector(
      onLongPress: onLongPress,
      child: CircleAvatar(
        radius: radius,
        backgroundImage: NetworkImage(avatarUrl),
        backgroundColor: Theme.of(context).brightness == Brightness.dark
            ? const Color(0xFF3A3A3A)
            : const Color(0xFFD9D9D9),
      ),
    );
  }
}
