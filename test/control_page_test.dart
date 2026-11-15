import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ptz_control/controller.dart';
import 'package:ptz_control/main.dart';
import 'package:ptz_control/models/camera.dart';
import 'package:ptz_control/models/camera_preset.dart';

class _UiController extends PtzController {
  int stopCount = 0;
  final commands = <List<int>>[];
  final recalled = <int>[];
  @override
  bool get canControl => true;
  @override
  Future<void> initialize() async {
    cameras = [
      const Camera(id: 'test', name: 'Stage', host: '192.0.2.1', port: 1259),
    ];
    selected = cameras.first;
    loading = false;
    pan = 1200;
    tilt = -800;
    zoom = 16384;
    exposureMode = 0x0a;
    whiteBalanceMode = 2;
    imageValues.addAll({0x4b: 17, 0x4a: 22, 0x4c: 4, 0x43: 128, 0x44: 129});
    connection = CameraConnection.connected;
    notifyListeners();
  }

  @override
  Future<void> stopAll() async {
    stopCount++;
  }

  @override
  Future<void> command(String description, List<int> bytes) async {
    commands.add(List.of(bytes));
  }

  @override
  Future<bool> recallPreset(int slot) async {
    recalled.add(slot);
    return true;
  }

  @override
  Future<bool> savePreset(int slot, String name) async {
    selected = selected!.withPresets([CameraPreset(slot: slot, name: name)]);
    cameras = [selected!];
    notifyListeners();
    return true;
  }
}

