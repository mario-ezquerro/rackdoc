import 'dart:async';
import 'dart:js_interop';
import 'package:web/web.dart' as web;
import 'image_file_picker.dart';

Future<PickedImageFile?> pickPlanImageFileImpl() =>
    _pickWebFile('.jpg,.jpeg,.png,.gif,.webp,image/jpeg,image/png,image/gif,image/webp');

Future<PickedImageFile?> pickExcelFileImpl() =>
    _pickWebFile('.xlsx,.xlsm,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');

Future<PickedImageFile?> _pickWebFile(String accept) async {
  final completer = Completer<PickedImageFile?>();
  final input = web.HTMLInputElement()
    ..type = 'file'
    ..accept = accept
    ..style.display = 'none';

  web.document.body?.append(input);

  input.addEventListener(
    'change',
    ((web.Event _) {
      final files = input.files;
      if (files == null || files.length == 0) {
        input.remove();
        if (!completer.isCompleted) completer.complete(null);
        return;
      }

      final file = files.item(0);
      if (file == null) {
        input.remove();
        if (!completer.isCompleted) completer.complete(null);
        return;
      }

      final reader = web.FileReader();
      reader.addEventListener(
        'loadend',
        ((web.Event _) {
          input.remove();
          if (!completer.isCompleted) {
            final buffer = (reader.result as JSArrayBuffer?)?.toDart;
            if (buffer != null) {
              completer.complete(
                PickedImageFile(
                  name: file.name,
                  bytes: buffer.asUint8List(),
                ),
              );
            } else {
              completer.complete(null);
            }
          }
        }).toJS,
      );

      reader.addEventListener(
        'error',
        ((web.Event _) {
          input.remove();
          if (!completer.isCompleted) completer.complete(null);
        }).toJS,
      );

      reader.readAsArrayBuffer(file);
    }).toJS,
  );

  input.click();
  return completer.future;
}
