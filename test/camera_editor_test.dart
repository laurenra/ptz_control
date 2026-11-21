import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ptz_control/models/camera.dart';
import 'package:ptz_control/models/camera_limits.dart';
import 'package:ptz_control/widgets/camera_editor.dart';
import 'package:ptz_control/widgets/connection_status.dart';

void main() {
  Finder field(String label) => find.byWidgetPredicate(
    (widget) => widget is TextField && widget.decoration?.labelText == label,
  );

  Future<void> openEditor(
    WidgetTester tester, {
    Camera? camera,
    required Future<bool> Function(Camera) onTest,
    Future<CameraLimits> Function(Camera)? onTestLimits,
    Future<void> Function()? onStopLimits,
    Future<bool> Function(Camera)? onSave,
  }) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => CameraEditor(
                  camera: camera,
                  newCameraId: 42,
                  onSave: onSave ?? (_) async => true,
                  onTest: onTest,
                  onTestLimits:
                      onTestLimits ??
                      (_) async => throw StateError('Unexpected limit test'),
                  onStopLimits: onStopLimits ?? () async {},
                ),
              ),
              child: const Text('Open editor'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();
  }

  testWidgets('tests unsaved settings without requiring a display name', (
    tester,
  ) async {
    final tested = <Camera>[];
    await openEditor(
      tester,
      onTest: (camera) async {
        tested.add(camera);
        return true;
      },
    );
    expect(find.text('Not connected'), findsOneWidget);
    expect(tested, isEmpty);
    final button = find.text('Test connection');
    final instructions = find.text(
      'Local port 0 chooses an available port. Set a fixed local port if your camera requires it.',
    );
    expect(
      tester.getRect(button).top,
      greaterThan(tester.getRect(instructions).bottom),
    );
    expect(
      tester.getRect(find.text('Not connected')).left,
      greaterThan(tester.getRect(button).right),
    );
    await tester.enterText(field('IPv4 address'), '192.168.1.123');
    await tester.enterText(field('Camera port'), '50000');
    await tester.enterText(field('Local port'), '50001');
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(tested.single.host, '192.168.1.123');
    expect(tested.single.id, 42);
    expect(tested.single.port, 50000);
    expect(tested.single.localPort, 50001);
    expect(tested.single.transport, ViscaTransport.sony);
    expect(find.text('Enter a camera name'), findsNothing);
    expect(find.text('Connected'), findsOneWidget);
    expect(
      tester.widget<ConnectionStatus>(find.byType(ConnectionStatus)).connected,
      true,
    );
    await tester.enterText(field('IPv4 address'), '192.168.1.124');
    await tester.pump();
    expect(find.text('Not connected'), findsOneWidget);
  });

  testWidgets('validates address and both ports without sending a test', (
    tester,
  ) async {
    var calls = 0;
    await openEditor(
      tester,
      onTest: (_) async {
        calls++;
        return true;
      },
    );
    await tester.enterText(field('Camera port'), '0');
    await tester.enterText(field('Local port'), '65536');
    await tester.tap(find.text('Test connection'));
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(
      find.text('Enter an IPv4 address, e.g. 192.168.1.100'),
      findsOneWidget,
    );
    expect(find.text('1–65535'), findsOneWidget);
    expect(find.text('0–65535'), findsOneWidget);
    expect(find.text('Enter a camera name'), findsNothing);
  });

  testWidgets(
    'editing tests saved settings once automatically and clears stale success on network changes',
    (tester) async {
      final tested = <Camera>[];
      await openEditor(
        tester,
        camera: const Camera(
          id: 1,
          name: 'Stage',
          host: '192.168.1.10',
          port: 1259,
        ),
        onTest: (camera) async {
          tested.add(camera);
          return true;
        },
      );
      expect(find.text('Edit camera'), findsOneWidget);
      expect(find.text('Connected'), findsOneWidget);
      expect(tested.single.transport, ViscaTransport.raw);
      expect(tested.single.id, 1);
      await tester.pump();
      expect(tested, hasLength(1));
      for (final label in ['Camera port', 'Local port']) {
        await tester.enterText(field(label), '50000');
        await tester.pump();
        expect(find.text('Not connected'), findsOneWidget);
        await tester.tap(find.text('Test connection'));
        await tester.pumpAndSettle();
        expect(find.text('Connected'), findsOneWidget);
      }
      await tester.tap(find.text('Raw VISCA'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('VISCA over IP').last);
      await tester.pumpAndSettle();
      expect(find.text('Not connected'), findsOneWidget);
      await tester.tap(find.text('Test connection'));
      await tester.pumpAndSettle();
      expect(tested.last.transport, ViscaTransport.sony);
    },
  );

  testWidgets(
    'automatic test disables repeat tests and saving until result, and reports failure',
    (tester) async {
      final result = Completer<bool>();
      await openEditor(
        tester,
        camera: const Camera(
          id: 1,
          name: 'Stage',
          host: '192.168.1.10',
          port: 1259,
        ),
        onTest: (_) => result.future,
      );
      expect(find.text('Testing…'), findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Test connection'),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      result.complete(false);
      await tester.pumpAndSettle();
      expect(find.text('Not connected'), findsOneWidget);
      expect(
        tester
            .widget<ConnectionStatus>(find.byType(ConnectionStatus))
            .connected,
        false,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Test connection'),
            )
            .onPressed,
        isNotNull,
      );
    },
  );

  const limits = CameraLimits(
    panMin: -30,
    panMax: 40,
    tiltMin: -20,
    tiltMax: 50,
    zoomMin: 10,
    zoomMax: 80,
  );

  testWidgets(
    'limit test shows progress and table, and preserves results when saving camera',
    (tester) async {
      final result = Completer<CameraLimits>();
      Camera? testedCamera;
      Camera? savedCamera;
      await openEditor(
        tester,
        onTest: (_) async => true,
        onTestLimits: (camera) {
          testedCamera = camera;
          return result.future;
        },
        onSave: (camera) async {
          savedCamera = camera;
          return true;
        },
      );
      await tester.enterText(field('Camera name'), 'New camera');
      await tester.enterText(field('IPv4 address'), '192.168.1.10');
      final button = find.text('Test & save limits');
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      expect(
        tester.getRect(button).top,
        greaterThan(tester.getRect(find.text('Test connection')).bottom),
      );
      await tester.tap(button);
      await tester.pump();
      expect(find.text('Please wait. Testing limits...'), findsOneWidget);
      expect(find.text('Stop test'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      result.complete(limits);
      await tester.pumpAndSettle();
      expect(find.text('Please wait. Testing limits...'), findsNothing);
      expect(find.text('Min'), findsOneWidget);
      expect(find.text('Max'), findsOneWidget);
      for (final entry in {
        'pan-min': '-30',
        'pan-max': '40',
        'tilt-min': '-20',
        'tilt-max': '50',
        'zoom-min': '10',
        'zoom-max': '80',
      }.entries) {
        expect(
          tester.widget<Text>(find.byKey(ValueKey('limit-${entry.key}'))).data,
          entry.value,
        );
      }
      await tester.tap(find.text('Save camera'));
      await tester.pumpAndSettle();
      expect(savedCamera!.id, testedCamera!.id);
      expect(savedCamera!.limits!.toJson(), limits.toJson());
    },
  );

  testWidgets('saved limits appear on edit and survive a stopped test', (
    tester,
  ) async {
    final result = Completer<CameraLimits>();
    var stopCalls = 0;
    await openEditor(
      tester,
      camera: const Camera(
        id: 1,
        name: 'Stage',
        host: '192.168.1.10',
        port: 1259,
        limits: limits,
      ),
      onTest: (_) async => true,
      onTestLimits: (_) => result.future,
      onStopLimits: () async {
        stopCalls++;
        result.completeError(StateError('Stopped'));
      },
    );
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('limit-pan-min'))).data,
      '-30',
    );
    await tester.ensureVisible(find.text('Test & save limits'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Test & save limits'));
    await tester.pump();
    await tester.ensureVisible(find.text('Stop test'));
    await tester.tap(find.text('Stop test'));
    await tester.pumpAndSettle();
    expect(stopCalls, 1);
    expect(find.textContaining('Limits were not saved:'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('limit-pan-min'))).data,
      '-30',
    );
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Test & save limits'),
          )
          .onPressed,
      isNotNull,
    );
  });
}
