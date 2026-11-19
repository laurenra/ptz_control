import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ptz_control/controller.dart';
import 'package:ptz_control/main.dart';
import 'package:ptz_control/models/camera.dart';
import 'package:ptz_control/models/camera_preset.dart';
import 'package:ptz_control/widgets/focus_depth_icon.dart';
import 'package:ptz_control/widgets/hold_button.dart';

class _UiController extends PtzController {
  int stopCount = 0;
  final commands = <List<int>>[];
  final recalled = <int>[];
  int imageRefreshes = 0;
  int controlRefreshes = 0;
  int fullRefreshes = 0;
  int presetRefreshes = 0;
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
    if (bytes.length == 6 && bytes[3] == 0x38) {
      autofocus = bytes[4] == 2;
      notifyListeners();
    }
  }

  @override
  Future<bool> recallPreset(int slot) async {
    recalled.add(slot);
    return true;
  }

  @override
  Future<void> refreshImageSettings() async {
    imageRefreshes++;
  }

  @override
  Future<void> refreshControlStatus() async {
    controlRefreshes++;
  }

  @override
  Future<void> refresh() async {
    fullRefreshes++;
  }

  @override
  Future<void> refreshPresetSettings() async {
    presetRefreshes++;
    notifyListeners();
  }

  @override
  Future<bool> savePreset(int slot, String name) async {
    selected = selected!.withPresets([CameraPreset(slot: slot, name: name)]);
    cameras = [selected!];
    notifyListeners();
    return true;
  }
}

class _LifecycleUiController extends _UiController {
  int initializations = 0;
  final pauses = <bool>[];

  @override
  Future<void> initialize() async {
    initializations++;
    await super.initialize();
  }

  @override
  Future<void> setPaused(bool paused) async {
    pauses.add(paused);
  }
}

class _MovementUiController extends _UiController {
  Object? _owner;
  int movementStops = 0;
  final directions = <(int, int)>[];

  @override
  bool get moving => _owner != null;
  @override
  bool motionOwnedBy(Object owner) => _owner == owner;
  @override
  bool startPanTilt(
    String description,
    int horizontal,
    int vertical, {
    Object? owner,
  }) {
    if (moving && !moveUntilStopped) return false;
    _owner = owner ?? description;
    directions.add((horizontal, vertical));
    notifyListeners();
    return true;
  }

  @override
  Future<void> endMotion({Object? owner}) async {
    if (_owner == null || owner != null && owner != _owner) return;
    _owner = null;
    movementStops++;
    notifyListeners();
  }

  @override
  Future<void> stopAll() async {
    stopCount++;
    await endMotion();
  }
}

