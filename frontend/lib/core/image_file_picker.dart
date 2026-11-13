import 'dart:typed_data';
import 'image_file_picker_io.dart'
    if (dart.library.js_interop) 'image_file_picker_web.dart';

/// Contenedor en memoria de un fichero de imagen o libro Excel seleccionado por el usuario.
class PickedImageFile {
  final String name;
  final Uint8List bytes;

  PickedImageFile({required this.name, required this.bytes});
}

/// Abre el selector nativo/web para elegir una imagen de plano (`JPG`, `PNG`, `GIF`, `WEBP`).
Future<PickedImageFile?> pickPlanImageFile() => pickPlanImageFileImpl();

/// Abre el selector nativo/web para elegir un libro Excel (`.xlsx`, `.xlsm`).
Future<PickedImageFile?> pickExcelFile() => pickExcelFileImpl();
