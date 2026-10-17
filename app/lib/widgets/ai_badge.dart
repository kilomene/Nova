import 'package:flutter/material.dart';

/// Viewer-facing badge shown on any AI-generated content.
/// Subtle but unmissable: dark pill with gold sparkle icon + "AI" label.
class AiBadge extends StatelessWidget {
  final bool compact;
  const AiBadge({super.key, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 6 : 8,
        vertical: compact ? 2 : 4,
      ),
      decoration: BoxDecoration(
        color: (isDark ? Colors.black : Colors.white).withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFFFC107).withValues(alpha: 0.7), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.auto_awesome, size: compact ? 10 : 12, color: const Color(0xFFFFC107)),
          SizedBox(width: compact ? 3 : 4),
          Text(
            'AI-generated',
            style: TextStyle(
              color: const Color(0xFFFFC107),
              fontSize: compact ? 9 : 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }
}

/// Uploader-side declaration toggle: mandatory choice before publishing.
/// Placed on the upload screen; blocks publishing until answered.
class AiDeclarationToggle extends StatelessWidget {
  final bool? isAiGenerated; // null = unanswered
  final ValueChanged<bool> onChanged;

  const AiDeclarationToggle({
    super.key,
    required this.isAiGenerated,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final card = isDark ? const Color(0xFF161616) : Colors.white;
    final text = isDark ? Colors.white : Colors.black87;
    final sub = isDark ? Colors.white60 : Colors.black54;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isAiGenerated == null
              ? (isDark ? Colors.white24 : Colors.black12)
              : const Color(0xFFFFC107).withValues(alpha: 0.6),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.auto_awesome, color: Color(0xFFFFC107), size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Is this AI-generated?',
                  style: TextStyle(color: text, fontWeight: FontWeight.w700, fontSize: 14),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'AI-made photos, videos or audio must be labeled so viewers know.',
            style: TextStyle(color: sub, fontSize: 12),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _choice(
                context,
                label: 'Yes, AI-made',
                selected: isAiGenerated == true,
                onTap: () => onChanged(true),
              ),
              const SizedBox(width: 10),
              _choice(
                context,
                label: 'No, filmed/real',
                selected: isAiGenerated == false,
                onTap: () => onChanged(false),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _choice(BuildContext context,
      {required String label, required bool selected, required VoidCallback onTap}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            gradient: selected
                ? const LinearGradient(colors: [Color(0xFFFFD54F), Color(0xFFFF8F00)])
                : null,
            color: selected ? null : (isDark ? Colors.white10 : Colors.black.withValues(alpha: 0.05)),
            border: Border.all(
              color: selected ? Colors.transparent : (isDark ? Colors.white24 : Colors.black12),
            ),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: selected ? Colors.black : (isDark ? Colors.white70 : Colors.black54),
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
        ),
      ),
    );
  }
}
