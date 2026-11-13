import 'dart:typed_data';

import 'file_downloader_io.dart'
    if (dart.library.js_interop) 'file_downloader_web.dart';

/// Descarga un bloque de bytes en el cliente (ancla HTML5 en Web o URI de datos en escritorio).
Future<void> downloadBytesAsFile({
  required Uint8List bytes,
  required String filename,
  required String mimeType,
}) => downloadBytesAsFileImpl(
  bytes: bytes,
  filename: filename,
  mimeType: mimeType,
);
