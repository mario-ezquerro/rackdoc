import 'dart:typed_data';

import 'file_downloader_io.dart'
    if (dart.library.js_interop) 'file_downloader_web.dart';

Future<void> downloadBytesAsFile({
  required Uint8List bytes,
  required String filename,
  required String mimeType,
}) => downloadBytesAsFileImpl(
  bytes: bytes,
  filename: filename,
  mimeType: mimeType,
);
