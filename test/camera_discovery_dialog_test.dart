import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ptz_control/controller.dart';
import 'package:ptz_control/models/discovered_camera.dart';
import 'package:ptz_control/services/onvif_discovery.dart';
import 'package:ptz_control/widgets/camera_discovery_dialog.dart';
import 'package:ptz_control/widgets/control_shell.dart';

import 'visca_client_test.dart' show MemoryStore;

class _Scan implements CameraDiscoveryScan {
  final controller = StreamController<List<DiscoveredCamera>>();
  bool cancelled = false;
  @override
  Stream<List<DiscoveredCamera>> get results => controller.stream;
  @override
  void cancel() {
    if (cancelled) return;
    cancelled = true;
    unawaited(controller.close());
  }
}

class _Discovery extends OnvifDiscoveryService {
  final scans = <_Scan>[];
  @override
  CameraDiscoveryScan start() {
    final scan = _Scan();
    scans.add(scan);
    return scan;
  }
}

void main() {
  late _Discovery discovery;
  late PtzController controller;

  Future<void> openCameras(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    discovery = _Discovery();
    controller = PtzController(store: MemoryStore([]));
    await controller.setPaused(true);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ControlShell(controller: controller, discoveryService: discovery),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cameras'));
    await tester.pumpAndSettle();
  }

  Future<void> openSearch(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(OutlinedButton, 'Find cameras'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets(
    'Find cameras, Export and Import remain on one line at narrow widths',
    (tester) async {
      await openCameras(tester);
      expect(find.text('Export settings'), findsNothing);
      expect(find.text('Import settings'), findsNothing);
      for (final size in [const Size(400, 800), const Size(320, 640)]) {
        tester.view.physicalSize = size;
        for (final side in [false, true]) {
          if (controller.sideNavigation != side) controller.toggleNavigation();
          await tester.pumpAndSettle();
          final buttons = [
            'Find cameras',
            'Export',
            'Import',
          ].map((label) => find.widgetWithText(OutlinedButton, label)).toList();
          final rects = buttons.map(tester.getRect).toList();
          expect(rects[0].center.dy, rects[1].center.dy);
          expect(rects[1].center.dy, rects[2].center.dy);
          expect(rects[0].right, lessThan(rects[1].left));
          expect(rects[1].right, lessThan(rects[2].left));
          expect(
            tester.widget<OutlinedButton>(buttons[0]).onPressed,
            isNotNull,
          );
          expect(tester.widget<OutlinedButton>(buttons[1]).onPressed, isNull);
          expect(
            tester.widget<OutlinedButton>(buttons[2]).onPressed,
            isNotNull,
          );
          expect(tester.takeException(), isNull);
        }
      }
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'shows live discovery metadata and Cancel closes and stops discovery',
    (tester) async {
      await openCameras(tester);
      await openSearch(tester);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.text('Searching for ONVIF devices…'), findsOneWidget);
      final scan = discovery.scans.single;
      scan.controller.add([
        DiscoveredCamera(
          address: 'urn:uuid:camera-one',
          types: ['dn:NetworkVideoTransmitter'],
          scopes: ['onvif://www.onvif.org/name/Chapel'],
          xAddrs: ['http://192.0.2.1/onvif/device_service'],
        ),
      ]);
      await tester.pump();
      expect(find.text('1 device found'), findsOneWidget);
      for (final text in [
        'EndpointReference (address)',
        'Types',
        'Scopes',
        'XAddrs',
        'urn:uuid:camera-one',
        'dn:NetworkVideoTransmitter',
        'onvif://www.onvif.org/name/Chapel',
        'http://192.0.2.1/onvif/device_service',
      ]) {
        expect(find.text(text), findsOneWidget);
      }
      expect(controller.cameras, isEmpty);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(CameraDiscoveryDialog), findsNothing);
      expect(scan.cancelled, true);
      expect(controller.cameras, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'completed results stay open, scroll, and show missing metadata at 320 by 640',
    (tester) async {
      await openCameras(tester);
      tester.view.physicalSize = const Size(320, 640);
      await tester.pumpAndSettle();
      await openSearch(tester);
      final scan = discovery.scans.single;
      scan.controller.add([
        for (var i = 0; i < 3; i++)
          DiscoveredCamera(
            address: 'urn:uuid:camera-$i',
            types: [],
            scopes: [],
            xAddrs: [],
          ),
      ]);
      await scan.controller.close();
      await tester.pumpAndSettle();
      expect(find.text('Search finished'), findsOneWidget);
      expect(find.text('3 devices found'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.text('Not reported'), findsWidgets);
      final list = find.descendant(
        of: find.byType(CameraDiscoveryDialog),
        matching: find.byType(ListView),
      );
      await tester.drag(list, const Offset(0, -650));
      await tester.pumpAndSettle();
      expect(find.text('urn:uuid:camera-2'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final fail in [false, true]) {
    testWidgets(
      fail
          ? 'shows discovery errors with Cancel still available'
          : 'shows a useful empty result',
      (tester) async {
        await openCameras(tester);
        await openSearch(tester);
        final scan = discovery.scans.single;
        if (fail) scan.controller.addError(StateError('network unavailable'));
        await scan.controller.close();
        await tester.pumpAndSettle();
        expect(
          find.text(
            fail ? 'Check local network access and try again.' : 'No ONVIF devices responded. Check your network connection and that ONVIF discovery is enabled on the cameras.',
          ),
          findsOneWidget,
        );
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(scan.cancelled, true);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
