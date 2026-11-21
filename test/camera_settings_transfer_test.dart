import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ptz_control/controller.dart';
import 'package:ptz_control/main.dart';
import 'package:ptz_control/models/camera_settings.dart';
import 'package:ptz_control/services/camera_settings_transfer.dart';

import 'camera_settings_test.dart' show settingsCameras, settingsCameraInfo;
import 'visca_client_test.dart' show MemoryStore;

final class _SettingsFile extends PlatformFile {
  _SettingsFile(String text, {this.reportedSize})
    : data = Uint8List.fromList(utf8.encode(text));
  final Uint8List data;
  final int? reportedSize;
  @override
  String get name => 'cameras.json';
  @override
  Uri get uri => Uri.parse('content://settings/cameras.json');
  @override
  Never get xFile => throw UnimplementedError();
  @override
  int? lengthSync() => reportedSize;
  @override
  Future<int?> length() async => reportedSize;
  @override
  Future<Uint8List> readAsBytes() async => data;
  @override
  Stream<Uint8List> readAsByteStream() async* {
    final split = data.length ~/ 2;
    yield Uint8List.sublistView(data, 0, split);
    yield Uint8List.sublistView(data, split);
  }
}

class _SettingsPicker extends FilePickerPlatform {
  var saveResponse = Completer<Uri?>();
  var pickResponse = Completer<PlatformFile?>();
  Uint8List? savedBytes;
  String? savedName, savedMimeType;
  List<String>? pickedExtensions;
  FileType? pickedType;

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
    savedBytes = Uint8List.fromList(bytes);
    savedName = fileName;
    savedMimeType = mimeType;
    return saveResponse.future;
  }

  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) {
    pickedType = type;
    pickedExtensions = allowedExtensions;
    return pickResponse.future;
  }
}

class _TransferController extends PtzController {
  _TransferController.withStore(this.store) : super(store: store);
  final MemoryStore store;
  @override
  Future<void> initialize() async {
    await setPaused(true);
    cameras = List.of(store.cameras);
    selected = cameras.first;
    loading = false;
    notifyListeners();
  }
}

void main() {
  late _SettingsPicker picker;
  setUp(() {
    final previous = FilePickerPlatform.instance;
    picker = _SettingsPicker();
    FilePickerPlatform.instance = picker;
    addTearDown(() => FilePickerPlatform.instance = previous);
  });

  Future<_TransferController> openCameras(WidgetTester tester) async {
    picker = _SettingsPicker();
    FilePickerPlatform.instance = picker;
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = _TransferController.withStore(
      MemoryStore([settingsCameras.last]),
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(MyApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cameras'));
    await tester.pumpAndSettle();
    return c;
  }

  testWidgets(
    'export uses JSON and a fixed snapshot; cancel and errors are recoverable',
    (tester) async {
      final c = await openCameras(tester);
      await c.saveCamera(settingsCameras.last.withInfo(settingsCameraInfo));
      await tester.pumpAndSettle();
      final export = find.widgetWithText(OutlinedButton, 'Export settings');
      final import = find.widgetWithText(OutlinedButton, 'Import settings');
      await tester.tap(export);
      await tester.pumpAndSettle();
      expect(tester.widget<OutlinedButton>(export).onPressed, isNull);
      expect(tester.widget<OutlinedButton>(import).onPressed, isNull);
      expect(picker.savedName, startsWith('ptz-cameras-'));
      expect(picker.savedName, endsWith('.json'));
      expect(picker.savedName, isNot(contains(':')));
      expect(picker.savedMimeType, 'application/json');
      final source = utf8.decode(picker.savedBytes!);
      expect(CameraSettings.decode(source).cameras.single.id, 1);
      expect(
        jsonDecode(source)['cameras'][0]['info'],
        settingsCameraInfo.toJson(),
      );
      await c.saveCamera(settingsCameras.first);
      await tester.pump();
      expect(utf8.decode(picker.savedBytes!), source);
      picker.saveResponse.complete(null);
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.widget<OutlinedButton>(export).onPressed, isNotNull);
      picker.saveResponse = Completer<Uri?>();
      await tester.tap(export);
      await tester.pumpAndSettle();
      picker.saveResponse.completeError(StateError('Disk full'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Could not export camera settings:'),
        findsOneWidget,
      );
      picker.saveResponse = Completer<Uri?>();
      await tester.tap(export);
      await tester.pumpAndSettle();
      picker.saveResponse.complete(Uri.file('/tmp/cameras.json'));
      await tester.pumpAndSettle();
      expect(find.text('Camera settings exported.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'import validates, previews and requires confirmation before replacing',
    (tester) async {
      final c = await openCameras(tester);
      final import = find.widgetWithText(OutlinedButton, 'Import settings');
      await tester.tap(import);
      await tester.pumpAndSettle();
      picker.pickResponse.complete(null);
      await tester.pumpAndSettle();
      expect(c.cameras, [settingsCameras.last]);
      expect(find.byType(AlertDialog), findsNothing);

      picker.pickResponse = Completer<PlatformFile?>();
      await tester.tap(import);
      await tester.pumpAndSettle();
      expect(picker.pickedType, FileType.custom);
      expect(picker.pickedExtensions, ['json']);
      picker.pickResponse.complete(_SettingsFile('{'));
      await tester.pumpAndSettle();
      expect(find.text('The selected file is not valid JSON.'), findsOneWidget);
      expect(c.cameras, [settingsCameras.last]);
      final source = CameraSettings(
        cameras: settingsCameras,
        nextId: 10,
      ).encode();
      for (final confirm in [false, true]) {
        picker.pickResponse = Completer<PlatformFile?>();
        await tester.tap(import);
        await tester.pumpAndSettle();
        picker.pickResponse.complete(_SettingsFile(source));
        await tester.pumpAndSettle();
        expect(find.text('Import camera settings?'), findsOneWidget);
        expect(find.text('3. Stage – 三'), findsOneWidget);
        expect(
          find.textContaining('Replace your 1 saved cameras'),
          findsOneWidget,
        );
        expect(c.store.cameras, [settingsCameras.last]);
        await tester.tap(find.text(confirm ? 'Replace cameras' : 'Cancel'));
        await tester.pumpAndSettle();
        if (!confirm) expect(c.cameras, [settingsCameras.last]);
      }
      expect(
        c.cameras.map((camera) => camera.toJson()),
        settingsCameras.map((camera) => camera.toJson()),
      );
      expect(c.selected!.id, 1);
      expect(c.nextCameraId, 10);
      expect(find.text('Camera settings imported.'), findsOneWidget);
      expect(c.store.cameras.first.info!.toJson(), settingsCameraInfo.toJson());
      await tester.tap(find.byTooltip('Edit Stage – 三'));
      await tester.pumpAndSettle();
      for (final entry in {
        'manufacturer': 'Example Camera Co',
        'model': 'PTZ 20X',
        'serial': 'SN-123',
        'mac': '02:AA:BB:CC:DD:01',
      }.entries) {
        expect(
          tester
              .widget<Text>(find.byKey(ValueKey('camera-info-${entry.key}')))
              .data,
          entry.value,
        );
      }
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(320, 640);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test(
    'oversized settings are rejected before reading or while streaming',
    () async {
      for (final file in [
        _SettingsFile('{}', reportedSize: 1024 * 1024 + 1),
        _SettingsFile(' ' * (1024 * 1024 + 1)),
      ]) {
        picker.pickResponse = Completer<PlatformFile?>()..complete(file);
        await expectLater(pickCameraSettings(), throwsFormatException);
      }
    },
  );
}
