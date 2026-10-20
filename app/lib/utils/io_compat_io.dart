import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';

Future<Uint8List> readPathBytes(String path) => File(path).readAsBytes();

Future<bool> pathExists(String path) => File(path).exists();

Future<String> writeTempBytes(String name, Uint8List bytes) async {
  final f = File('${Directory.systemTemp.path}/$name');
  await f.writeAsBytes(bytes);
  return f.path;
}

VideoPlayerController fileVideoController(String path) =>
    VideoPlayerController.file(File(path));

ImageProvider pathImage(String path) => FileImage(File(path));

Future<void> saveUrlToTemp(String url, String fileName) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(Uri.parse(url));
    final resp = await req.close();
    if (resp.statusCode != 200) throw Exception('HTTP ${resp.statusCode}');
    final file = File('${Directory.systemTemp.path}/$fileName');
    final sink = file.openWrite();
    await resp.pipe(sink);
    await sink.close();
  } finally {
    client.close();
  }
}

/// Names of local network interfaces (for the client-side VPN check).
Future<List<String>> networkInterfaceNames() async {
  final ifs = await NetworkInterface.list();
  return ifs.map((i) => i.name).toList();
}
