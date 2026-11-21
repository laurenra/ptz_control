import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import '../models/camera_settings.dart';

Future<Uri?> saveCameraSettings(CameraSettings settings) {
  final exportedAt = DateTime.now().toUtc();
  final timestamp = exportedAt.toIso8601String().replaceAll(':', '-');
  return FilePicker.saveFile(
    dialogTitle: 'Export camera settings',
    fileName: 'ptz-cameras-$timestamp.json',
    mimeType: 'application/json',
    bytes: Uint8List.fromList(
      utf8.encode(settings.encode(exportedAt: exportedAt)),
    ),
  );
}

Future<CameraSettings?> pickCameraSettings() async {
  final file = await FilePicker.pickFile(
    dialogTitle: 'Import camera settings',
    type: FileType.custom,
    allowedExtensions: ['json'],
  );
  if (file == null) return null;
  const maxBytes = 1024 * 1024;
  const tooLarge = FormatException(
    'The settings file is too large (maximum 1 MB).',
  );
  if ((await file.length() ?? 0) > maxBytes) throw tooLarge;
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in file.readAsByteStream()) {
    if (bytes.length + chunk.length > maxBytes) throw tooLarge;
    bytes.add(chunk);
  }
  final String source;
  try {
    source = utf8.decode(bytes.takeBytes());
  } on FormatException {
    throw const FormatException('The settings file must use UTF-8 text.');
  }
  return CameraSettings.decode(source);
}
