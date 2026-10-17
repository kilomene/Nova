/// TikTok-style compact number formatting.
/// - Under 10,000: full number with thousands separators ("9,999")
/// - 10,000+: compact ("10k", "10.5k", "100k", "1M", "1.5M")
String formatCount(num n) {
  if (n < 0) return '0';
  if (n < 10000) {
    return _withCommas(n.round());
  }
  if (n < 1000000) {
    return _compact(n / 1000, 'k');
  }
  if (n < 1000000000) {
    return _compact(n / 1000000, 'M');
  }
  return _compact(n / 1000000000, 'B');
}

String _withCommas(int n) {
  final s = n.toString();
  final buf = StringBuffer();
  int count = 0;
  for (int i = s.length - 1; i >= 0; i--) {
    buf.write(s[i]);
    count++;
    if (count % 3 == 0 && i != 0) buf.write(',');
  }
  return buf.toString().split('').reversed.join();
}

String _compact(double v, String suffix) {
  // One decimal only when it adds information (10.5k, not 10.0k).
  final rounded1 = (v * 10).round() / 10;
  final text = (rounded1 == rounded1.roundToDouble())
      ? '${rounded1.round()}'
      : '$rounded1';
  return '$text$suffix';
}
