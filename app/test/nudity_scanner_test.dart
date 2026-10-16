import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:nova/services/nudity_scanner.dart';

/// Verifies the nudity scanner's pure-Dart contract against the model's
/// documented interface:
///   input  [1,224,224,3] float32, BGR, ImageNet-mean centered (B-104/G-117/R-123)
///   output [1,2] — index 0 = SFW, index 1 = NSFW
/// (Model structure verified by parsing the bundled assets/nsfw.tflite
/// flatbuffer: input tensor shape [1,224,224,3], output tensor shape [1,2].)
void main() {
  group('NudityScanner.preprocess', () {
    test('produces [1,224,224,3] float input', () {
      final image = img.Image(width: 100, height: 100);
      img.fill(image, color: img.ColorRgb8(10, 20, 30));
      final input = NudityScanner.preprocess(image);
      expect(input.length, 1);
      expect(input[0].length, 224);
      expect(input[0][0].length, 224);
      expect(input[0][0][0].length, 3);
      expect(input[0][0][0][0], isA<double>());
    });

    test('applies BGR mean-centering (B-104, G-117, R-123)', () {
      // Solid color image: every pixel identical, so the center pixel is exact.
      final image = img.Image(width: 300, height: 300);
      img.fill(image, color: img.ColorRgb8(23, 17, 4)); // r=23, g=17, b=4
      final input = NudityScanner.preprocess(image);
      final center = input[0][112][112];
      expect(center[0], closeTo(4 - 104, 1e-9)); // B
      expect(center[1], closeTo(17 - 117, 1e-9)); // G
      expect(center[2], closeTo(23 - 123, 1e-9)); // R
    });

    test('white pixel maps to known centered values', () {
      final image = img.Image(width: 300, height: 300);
      img.fill(image, color: img.ColorRgb8(255, 255, 255));
      final input = NudityScanner.preprocess(image);
      final p = input[0][0][0];
      expect(p[0], closeTo(151.0, 1e-9)); // 255-104
      expect(p[1], closeTo(138.0, 1e-9)); // 255-117
      expect(p[2], closeTo(132.0, 1e-9)); // 255-123
    });
  });

  group('NudityScanner.verdict', () {
    final s = NudityScanner();
    test('high-confidence score blocks', () {
      expect(s.verdict(0.85), ScanVerdict.block);
      expect(s.verdict(0.99), ScanVerdict.block);
    });
    test('borderline score quarantines', () {
      expect(s.verdict(0.60), ScanVerdict.quarantine);
      expect(s.verdict(0.849), ScanVerdict.quarantine);
    });
    test('low score passes', () {
      expect(s.verdict(0.0), ScanVerdict.pass);
      expect(s.verdict(0.599), ScanVerdict.pass);
    });
    test('unavailable scan is distinct from pass', () {
      expect(s.verdict(-1), ScanVerdict.unavailable);
    });
  });
}
