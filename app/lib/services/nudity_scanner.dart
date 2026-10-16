import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:fc_native_video_thumbnail/fc_native_video_thumbnail.dart';
import 'package:fc_native_video_thumbnail/fc_native_video_thumbnail_platform_interface.dart';

/// On-device nudity detector (strict, $0, private — nothing leaves the phone).
///
/// Model: nsfw.tflite (MobileNetV2-based binary NSFW classifier, 23MB),
/// bundled at assets/nsfw.tflite.
///   input:  [1,224,224,3] float32, BGR order, ImageNet-mean centered
///           (B-104, G-117, R-123) — resize to 256, center-crop 224.
///   output: [1,2] float32 — index 0 = SFW, index 1 = NSFW.
///   nsfwScore = output[0][1].
///
/// Tiered enforcement (tuned for recall; gray areas go to human review):
///   score >= 0.85  → BLOCK (upload refused; report filed for a strike)
///   0.60 – 0.85    → QUARANTINE (upload held for review; strike only if confirmed)
///   score < 0.60   → PASS
///
/// Honest limits: tuned for recall, so modest swimwear-adjacent content can
/// false-positive into quarantine — that's why borderline never auto-strikes.
/// Scans images + sampled video frames pre-upload. If the model fails to load,
/// scans return "unavailable" and uploads proceed (never brick the app).
class NudityScanner {
  static const double blockThreshold = 0.85;
  static const double quarantineThreshold = 0.60;

  Interpreter? _interpreter;
  bool _loading = false;

  Future<bool> get isAvailable async {
    if (_interpreter != null) return true;
    if (_loading) return false;
    _loading = true;
    try {
      _interpreter = await Interpreter.fromAsset('nsfw.tflite');
      return true;
    } catch (e) {
      debugPrint('NudityScanner: model load failed: $e');
      return false;
    } finally {
      _loading = false;
    }
  }

  /// Preprocess a decoded image into the model's [1,224,224,3] float32 input:
  /// resize to 256, center-crop 224, BGR order, ImageNet-mean centered.
  /// Pure Dart — unit-testable without the native TFLite library.
  static List<List<List<List<double>>>> preprocess(img.Image decoded) {
    final r256 = img.copyResize(decoded, width: 256, height: 256);
    final cropped = img.copyCrop(r256, x: 16, y: 16, width: 224, height: 224);
    return List.generate(
      1,
      (_) => List.generate(
        224,
        (y) => List.generate(224, (x) {
          final p = cropped.getPixel(x, y);
          return [p.b - 104.0, p.g - 117.0, p.r - 123.0];
        }),
      ),
    );
  }

  /// Score a single image. Returns nsfwScore 0..1, or -1 if unavailable.
  Future<double> scoreImage(Uint8List bytes) async {
    if (!await isAvailable) return -1;
    try {
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return -1;
      final input = preprocess(decoded);
      final output = List.generate(1, (_) => List.filled(2, 0.0));
      _interpreter!.run(input, output);
      final score = output[0][1].clamp(0.0, 1.0);
      return score;
    } catch (e) {
      debugPrint('NudityScanner: inference failed: $e');
      return -1;
    }
  }

  /// Score a local image file.
  Future<double> scoreFile(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      return await scoreImage(bytes);
    } catch (_) {
      return -1;
    }
  }

  /// Score sampled frames of a local video file. Returns the MAX frame score
  /// (strict: one bad frame flags the video), or -1 if unavailable.
  Future<double> scoreVideo(String videoPath) async {
    if (!await isAvailable) return -1;
    final plugin = FcNativeVideoThumbnail();
    var maxScore = 0.0;
    var gotFrame = false;
    // Sample across the timeline; failures (short videos) are skipped.
    for (final ms in [500, 3000, 8000, 15000, 30000]) {
      try {
        final thumb = await plugin.saveThumbnailToBytes(
          srcFile: videoPath,
          width: 256,
          height: 256,
          at: FcVideoThumbnailTime(ms, FcVideoThumbnailTimeUnit.milliseconds),
          quality: 70,
        );
        if (thumb == null || thumb.isEmpty) continue;
        gotFrame = true;
        final s = await scoreImage(thumb);
        if (s > maxScore) maxScore = s;
        if (maxScore >= blockThreshold) break; // early exit on clear block
      } catch (_) {
        continue;
      }
    }
    return gotFrame ? maxScore : -1;
  }

  ScanVerdict verdict(double score) {
    if (score < 0) return ScanVerdict.unavailable;
    if (score >= blockThreshold) return ScanVerdict.block;
    if (score >= quarantineThreshold) return ScanVerdict.quarantine;
    return ScanVerdict.pass;
  }

  void dispose() {
    _interpreter?.close();
    _interpreter = null;
  }
}

enum ScanVerdict { pass, quarantine, block, unavailable }
