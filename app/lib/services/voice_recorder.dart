import 'dart:async';
import 'package:flutter/services.dart';

/// Native voice recorder via Android MediaRecorder (no `record` package needed).
class VoiceRecorder {
  static const _channel = MethodChannel('com.nova.app/voice_recorder');

  /// Start recording. Returns the output file path, or throws.
  static Future<String> start() async {
    final path = await _channel.invokeMethod<String>('startRecording');
    if (path == null || path.isEmpty) throw Exception('Recording failed to start');
    return path;
  }

  /// Stop recording. Returns the recorded file path.
  static Future<String?> stop() async {
    return await _channel.invokeMethod<String>('stopRecording');
  }

  /// Whether currently recording.
  static Future<bool> isRecording() async {
    return await _channel.invokeMethod<bool>('isRecording') ?? false;
  }
}
