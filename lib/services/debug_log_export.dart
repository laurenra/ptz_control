import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import 'visca_client.dart';
import 'visca_protocol.dart';

/// Exports the supplied console snapshot in its displayed order (newest first).
Future<Uri?> saveDebugLog(List<CommandLog> logs) {
  final exportedAt = DateTime.now().toUtc();
  final text = StringBuffer()
    ..writeln('PTZ Control - Debug log')
    ..writeln('Exported: ${exportedAt.toIso8601String()}')
    ..writeln('Events: ${logs.length} (newest first; timestamps in UTC)')
    ..writeln();
  for (final log in logs) {
    text
      ..writeln(
        '${log.time.toUtc().toIso8601String()}  ${log.direction}  ${log.endpoint}',
      )
      ..writeln(log.description);
    if (log.bytes.isNotEmpty) text.writeln(Visca.hex(log.bytes));
    text.writeln();
  }
  final timestamp = exportedAt
      .toIso8601String()
      .replaceFirst(RegExp(r'\.\d+Z$'), 'Z')
      .replaceAll(':', '-');
  return FilePicker.saveFile(
    dialogTitle: 'Save debug log',
    fileName: 'ptz-debug-$timestamp.txt',
    mimeType: 'text/plain',
    bytes: Uint8List.fromList(utf8.encode(text.toString())),
  );
}
