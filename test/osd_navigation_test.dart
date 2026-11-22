import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ptz_control/controller.dart';
import 'package:ptz_control/models/camera.dart';
import 'package:ptz_control/services/visca_protocol.dart';

import 'visca_client_test.dart' show MemoryStore;

void main() {
  late RawDatagramSocket server;
  late StreamSubscription<RawSocketEvent> subscription;
  late PtzController controller;
  late Camera camera;
  final received = <List<int>>[];
  Completer<Datagram>? heldEnter;
  Completer<Datagram>? heldDirection;
  Completer<Datagram>? heldStop;
  var reject = false;
  var ignoreDirection = false;

  setUp(() async {
    received.clear();
    heldEnter = null;
    heldDirection = heldStop = null;
    reject = false;
    ignoreDirection = false;
    server = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    subscription = server.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? packet;
      while ((packet = server.receive()) != null) {
        final p = packet!;
        final bytes = p.data.toList();
        received.add(bytes);
        if (bytes.length == 9 && bytes[2] == 6 && bytes[3] == 1) {
          final stop = bytes[6] == 3 && bytes[7] == 3;
          final held = stop ? heldStop : heldDirection;
          if (held?.isCompleted == false) {
            held!.complete(p);
            continue;
          }
          if (!stop && ignoreDirection) continue;
        }
        if (heldEnter != null && bytes.length == 6 && bytes[3] == 6) {
          heldEnter!.complete(p);
          continue;
        }
        final reply = bytes[1] == 9
            ? switch (bytes[3]) {
                0x12 => [0x90, 0x50, ...List.filled(8, 0), 255],
                0x38 || 0x39 || 0x35 => [0x90, 0x50, 3, 255],
                _ => [0x90, 0x50, 0, 0, 0, 0, 255],
              }
            : reject
            ? [0x90, 0x60, 2, 255]
            : [0x90, 0x50, 255];
        server.send(reply, p.address, p.port);
      }
    });
    camera = Camera(id: 1, name: 'Stage', host: '127.0.0.1', port: server.port);
    controller = PtzController(store: MemoryStore([camera]));
    await controller.initialize();
    received.clear();
  });

  tearDown(() async {
    controller.dispose();
    await subscription.cancel();
    server.close();
  });

  test(
    'mode is local, blocks normal controls, and refreshes on return',
    () async {
      await controller.osdCommand(OsdKey.menu);
      expect(received, isEmpty);
      await controller.setOsdNavigation(true);
      expect(controller.osdNavigation, true);
      expect(controller.canOperate, false);
      expect(received, isEmpty);
      await controller.command('Home', Visca.home);
      expect(controller.startPanTilt('Right', 2, 3), false);
      expect(
        controller.startMotion(
          'Zoom',
          Visca.camera(7, [0x23]),
          Visca.camera(7, [0]),
        ),
        false,
      );
      expect(await controller.recallPreset(1), false);
      expect(await controller.savePreset(1, 'Test'), false);
      expect(received, isEmpty);

      // No inquiries should compete with menu actions while OSD is active.
      await controller.refresh();
      await controller.refreshControlStatus();
      expect(received, isEmpty);

      for (final key in OsdKey.values) {
        await controller.osdCommand(key);
      }
      expect(received, [
        Visca.osd(OsdKey.menu),
        Visca.osd(OsdKey.up),
        Visca.osdStop,
        Visca.osd(OsdKey.down),
        Visca.osdStop,
        Visca.osd(OsdKey.left),
        Visca.osdStop,
        Visca.osd(OsdKey.right),
        Visca.osdStop,
        Visca.osd(OsdKey.enter),
      ]);
      received.clear();
      await controller.setOsdNavigation(false);
      expect(controller.canOperate, true);
      expect(received, [
        Visca.focusModeInquiry,
        Visca.exposureModeInquiry,
        Visca.whiteBalanceModeInquiry,
        Visca.apertureInquiry,
      ]);
      expect(received.every((bytes) => bytes[1] == 9), true);
    },
  );

  test('a direction ACK gets a 100ms pause before stop and controls wait for its reply', () async {
    await controller.setOsdNavigation(true);
    controller.setSpeed('Pan', 1);
    controller.setSpeed('Tilt', 2);
    heldDirection = Completer<Datagram>();
    heldStop = Completer<Datagram>();
    final sending = controller.osdCommand(OsdKey.up);
    final direction = await heldDirection!.future.timeout(
      const Duration(seconds: 1),
    );
    expect(controller.moving, true);
    expect(controller.canNavigateOsd, false);
    expect(received, [Visca.osd(OsdKey.up)]);
    // ACK only: the camera may defer completion until it receives Stop.
    final sinceAck = Stopwatch()..start();
    server.send([0x90, 0x41, 255], direction.address, direction.port);
    final stop = await heldStop!.future.timeout(const Duration(seconds: 1));
    // Allow a small timer-resolution tolerance without imposing a flaky
    // upper bound on OS scheduling or UDP delivery time.
    expect(sinceAck.elapsedMilliseconds, greaterThanOrEqualTo(95));
    expect(received, [Visca.osd(OsdKey.up), Visca.osdStop]);
    expect(controller.osdBusy, true);
    expect(controller.canNavigateOsd, false);
    await controller.osdCommand(OsdKey.down);
    await controller.setOsdNavigation(false);
    expect(controller.osdNavigation, true);
    server.send([0x90, 0x41, 255], stop.address, stop.port);
    await sending;
    expect(controller.osdBusy, false);
    expect(controller.moving, false);
    expect(controller.canNavigateOsd, true);
    expect(received, [Visca.osd(OsdKey.up), Visca.osdStop]);
  });

  test(
    'a direction timeout still sends stop and preserves the failure message',
    () async {
      await controller.setOsdNavigation(true);
      ignoreDirection = true;
      await controller.osdCommand(OsdKey.left);
      expect(received, [Visca.osd(OsdKey.left), Visca.osdStop]);
      expect(controller.message, 'No acknowledgement: OSD left');
      expect(controller.canNavigateOsd, true);
      expect(controller.moving, false);
    },
  );

  test(
    'focus loss can stop an unacknowledged direction without duplicate stops',
    () async {
      await controller.setOsdNavigation(true);
      heldDirection = Completer<Datagram>();
      final sending = controller.osdCommand(OsdKey.right);
      await heldDirection!.future.timeout(const Duration(seconds: 1));
      await controller.endMotion();
      await sending;
      expect(received, [Visca.osd(OsdKey.right), Visca.osdStop]);
      expect(controller.moving, false);
      expect(controller.canNavigateOsd, true);
      expect(controller.message, isNull);
    },
  );

  test(
    'OSD silence does not mark the camera offline or fabricate replies',
    () async {
      await controller.setOsdNavigation(true);
      final previousReply = DateTime.now().subtract(const Duration(minutes: 1));
      controller.lastReply = previousReply;
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      expect(controller.connection, CameraConnection.connected);
      expect(controller.lastReply, previousReply);
      await controller.setOsdNavigation(false, refreshStatus: false);
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      expect(controller.connection, CameraConnection.connected);
      expect(controller.lastReply, previousReply);
      expect(received, isEmpty);
    },
  );

  test(
    'entering OSD stops active lens movement before enabling navigation',
    () async {
      controller.startMotion(
        'Zoom',
        Visca.camera(7, [0x23]),
        Visca.camera(7, [0]),
      );
      final entering = controller.setOsdNavigation(true);
      expect(controller.changingOsdNavigation, true);
      expect(controller.canOperate, false);
      expect(controller.canNavigateOsd, false);
      await entering;
      expect(controller.moving, false);
      expect(controller.canNavigateOsd, true);
      expect(received, contains(equals(Visca.camera(7, [0]))));
      expect(received, isNot(contains(equals(Visca.osd(OsdKey.menu)))));
    },
  );

  test('an in-flight OSD action cannot repeat or change mode', () async {
    await controller.setOsdNavigation(true);
    heldEnter = Completer<Datagram>();
    final sending = controller.osdCommand(OsdKey.enter);
    final packet = await heldEnter!.future;
    expect(controller.osdBusy, true);
    expect(controller.canNavigateOsd, false);
    await controller.osdCommand(OsdKey.enter);
    await controller.setOsdNavigation(false);
    expect(controller.osdNavigation, true);
    expect(received, [Visca.osd(OsdKey.enter)]);
    server.send([0x90, 0x50, 255], packet.address, packet.port);
    await sending;
    expect(controller.canNavigateOsd, true);
  });

  test(
    'camera errors keep the local mode usable and selection resets it',
    () async {
      await controller.setOsdNavigation(true);
      reject = true;
      await controller.osdCommand(OsdKey.menu);
      expect(controller.message, contains('unsupported command'));
      expect(controller.canNavigateOsd, true);
      reject = false;
      await controller.select(camera);
      expect(controller.osdNavigation, false);
      expect(controller.canOperate, true);
      expect(received.where((bytes) => bytes[1] == 1), [
        Visca.osd(OsdKey.menu),
      ]);
    },
  );
}
