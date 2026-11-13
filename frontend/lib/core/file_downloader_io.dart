import 'dart:typed_data';
import 'package:url_launcher/url_launcher.dart';

/// Implementación IO/escritorio de descarga de archivos en memoria.
Future<void> downloadBytesAsFileImpl({
  required Uint8List bytes,
  required String filename,
  required String mimeType,
}) async {
  final uri = Uri.dataFromBytes(bytes, mimeType: mimeType);
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}
