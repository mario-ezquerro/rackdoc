import 'dart:typed_data';
import 'image_file_picker_io.dart'
    if (dart.library.js_interop) 'image_file_picker_web.dart';

class PickedImageFile {
  final String name;
  final Uint8List bytes;

  PickedImageFile({required this.name, required this.bytes});
}

Future<PickedImageFile?> pickPlanImageFile() => pickPlanImageFileImpl();
