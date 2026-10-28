import 'package:file_picker/file_picker.dart';
import 'image_file_picker.dart';

Future<PickedImageFile?> pickPlanImageFileImpl() async {
  final files = await FilePicker.pickFiles(
    type: FileType.custom,
    allowedExtensions: const ['jpg', 'jpeg', 'png', 'gif', 'webp'],
  );
  if (files.isEmpty) return null;
  final picked = files.first;
  final bytes = await picked.readAsBytes();
  return PickedImageFile(name: picked.name, bytes: bytes);
}
