/// Platform file helpers. On IO platforms these use dart:io; on web,
/// picker "paths" are blob: URLs and temp files are in-memory handles.
export 'io_compat_stub.dart' if (dart.library.io) 'io_compat_io.dart';
