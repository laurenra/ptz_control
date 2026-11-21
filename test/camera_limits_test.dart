import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ptz_control/controller.dart';
import 'package:ptz_control/models/camera.dart';
import 'package:ptz_control/models/camera_limits.dart';
import 'package:ptz_control/services/camera_limit_tester.dart';
import 'package:ptz_control/services/visca_protocol.dart';

import 'visca_client_test.dart' show MemoryStore;

const measured = CameraLimits(
  panMin: -30,
  panMax: 40,
  tiltMin: -20,
  tiltMax: 50,
  zoomMin: 10,
  zoomMax: 80,
);
const previous = CameraLimits(
  panMin: -10,
  panMax: 10,
  tiltMin: -10,
  tiltMax: 10,
  zoomMin: 0,
  zoomMax: 100,
);

class _Store extends MemoryStore {
  _Store(super.cameras);
  bool fail = false;
  @override
  Future<void> save(List<Camera> cameras, {int? nextId}) async {
    if (fail) throw StateError('Storage failure');
    await super.save(cameras, nextId: nextId);
  }
}

void main() {
  late RawDatagramSocket server;
  late StreamSubscription<RawSocketEvent> subscription;
  late Camera camera;
  late PtzController controller;
  late _Store store;
  late List<List<int>> received;
  var pan = 0, tilt = 0, zoom = 30;
  var panDirection = 0, tiltDirection = 0, zoomDirection = 0;
  var rejectMovement = false,
      invalidPosition = false,
      neverStops = false,
      stationary = false;
  var disposed = false;
  var holdHome = false, rejectHome = false;
  Completer<Datagram>? homeArrived;
  Completer<void>? moved;

  setUp(() async {
    pan = tilt = panDirection = tiltDirection = zoomDirection = 0;
    zoom = 30;
    rejectMovement = invalidPosition = neverStops = stationary = disposed =
        false;
    moved = null;
    holdHome = rejectHome = false;
    homeArrived = null;
    received = [];
    server = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    subscription = server.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? packet;
      while ((packet = server.receive()) != null) {
        final p = packet!;
        if (p.data[0] == 2) {
          server.send([2, 1, 0, 1, 0, 0, 0, 0, 1], p.address, p.port);
          continue;
        }
        final framed = p.data[0] == 1;
        final data = framed ? p.data.sublist(8) : p.data.toList();
        received.add(data);
        void reply(List<int> payload) {
          if (!framed) {
            server.send(payload, p.address, p.port);
          } else {
            final bytes = Uint8List(8 + payload.length);
            bytes.setRange(0, 8, p.data);
            bytes[1] = 0x11;
            ByteData.sublistView(bytes).setUint16(2, payload.length);
            bytes.setRange(8, bytes.length, payload);
            server.send(bytes, p.address, p.port);
          }
        }

        if (data[1] == 9) {
          if (invalidPosition && data[3] == 0x12) {
            reply([0x90, 0x60, 0x41, 255]);
            continue;
          }
          if (!stationary) {
            pan += panDirection * 10;
            tilt += tiltDirection * 10;
            zoom += zoomDirection * 10;
            if (!neverStops) {
              pan = pan.clamp(-30, 40);
              tilt = tilt.clamp(-20, 50);
              zoom = zoom.clamp(10, 80);
            }
          }
          reply(switch (data[3]) {
            0x12 => [
              0x90,
              0x50,
              ...Visca.positionNibbles(pan, signed: true),
              ...Visca.positionNibbles(tilt, signed: true),
              255,
            ],
            0x47 => [0x90, 0x50, ...Visca.positionNibbles(zoom), 255],
            0x4a ||
            0x4b ||
            0x4c ||
            0x43 ||
            0x44 => [0x90, 0x50, 0, 0, 0, 1, 255],
            _ => [0x90, 0x50, 3, 255],
          });
        } else {
          if (data[2] == 6 && data[3] == 4) {
            if (rejectHome) {
              reply([0x90, 0x60, 0x41, 255]);
              continue;
            }
            reply([0x90, 0x41, 255]);
            if (holdHome) {
              if (homeArrived?.isCompleted == false) homeArrived!.complete(p);
              continue;
            }
            pan = tilt = 0;
            reply([0x90, 0x51, 255]);
            continue;
          }
          final ptz = data[2] == 6 && data[3] == 1;
          final isZoom = data[2] == 4 && data[3] == 7;
          final moving = ptz
              ? data[6] != 3 || data[7] != 3
              : isZoom && data[4] != 0;
          if (moving && rejectMovement) {
            reply([0x90, 0x60, 0x41, 255]);
            continue;
          }
          if (ptz) {
            panDirection = data[6] == 1
                ? -1
                : data[6] == 2
                ? 1
                : 0;
            tiltDirection = data[7] == 1
                ? 1
                : data[7] == 2
                ? -1
                : 0;
          } else if (isZoom) {
            zoomDirection = data[4] == 0
                ? 0
                : (data[4] & 0xf0) == 0x20
                ? 1
                : -1;
          }
          if (moving && moved?.isCompleted == false) moved!.complete();
          reply([0x90, 0x41, 255]);
          reply([0x90, 0x51, 255]);
        }
      }
    });
    camera = Camera(
      id: 1,
      name: 'Stage',
      host: '127.0.0.1',
      port: server.port,
      limits: previous,
    );
    store = _Store([camera]);
    controller = PtzController(
      store: store,
      limitTesterFactory: (client) => CameraLimitTester(
        client,
        pollInterval: const Duration(milliseconds: 1),
        settleDuration: const Duration(milliseconds: 4),
        stableSamples: 3,
        travelTimeout: Duration(milliseconds: neverStops ? 40 : 500),
      ),
    );
    await controller.initialize();
    received.clear();
  });

  tearDown(() async {
    if (!disposed) controller.dispose();
    await subscription.cancel();
    server.close();
  });

  for (final transport in ViscaTransport.values) {
    test('sweeps all six directions and persists $transport limits', () async {
      final entered = Camera(
        id: camera.id,
        name: camera.name,
        host: camera.host,
        port: camera.port,
        transport: transport,
        limits: previous,
      );
      final limits = await controller.testAndSaveCameraLimits(entered);
      expect(limits.toJson(), measured.toJson());
      expect(
        Camera.fromJson(store.cameras.single.toJson()).limits!.toJson(),
        measured.toJson(),
      );
      expect(controller.selected!.limits!.toJson(), measured.toJson());
      expect([panDirection, tiltDirection, zoomDirection], [0, 0, 0]);
      expect([pan, tilt], [0, 0]);
      final moves = received
          .where(
            (command) =>
                (command[1] == 1 &&
                    command[2] == 6 &&
                    command[3] == 1 &&
                    (command[6] != 3 || command[7] != 3)) ||
                (command[1] == 1 &&
                    command[2] == 4 &&
                    command[3] == 7 &&
                    command[4] != 0) ||
                listEquals(command, Visca.home),
          )
          .toList();
      expect(moves, hasLength(7));
      expect(moves.last, Visca.home);
      for (final command in [
        Visca.drive(12, 10, 1, 3),
        Visca.drive(12, 10, 2, 3),
        Visca.drive(12, 10, 3, 2),
        Visca.drive(12, 10, 3, 1),
        Visca.lens(focus: false, positive: false, speed: 7),
        Visca.lens(focus: false, positive: true, speed: 7),
      ]) {
        expect(received, contains(equals(command)));
      }
      expect(controller.canOperate, true);
    });
  }

  test('rejected movement preserves saved limits and sends stops', () async {
    rejectMovement = true;
    await expectLater(
      controller.testAndSaveCameraLimits(camera),
      throwsStateError,
    );
    expect(store.cameras.single.limits, same(previous));
    expect(received, contains(equals(Visca.drive(12, 10, 3, 3))));
    expect(received, contains(equals(Visca.camera(7, [0]))));
  });

  test('unreadable positions preserve saved limits', () async {
    invalidPosition = true;
    await expectLater(
      controller.testAndSaveCameraLimits(camera),
      throwsStateError,
    );
    expect(store.cameras.single.limits, same(previous));
    expect([panDirection, tiltDirection, zoomDirection], [0, 0, 0]);
  });

  test(
    'a stationary camera cannot produce successful zero-width limits',
    () async {
      stationary = true;
      await expectLater(
        controller.testAndSaveCameraLimits(camera),
        throwsStateError,
      );
      expect(store.cameras.single.limits, same(previous));
      expect([panDirection, tiltDirection, zoomDirection], [0, 0, 0]);
    },
  );

  test('movement that never settles times out and stops', () async {
    neverStops = true;
    await expectLater(
      controller.testAndSaveCameraLimits(camera),
      throwsStateError,
    );
    expect(store.cameras.single.limits, same(previous));
    expect([panDirection, tiltDirection, zoomDirection], [0, 0, 0]);
  });

  for (final action in ['stop', 'pause', 'dispose']) {
    test('$action interrupts movement without replacing limits', () async {
      moved = Completer<void>();
      final operation = controller.testAndSaveCameraLimits(camera);
      final failed = expectLater(operation, throwsStateError);
      await moved!.future.timeout(const Duration(seconds: 2));
      if (action == 'stop') {
        await controller.stopAll();
      } else if (action == 'pause') {
        await controller.setPaused(true);
      } else {
        controller.dispose();
        disposed = true;
      }
      await failed;
      expect(store.cameras.single.limits, same(previous));
      expect([panDirection, tiltDirection, zoomDirection], [0, 0, 0]);
      expect(received, isNot(contains(equals(Visca.home))));
    });
  }

  test('waits for Home completion before saving measured limits', () async {
    holdHome = true;
    homeArrived = Completer<Datagram>();
    var finished = false;
    final operation = controller.testAndSaveCameraLimits(camera).then((limits) {
      finished = true;
      return limits;
    });
    final packet = await homeArrived!.future.timeout(
      const Duration(seconds: 2),
    );
    expect(finished, false);
    expect(store.cameras.single.limits, same(previous));
    pan = tilt = 0;
    server.send([0x90, 0x51, 255], packet.address, packet.port);
    expect((await operation).toJson(), measured.toJson());
    expect(finished, true);
    expect(store.cameras.single.limits!.toJson(), measured.toJson());
  });

  test('Home rejection preserves previous limits', () async {
    rejectHome = true;
    await expectLater(
      controller.testAndSaveCameraLimits(camera),
      throwsStateError,
    );
    expect(store.cameras.single.limits, same(previous));
    expect([panDirection, tiltDirection, zoomDirection], [0, 0, 0]);
  });

  test('Home timeout preserves previous limits and stops movement', () async {
    holdHome = true;
    await expectLater(
      controller.testAndSaveCameraLimits(camera),
      throwsStateError,
    );
    expect(store.cameras.single.limits, same(previous));
    expect([panDirection, tiltDirection, zoomDirection], [0, 0, 0]);
  });

  test('Stop test interrupts a Home command waiting for completion', () async {
    holdHome = true;
    homeArrived = Completer<Datagram>();
    final operation = controller.testAndSaveCameraLimits(camera);
    final failed = expectLater(operation, throwsStateError);
    await homeArrived!.future.timeout(const Duration(seconds: 2));
    await controller.stopAll();
    await failed;
    expect(store.cameras.single.limits, same(previous));
    expect([panDirection, tiltDirection, zoomDirection], [0, 0, 0]);
    expect(
      received.where((command) => listEquals(command, Visca.home)),
      hasLength(1),
    );
  });

  test('storage failure preserves old limits after a complete sweep', () async {
    store.fail = true;
    await expectLater(
      controller.testAndSaveCameraLimits(camera),
      throwsStateError,
    );
    expect(store.cameras.single.limits, same(previous));
    expect(controller.selected!.limits, same(previous));
    expect([panDirection, tiltDirection, zoomDirection], [0, 0, 0]);
  });

  test(
    'preset updates preserve camera limits and legacy configurations load',
    () {
      expect(camera.withPresets([]).limits, same(previous));
      final legacy = camera.toJson()..remove('limits');
      expect(Camera.fromJson(legacy).limits, isNull);
      final invalid = {...measured.toJson(), 'panMin': 50};
      expect(() => CameraLimits.fromJson(invalid), throwsFormatException);
    },
  );
}
