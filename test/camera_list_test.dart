import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ptz_control/controller.dart';
import 'package:ptz_control/main.dart';
import 'package:ptz_control/models/camera.dart';
import 'package:ptz_control/services/camera_store.dart';

import 'visca_client_test.dart' show MemoryStore;

const cameras = [
  Camera(id: 1, name: 'One', host: '192.0.2.1', port: 52381),
  Camera(id: 2, name: 'Two', host: '192.0.2.2', port: 52381),
  Camera(id: 3, name: 'Three', host: '192.0.2.3', port: 52381),
];

class _FailingStore extends MemoryStore {
  _FailingStore(super.cameras);
  @override
  Future<void> save(List<Camera> cameras, {int? nextId}) async =>
      throw StateError('Save failed');
}

class _ListController extends PtzController {
  _ListController(this.store) : super(store: store);
  final MemoryStore store;
  @override
  Future<void> initialize() async {
    this.cameras = List.of(store.cameras);
    selected = this.cameras[0];
    loading = false;
    notifyListeners();
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'reordering persists both directions and retains selection and IDs',
    () async {
      final store = MemoryStore(List.of(cameras));
      final c = PtzController(store: store);
      addTearDown(c.dispose);
      await c.setPaused(true);
      await c.initialize();
      await c.select(cameras[1]);
      expect(await c.reorderCamera(0, 2), true);
      expect(c.cameras.map((camera) => camera.id), [2, 3, 1]);
      expect(store.cameras, c.cameras);
      expect(c.selected, same(cameras[1]));
      expect(c.connection, CameraConnection.paused);
      expect(await c.reorderCamera(2, 0), true);
      expect(c.cameras, cameras);
      expect(c.nextCameraId, 4);
      expect(await c.reorderCamera(-1, 0), false);
      expect(await c.reorderCamera(0, 3), false);
    },
  );

  test('failed reorder leaves order and selected camera intact', () async {
    final c = PtzController(store: _FailingStore(List.of(cameras)));
    addTearDown(c.dispose);
    await c.setPaused(true);
    await c.initialize();
    final selected = c.selected;
    expect(await c.reorderCamera(0, 2), false);
    expect(c.cameras, cameras);
    expect(c.selected, same(selected));
    expect(c.message, contains('Could not save'));
  });

  test(
    'new IDs advance on successful saves and survive deletion and restart',
    () async {
      final store = PreferencesCameraStore();
      final c = PtzController(store: store);
      addTearDown(c.dispose);
      await c.setPaused(true);
      await c.initialize();
      expect(c.nextCameraId, 1);
      expect(await c.saveCamera(cameras[0]), true);
      expect(c.nextCameraId, 2);
      expect(await c.saveCamera(cameras[1]), true);
      expect(c.nextCameraId, 3);
      await c.removeCamera(cameras[1]);
      final restarted = PtzController(store: PreferencesCameraStore());
      addTearDown(restarted.dispose);
      await restarted.setPaused(true);
      await restarted.initialize();
      expect(restarted.nextCameraId, 3);
      expect(await restarted.saveCamera(cameras[2]), true);
      expect(restarted.cameras.map((camera) => camera.id), [1, 3]);
    },
  );

  test('IDs stay within 1–255 when the sequence reaches its end', () async {
    final store = MemoryStore([
      const Camera(
        id: 254,
        name: 'Last but one',
        host: '192.0.2.1',
        port: 52381,
      ),
    ]);
    final c = PtzController(store: store);
    addTearDown(c.dispose);
    await c.setPaused(true);
    await c.initialize();
    expect(c.nextCameraId, 255);
    await c.saveCamera(
      const Camera(id: 255, name: 'Last', host: '192.0.2.2', port: 52381),
    );
    expect(c.nextCameraId, 1);
    await c.saveCamera(cameras[0]);
    expect(c.nextCameraId, 2);
    expect(
      c.cameras.map((camera) => camera.id).toSet().length,
      c.cameras.length,
    );
  });

  testWidgets('drag order drives dropdowns while keeping the selected camera', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = MemoryStore(List.of(cameras));
    final c = _ListController(store);
    addTearDown(c.dispose);
    await tester.pumpWidget(MyApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cameras'));
    await tester.pumpAndSettle();
    final first = tester.getCenter(find.byTooltip('Drag to reorder One'));
    final third = tester.getCenter(find.byTooltip('Drag to reorder Three'));
    final drag = await tester.startGesture(first);
    final distance = third.dy + 90 - first.dy;
    for (var step = 1; step <= 20; step++) {
      await drag.moveTo(first + Offset(0, distance * step / 20));
      await tester.pump(const Duration(milliseconds: 30));
    }
    await drag.up();
    await tester.pumpAndSettle();
    expect(c.cameras.map((camera) => camera.id), [2, 3, 1]);
    expect(store.cameras, c.cameras);
    expect(c.selected!.id, 1);
    expect(find.text('01'), findsOneWidget);
    for (final tab in ['Control', 'Image']) {
      await tester.tap(find.text(tab));
      await tester.pumpAndSettle();
      final finder = find.byWidgetPredicate(
        (widget) =>
            widget is DropdownButtonFormField<int> &&
            widget.decoration.labelText == 'Selected camera',
      );
      final selector = tester.widget<DropdownButtonFormField<int>>(finder);
      // The form value is the camera ID; its menu follows the saved order.
      expect(tester.state<FormFieldState<int>>(finder).value, 1);
      expect(selector.initialValue, 1);
      final dropdown = tester.widget<DropdownButton<int>>(
        find.descendant(of: finder, matching: find.byType(DropdownButton<int>)),
      );
      expect(dropdown.items!.map((item) => item.value), [2, 3, 1]);
      expect(dropdown.value, 1);
    }
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Cameras'));
    tester.view.physicalSize = const Size(320, 640);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
