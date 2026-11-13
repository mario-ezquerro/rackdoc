import 'dart:typed_data';
import 'package:web/web.dart' as web;

/// Implementación Web (DOM `HTMLAnchorElement`) de descarga directa en navegador.
Future<void> downloadBytesAsFileImpl({
  required Uint8List bytes,
  required String filename,
  required String mimeType,
}) async {
  final dataUrl = Uri.dataFromBytes(bytes, mimeType: mimeType).toString();
  final anchor = web.HTMLAnchorElement()
    ..href = dataUrl
    ..download = filename
    ..style.display = 'none';
  web.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
}
