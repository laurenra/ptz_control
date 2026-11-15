import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ptz_control/controller.dart';
import 'package:ptz_control/main.dart';
import 'package:ptz_control/services/visca_client.dart';

class _DebugController extends PtzController {
  @override
  Future<void> initialize() async {
    loading = false;
    debug = true;
    notifyListeners();
  }
}

class _SavePicker extends FilePickerPlatform {
  var calls = 0;
  String? suggestedName;
  String? savedMimeType;
  Uint8List? savedBytes;
  var response = Completer<Uri?>();

  @override
  Future<Uri?> saveFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    String? dialogTitle,
    String? initialDirectory,
    Function(FilePickerStatus)? onFileSaving,
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) {
    calls++;
    suggestedName = fileName;
    savedMimeType = mimeType;
    savedBytes = Uint8List.fromList(bytes);
    return response.future;
  }
}

void main() {
  testWidgets(
    'debug save exports a stable snapshot and handles cancel, error, and success',
    (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final originalPicker = FilePickerPlatform.instance;
      final picker = _SavePicker();
      FilePickerPlatform.instance = picker;
      addTearDown(() => FilePickerPlatform.instance = originalPicker);
      final c = _DebugController();
      addTearDown(c.dispose);
      await tester.pumpWidget(MyApp(controller: c));
      await tester.pumpAndSettle();
      final save = find.widgetWithIcon(IconButton, Icons.save_alt_outlined);
      expect(find.byTooltip('Save debug log'), findsOneWidget);
      expect(tester.widget<IconButton>(save).onPressed, isNull);

      final tx = CommandLog('TX', 'Read aperture', '192.168.1.192:52381', [
        0x81,
        9,
        4,
        0x4b,
        255,
      ]);
      final rx = CommandLog('RX', 'Camera reply', '192.168.1.192:52381', [
        0x90,
        0x50,
        0,
        0,
        0,
        9,
        255,
      ]);
      final error = CommandLog(
        '!',
        'No reply: Read gain',
        '192.168.1.193:52381',
        [],
      );
      c.logs.addAll([error, rx, tx]);
      c.notifyListeners();
      await tester.pump();
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(picker.calls, 1);
      expect(tester.widget<IconButton>(save).onPressed, isNull);
      expect(picker.suggestedName, startsWith('ptz-debug-'));
      expect(picker.suggestedName, endsWith('.txt'));
      expect(picker.suggestedName, isNot(contains(':')));
      expect(picker.savedMimeType, 'text/plain');
      final text = utf8.decode(picker.savedBytes!);
      expect(text, contains('Events: 3'));
      expect(
        text,
        contains(
          '${tx.time.toUtc().toIso8601String()}  TX  192.168.1.192:52381',
        ),
      );
      expect(text, contains('Read aperture\n81 09 04 4B FF'));
      expect(text, contains('Camera reply\n90 50 00 00 00 09 FF'));
      expect(text, contains('192.168.1.193:52381\nNo reply: Read gain'));
      expect(text.indexOf('No reply:'), lessThan(text.indexOf('Camera reply')));
      expect(
        text.indexOf('Camera reply'),
        lessThan(text.indexOf('Read aperture')),
      );

      // Results may change while the native picker is open; exported bytes stay fixed.
      c.logs
        ..clear()
        ..add(
          CommandLog('TX', 'New polling result', '192.168.1.192:52381', [
            0x81,
            9,
            4,
            0x35,
            255,
          ]),
        );
      c.notifyListeners();
      await tester.pump();
      expect(utf8.decode(picker.savedBytes!), text);
      picker.response.complete(null);
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
      expect(c.logs.single.description, 'New polling result');
      expect(tester.widget<IconButton>(save).onPressed, isNotNull);

      picker.response = Completer<Uri?>();
      await tester.tap(save);
      await tester.pumpAndSettle();
      picker.response.completeError(StateError('Disk full'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Could not save debug log:'), findsOneWidget);
      expect(c.logs, hasLength(1));
      expect(tester.widget<IconButton>(save).onPressed, isNotNull);

      picker.response = Completer<Uri?>();
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(utf8.decode(picker.savedBytes!), contains('New polling result'));
      picker.response.complete(Uri.file('/tmp/ptz-debug.txt'));
      await tester.pumpAndSettle();
      expect(find.text('Debug log saved.'), findsOneWidget);
      expect(picker.calls, 3);
      await tester.tap(find.byTooltip('Clear command log'));
      await tester.pump();
      expect(c.logs, isEmpty);
      expect(tester.widget<IconButton>(save).onPressed, isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