void main() {
  testWidgets(
    'app startup and lifecycle events reach the shared controller on any page',
    (tester) async {
      final c = _LifecycleUiController();
      addTearDown(c.dispose);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(MyApp(controller: c));
      await tester.pumpAndSettle();
      expect(c.initializations, 1);

      // Lifecycle handling belongs to the shell, even with Image selected.
      await tester.tap(find.text('Image'));
      await tester.pumpAndSettle();
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(c.pauses, [true, true, true, true, true, false]);
      expect(c.initializations, 1);
      expect(find.text('Image settings'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());

      // Disposing the shell also removes its lifecycle observer.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(c.pauses, hasLength(6));
    },
  );

  testWidgets('Control iris buttons follow exposure mode and show raw values', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = _MovementUiController();
    addTearDown(c.dispose);
    await tester.pumpWidget(MyApp(controller: c));
    await tester.pumpAndSettle();
    final close = find.byTooltip('Aperture / iris: Close');
    final open = find.byTooltip('Aperture / iris: Open');
    final value = find.byKey(const ValueKey('image-value-11'));
    IconButton button(Finder tooltip) => tester.widget<IconButton>(
      find.ancestor(of: tooltip, matching: find.byType(IconButton)).first,
    );
    final label = tester.getRect(find.text('Aperture / iris'));
    final focus = tester.getRect(find.byKey(const ValueKey('Focus-3')));
    expect(label.top, greaterThan(focus.bottom));
    expect(label.left, closeTo(focus.left, .1));
    expect(tester.getRect(close).left, greaterThan(label.right));
    expect(
      tester.getRect(open).left,
      greaterThan(tester.getRect(close).right - 1),
    );
    expect(tester.getRect(value).left, greaterThan(tester.getRect(open).right));
    expect(tester.widget<Text>(value).data, '17');

    for (final mode in [0, 0x0a, null, 0x7f, 3, 0x0b]) {
      c.exposureMode = mode;
      c.notifyListeners();
      await tester.pump();
      final enabled = mode == 3 || mode == 0x0b;
      expect(button(close).onPressed != null, enabled);
      expect(button(open).onPressed != null, enabled);
      if (enabled) {
        await tester.tap(close);
        await tester.tap(open);
      }
    }
    expect(c.commands, [
      [0x81, 1, 4, 0x0b, 3, 0xff],
      [0x81, 1, 4, 0x0b, 2, 0xff],
      [0x81, 1, 4, 0x0b, 3, 0xff],
      [0x81, 1, 4, 0x0b, 2, 0xff],
    ]);
    c.imageValues[0x4b] = 9;
    c.notifyListeners();
    await tester.pump();
    expect(tester.widget<Text>(value).data, '9');
    c.imageValues[0x4b] = null;
    c.startPanTilt('Right', 2, 3);
    await tester.pump();
    expect(tester.widget<Text>(value).data, '—');
    expect(button(open).onPressed, isNull);
    expect(button(close).onPressed, isNull);
    await c.endMotion();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Autofocus switches mode and disables manual focus controls', (
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

    final option = find.text('Autofocus');
    final focusSpeed = find.byWidgetPredicate(
      (widget) =>
          widget is DropdownButtonFormField<int> &&
          widget.decoration.labelText == 'Focus',
    );
    final focusButtons = find.byWidgetPredicate(
      (widget) => widget is HoldButton && widget.label.startsWith('Focus'),
    );
    void expectManualControls(bool enabled) {
      expect(
        tester.widget<DropdownButtonFormField<int>>(focusSpeed).onChanged,
        enabled ? isNotNull : isNull,
      );
      expect(
        tester
            .widgetList<HoldButton>(focusButtons)
            .every((button) => button.enabled == enabled),
        true,
      );
    }

    expect(
      tester.getRect(option).bottom,
      lessThanOrEqualTo(tester.getRect(focusSpeed).top),
    );
    // A missing focus-mode reply must not enable manual focus.
    expectManualControls(false);
    c.autofocus = false;
    c.notifyListeners();
    await tester.pumpAndSettle();
    expectManualControls(true);

    await tester.tap(option);
    await tester.pumpAndSettle();
    expect(c.autofocus, true);
    expect(c.commands.last, [0x81, 1, 4, 0x38, 2, 0xff]);
    expectManualControls(false);

    await tester.tap(option);
    await tester.pumpAndSettle();
    expect(c.autofocus, false);
    expect(c.commands.last, [0x81, 1, 4, 0x38, 3, 0xff]);
    expectManualControls(true);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'Move until stopped latches directions until the center stop or mode change',
    (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = _MovementUiController();
      addTearDown(c.dispose);
      await tester.pumpWidget(MyApp(controller: c));
      await tester.pumpAndSettle();
      final option = find.text('Move until stopped');
      expect(
        tester.getRect(option).bottom,
        lessThan(tester.getRect(find.byKey(const Key('movement-grid'))).top),
      );
      expect(c.moveUntilStopped, false);
      final held = await tester.startGesture(
        tester.getCenter(find.byTooltip('Pan right · hold to move')),
      );
      await tester.pump();
      expect(c.moving, true);
      await held.up();
      await tester.pumpAndSettle();
      expect(c.moving, false);
      expect(c.movementStops, 1);
      await tester.tap(option);
      await tester.pumpAndSettle();
      expect(c.moveUntilStopped, true);
      await tester.tap(find.byTooltip('Pan right · move until stopped'));
      await tester.pumpAndSettle();
      expect(c.moving, true);
      expect(c.movementStops, 1);
      await tester.tap(find.byTooltip('Stop all movement'));
      await tester.pumpAndSettle();
      expect(c.moving, false);
      expect(c.stopCount, 1);
      expect(c.movementStops, 2);
      await tester.tap(find.byTooltip('Pan right · move until stopped'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Pan left · move until stopped'));
      await tester.pumpAndSettle();
      expect(c.directions.last, (1, 3));
      expect(c.moving, true);
      await tester.tap(option);
      await tester.pumpAndSettle();
      expect(c.moveUntilStopped, false);
      expect(c.moving, false);
      expect(find.byTooltip('Pan left · hold to move'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

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
    expect(c.imageRefreshes, 1);
    final exposureDropdown = find.descendant(
      of: find.byWidgetPredicate(
        (w) => w is InputDecorator && w.decoration.labelText == 'Exposure mode',
      ),
      matching: find.byType(DropdownButton<int>),
    );
    expect(tester.widget<DropdownButton<int>>(exposureDropdown).value, 0x0a);
    c.exposureMode = 3;
    c.notifyListeners();
    await tester.pump();
    expect(tester.widget<DropdownButton<int>>(exposureDropdown).value, 3);
    // Rebuilds and tapping the active page do not repeat its entry queries.
    await tester.tap(find.text('Image'));
    await tester.pumpAndSettle();
    expect(c.imageRefreshes, 1);
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

    final trigger = find.text('Trigger One-Push white balance');
    Future<void> openConfirmation() async {
      await tester.ensureVisible(trigger);
      await tester.tap(trigger);
      await tester.pumpAndSettle();
      expect(find.text('Reset white balance with One-Push?'), findsOneWidget);
      expect(c.commands, isEmpty);
    }

    await openConfirmation();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(c.commands, isEmpty);
    await openConfirmation();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Reset white balance with One-Push?'), findsNothing);
    expect(c.commands, isEmpty);
    await openConfirmation();
    await tester.tap(find.text('Yes'));
    await tester.pumpAndSettle();
    expect(c.commands, [
      [0x81, 1, 4, 0x10, 5, 0xff],
    ]);
    await tester.tap(find.text('Cameras'));
    await tester.pumpAndSettle();
    expect(c.imageRefreshes, 1);
    expect(c.controlRefreshes, 0);
    await tester.tap(find.text('Control'));
    await tester.pumpAndSettle();
    expect(c.controlRefreshes, 1);
    await tester.tap(find.byTooltip('Refresh camera status'));
    await tester.pumpAndSettle();
    expect(c.fullRefreshes, 1);
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
        'Sync pan / tilt',
        'Zoom −',
        'Zoom +',
        'Focus near',
        'Focus far',
        'Position in camera-native units',
        'Hold to move',
        'Stop all movement',
      ]) {
        expect(find.text(removed), findsNothing);
      }
      expect(find.text('PAN: 1200'), findsNothing);
      expect(find.text('TILT: -800'), findsNothing);
      expect(find.text('ZOOM: 16384'), findsNothing);
      final exposureStatus = tester.getRect(
        find.text('EXPOSURE: Shutter priority'),
      );
      final balanceStatus = tester.getRect(find.text('WHITE BALANCE: Outdoor'));
      expect(
        exposureStatus.top,
        greaterThan(tester.getRect(find.text('Connected')).bottom),
      );
      expect(balanceStatus.center.dy, closeTo(exposureStatus.center.dy, .1));
      expect(balanceStatus.left, greaterThan(exposureStatus.right));
      expect(find.text('SPEED'), findsOneWidget);
      final movement = tester.getRect(find.byKey(const Key('movement-grid')));
      final speeds = tester.getRect(find.byKey(const Key('speed-controls')));
      expect(movement.top, closeTo(speeds.top, .1));
      expect(movement.bottom, closeTo(speeds.bottom, .1));
      Rect speedRect(String label) => tester.getRect(
        find.byWidgetPredicate(
          (widget) =>
              widget is InputDecorator && widget.decoration.labelText == label,
        ),
      );
      final pan = speedRect('Pan');
      final tilt = speedRect('Tilt');
      final zoom = speedRect('Zoom');
      final focus = speedRect('Focus');
      final sync = tester.getRect(find.byKey(const Key('sync-pan-tilt')));
      expect(pan.top, closeTo(movement.top, .1));
      expect(tilt.top, closeTo(pan.top, .1));
      expect(sync.left, greaterThan(pan.right));
      expect(sync.right, lessThan(tilt.left));
      expect(sync.center.dy, closeTo(pan.center.dy, .1));
      expect(zoom.left, closeTo(pan.left, .1));
      expect(focus.left, closeTo(pan.left, .1));
      expect(zoom.top, greaterThan(pan.bottom));
      expect(focus.top, greaterThan(zoom.bottom));
      expect(focus.bottom, closeTo(movement.bottom, .1));
      expect(
        tilt.right,
        closeTo(
          tester.getRect(find.byKey(const ValueKey('preset-3'))).right,
          .1,
        ),
      );
      expect(speeds.left - movement.right, greaterThan(12));
      Rect lensRect(String tooltip) =>
          tester.getRect(find.byTooltip('$tooltip · hold to move'));
      final zoomOut = lensRect('Zoom out');
      final zoomIn = lensRect('Zoom in');
      final focusNear = lensRect('Focus near');
      final focusFar = lensRect('Focus far');
      expect(zoomOut.left, greaterThan(zoom.right));
      expect(zoomIn.left, greaterThan(zoomOut.right));
      expect(zoomOut.center.dy, closeTo(zoom.center.dy, .1));
      expect(zoomIn.center.dy, closeTo(zoom.center.dy, .1));
      expect(focusNear.left, greaterThan(focus.right));
      expect(focusFar.left, greaterThan(focusNear.right));
      expect(focusNear.center.dy, closeTo(focus.center.dy, .1));
      expect(focusFar.center.dy, closeTo(focus.center.dy, .1));
      expect(
        tester.getSize(find.byIcon(Icons.zoom_out)).width,
        lessThan(tester.getSize(find.byIcon(Icons.zoom_in)).width),
      );
      expect(
        tester
            .widgetList<FocusDepthIcon>(find.byType(FocusDepthIcon))
            .map((icon) => icon.far),
        [false, true],
      );
      final focusButtons = find.byWidgetPredicate(
        (widget) => widget is HoldButton && widget.label.startsWith('Focus'),
      );
      expect(
        tester
            .widgetList<HoldButton>(focusButtons)
            .every((button) => !button.enabled),
        true,
      );
      c.autofocus = false;
      c.notifyListeners();
      await tester.pump();
      expect(
        tester
            .widgetList<HoldButton>(focusButtons)
            .every((button) => button.enabled),
        true,
      );
      final saveOption = tester.getRect(find.text('Save preset'));
      final apertureOption = tester.getRect(
        find.text('Use exposure from preset'),
      );
      final presetEdge = tester.getRect(find.byKey(const ValueKey('preset-9')));
      expect(saveOption.top, greaterThanOrEqualTo(presetEdge.bottom));
      expect(apertureOption.left, greaterThan(saveOption.right));
      expect(apertureOption.center.dy, closeTo(saveOption.center.dy, .1));
      expect(apertureOption.right, closeTo(presetEdge.right, .1));
      final apertureCheckbox = find.descendant(
        of: find
            .ancestor(
              of: find.text('Use exposure from preset'),
              matching: find.byType(InkWell),
            )
            .first,
        matching: find.byType(Checkbox),
      );
      expect(tester.getTopLeft(apertureCheckbox).dx, closeTo(200, .1));
      expect(tester.widget<Checkbox>(apertureCheckbox).onChanged, isNotNull);
      await tester.tap(find.text('Use exposure from preset'));
      await tester.pump();
      expect(tester.widget<Checkbox>(apertureCheckbox).value, true);
      expect(
        tester.widget<Text>(find.text('Use exposure from preset')).textAlign,
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
      final stopButton = find.byTooltip('Stop all movement');
      final stopPress = await tester.startGesture(tester.getCenter(stopButton));
      await tester.pump();
      expect(c.stopCount, 1);
      await stopPress.up();
      await tester.pumpAndSettle();
      expect(c.stopCount, 1);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(c.stopCount, 2);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.space);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(c.stopCount, 2);
      await tester.tap(find.byKey(const Key('sync-pan-tilt')));
      await tester.pumpAndSettle();
      c.setSpeed('Tilt', 17);
      await tester.pumpAndSettle();
      expect([c.panSpeed, c.tiltSpeed], [17, 17]);
      expect(find.byTooltip('Disable pan / tilt sync'), findsOneWidget);
      await tester.tap(find.byKey(const Key('sync-pan-tilt')));
      await tester.pumpAndSettle();
      c.setSpeed('Pan', 24);
      await tester.pumpAndSettle();
      expect([c.panSpeed, c.tiltSpeed], [24, 17]);
      expect(find.byTooltip('Enable pan / tilt sync'), findsOneWidget);
      await tester.tap(find.text('Save preset'));
      await tester.pumpAndSettle();
      expect(find.text('Save exposure with preset'), findsOneWidget);
      expect(find.text('Use exposure from preset'), findsNothing);
      expect(c.saveExposureWithPreset, true);
      await tester.tap(find.text('Save exposure with preset'));
      await tester.pump();
      expect(c.saveExposureWithPreset, false);
      await tester.tap(find.byKey(const ValueKey('preset-2')));
      await tester.pumpAndSettle();
      expect(find.text('Save preset 2'), findsOneWidget);
      expect(c.presetRefreshes, 1);
      expect(find.text('Exposure mode: Shutter priority'), findsOneWidget);
      expect(find.text('Aperture: 17'), findsOneWidget);
      expect(
        find.text('Exposure setting can only be saved for manual exposure.'),
        findsOneWidget,
      );
      final mode = tester.getRect(find.text('Exposure mode: Shutter priority'));
      final iris = tester.getRect(find.text('Aperture: 17'));
      expect(iris.left, greaterThan(mode.right));
      expect(iris.top, closeTo(mode.top, .1));
      const manualMessage = 'Exposure setting will be saved.';
      expect(find.text(manualMessage), findsNothing);
      c.exposureMode = 3;
      c.imageValues[0x4b] = 9;
      c.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('Exposure mode: Manual'), findsOneWidget);
      expect(find.text('Aperture: 9'), findsOneWidget);
      expect(
        find.text('Exposure setting can only be saved for manual exposure.'),
        findsNothing,
      );
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
