import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

/// Web stand-ins for the dart:io helpers. Temp "files" live in this
/// in-memory registry keyed by name; picker paths are blob: URLs that
/// can be fetched back with a plain GET.
final _mem = <String, Uint8List>{};

Future<Uint8List> readPathBytes(String path) async {
  final m = _mem[path];
  if (m != null) return m;
  final r = await http.get(Uri.parse(path));
  if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
  return r.bodyBytes;
}

Future<bool> pathExists(String path) async => true;

Future<String> writeTempBytes(String name, Uint8List bytes) async {
  _mem[name] = bytes;
  return name;
}

VideoPlayerController fileVideoController(String path) =>
    VideoPlayerController.networkUrl(Uri.parse(path));

ImageProvider pathImage(String path) => NetworkImage(path);

Future<void> saveUrlToTemp(String url, String fileName) async {
  // On web, "download" hands the file to the browser.
  await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
}

/// Web has no interface enumeration; the backend's egress-IP checks
/// remain the VPN enforcement layer there.
Future<List<String>> networkInterfaceNames() async => const [];