void main() {
  testWidgets('Image shows raw values and one-push requires confirmation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = _UiController();
    addTearDown(c.dispose);
    await tester.pumpWidget(MyApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Image'));
    await tester.pumpAndSettle();
    for (final row in [
      (11, '17', 'Aperture / iris: Open'),
      (10, '22', 'Shutter speed: Faster'),
      (12, '4', 'Gain: Higher'),
      (3, '128', 'Red gain: Higher'),
      (4, '129', 'Blue gain: Higher'),
    ]) {
      final value = find.byKey(ValueKey('image-value-${row.$1}'));
      await tester.ensureVisible(value);
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(value).data, row.$2);
      expect(
        tester.getRect(value).left,
        greaterThan(tester.getRect(find.byTooltip(row.$3)).right),
      );
    }
    c.imageValues[0x44] = null;
    c.notifyListeners();
    await tester.pump();
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('image-value-4'))).data,
      '—',
    );

    final trigger = find.text('Trigger one-push balance');
    Future<void> openConfirmation() async {
      await tester.ensureVisible(trigger);
      await tester.tap(trigger);
      await tester.pumpAndSettle();
      expect(find.text('Reset white balance with One Push?'), findsOneWidget);
      expect(c.commands, isEmpty);
    }

    await openConfirmation();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(c.commands, isEmpty);
    await openConfirmation();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Reset white balance with One Push?'), findsNothing);
    expect(c.commands, isEmpty);
    await openConfirmation();
    await tester.tap(find.text('Yes'));
    await tester.pumpAndSettle();
    expect(c.commands, [
      [0x81, 1, 4, 0x10, 5, 0xff],
    ]);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'compact page has inline status, stop center, sync, and all nine visible presets',
    (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = _UiController();
      addTearDown(c.dispose);
      await tester.pumpWidget(MyApp(controller: c));
      await tester.pumpAndSettle();
      for (final removed in [
        'Take control',
        'CAMERA WORKSPACE',
        'PAN & TILT',
        'LENS',
        'Position in camera-native units',
        'Hold to move',
        'Stop all movement',
      ]) {
        expect(find.text(removed), findsNothing);
      }
      expect(find.text('PAN: 1200'), findsOneWidget);
      expect(find.text('TILT: -800'), findsOneWidget);
      expect(find.text('ZOOM: 16384'), findsOneWidget);
      final exposureStatus = tester.getRect(
        find.text('EXPOSURE: Shutter priority'),
      );
      final balanceStatus = tester.getRect(find.text('WHITE BALANCE: Outdoor'));
      expect(
        exposureStatus.top,
        greaterThan(tester.getRect(find.text('PAN: 1200')).bottom),
      );
      expect(balanceStatus.center.dy, closeTo(exposureStatus.center.dy, .1));
      expect(balanceStatus.left, greaterThan(exposureStatus.right));
      expect(find.text('SPEED'), findsOneWidget);
      final movement = tester.getRect(find.byKey(const Key('movement-grid')));
      final speeds = tester.getRect(find.byKey(const Key('speed-controls')));
      final lens = tester.getRect(find.byKey(const Key('lens-controls')));
      expect(movement.top, closeTo(speeds.top, .1));
      expect(movement.bottom, closeTo(speeds.bottom, .1));
      expect(lens.top, closeTo(speeds.top, .1));
      expect(lens.bottom, closeTo(speeds.bottom, .1));
      final speedFields = find.byType(DropdownButtonFormField<int>);
      final firstBorder = tester.getRect(
        find.descendant(
          of: speedFields.first,
          matching: find.byType(InputDecorator),
        ),
      );
      final lastBorder = tester.getRect(
        find.descendant(
          of: speedFields.last,
          matching: find.byType(InputDecorator),
        ),
      );
      expect(firstBorder.top, closeTo(movement.top, .1));
      expect(lastBorder.bottom, closeTo(movement.bottom, .1));
      expect(
        lens.right,
        closeTo(
          tester.getRect(find.byKey(const ValueKey('preset-3'))).right,
          .1,
        ),
      );
      expect(speeds.left - movement.right, greaterThan(12));
      final speedHeading = tester.getRect(find.text('SPEED'));
      final syncLabel = tester.getRect(find.text('Sync pan / tilt'));
      expect(syncLabel.left, greaterThan(speedHeading.right));
      expect((syncLabel.center.dy - speedHeading.center.dy).abs(), lessThan(3));
      final syncCheckbox = find.descendant(
        of: find
            .ancestor(
              of: find.text('Sync pan / tilt'),
              matching: find.byType(InkWell),
            )
            .first,
        matching: find.byType(Checkbox),
      );
      expect(tester.getTopLeft(syncCheckbox).dx, closeTo(lens.left, .1));
      final saveOption = tester.getRect(find.text('Save preset'));
      final apertureOption = tester.getRect(
        find.text('Save aperture with preset'),
      );
      final presetEdge = tester.getRect(find.byKey(const ValueKey('preset-9')));
      expect(saveOption.top, greaterThanOrEqualTo(presetEdge.bottom));
      expect(apertureOption.left, greaterThan(saveOption.right));
      expect(apertureOption.center.dy, closeTo(saveOption.center.dy, .1));
      expect(apertureOption.right, closeTo(presetEdge.right, .1));
      final apertureCheckbox = find.descendant(
        of: find
            .ancestor(
              of: find.text('Save aperture with preset'),
              matching: find.byType(InkWell),
            )
            .first,
        matching: find.byType(Checkbox),
      );
      expect(tester.getTopLeft(apertureCheckbox).dx, closeTo(200, .1));
      expect(tester.widget<Checkbox>(apertureCheckbox).onChanged, isNull);
      await tester.tap(find.text('Save aperture with preset'));
      await tester.pump();
      expect(tester.widget<Checkbox>(apertureCheckbox).value, false);
      expect(
        tester.widget<Text>(find.text('Save aperture with preset')).textAlign,
        TextAlign.start,
      );
      final navTop = tester.getTopLeft(find.byType(NavigationBar)).dy;
      expect(
        tester.getBottomRight(find.text('Save preset')).dy,
        lessThanOrEqualTo(navTop),
      );
      for (var slot = 1; slot <= 9; slot++) {
        expect(find.byKey(ValueKey('preset-$slot')), findsOneWidget);
      }
      await tester.tap(find.byKey(const ValueKey('preset-9')));
      expect(c.recalled, [9]);
      final selector = tester.getRect(
        find.byType(DropdownButtonFormField<String>),
      );
      final refresh = tester.getRect(find.byTooltip('Refresh camera status'));
      expect(refresh.left, greaterThan(selector.right));
      expect((refresh.center.dy - selector.center.dy).abs(), lessThan(3));
      await tester.tap(find.byTooltip('Stop all movement'));
      await tester.pump();
      expect(c.stopCount, 1);
      await tester.tap(find.text('Sync pan / tilt'));
      await tester.pumpAndSettle();
      c.setSpeed('Tilt', 17);
      await tester.pumpAndSettle();
      expect([c.panSpeed, c.tiltSpeed], [17, 17]);
      await tester.tap(find.text('Save preset'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('preset-2')));
      await tester.pumpAndSettle();
      expect(find.text('Save preset 2'), findsOneWidget);
      const manualMessage =
          'Manual exposure mode enabled. Exposure and image settings are also saved.';
      expect(find.text(manualMessage), findsNothing);
      c.exposureMode = 3;
      c.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text(manualMessage), findsOneWidget);
      expect(
        tester.getRect(find.text(manualMessage)).bottom,
        lessThan(tester.getRect(find.byKey(const Key('preset-name'))).top),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Save preset 2'), findsNothing);
      expect(c.preset(2), isNull);
      await tester.tap(find.byKey(const ValueKey('preset-2')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('preset-name')),
        '2 Podium\nExtra Wide',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(c.preset(2)?.name, '2 Podium\nExtra Wide');
      expect(find.text('2 Podium\nExtra Wide'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
