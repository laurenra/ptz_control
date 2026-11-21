import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ptz_control/controller.dart';
import 'package:ptz_control/models/camera.dart';
import 'package:ptz_control/models/camera_limits.dart';
import 'package:ptz_control/services/visca_protocol.dart';

import 'visca_client_test.dart' show MemoryStore;

void main() {
  late RawDatagramSocket server;
  late StreamSubscription<RawSocketEvent> subscription;
  late StreamController<List<int>> drives;
  late PtzController c;
  late Camera camera;
  late List<List<int>> received;
  int pan = 0, tilt = 0;
  bool rejectMovement = false, failPosition = false, malformedPosition = false;
  bool disposed = false;
  bool dropPosition = false;
  Completer<Datagram>? heldPosition;

  bool isStop(List<int> command) => command[6] == 3 && command[7] == 3;
  Future<List<int>> nextDrive(
    bool Function(List<int>) predicate, {
    int seconds = 2,
  }) => drives.stream.firstWhere(predicate).timeout(Duration(seconds: seconds));
  Future<void> until(bool Function() predicate) async {
    if (predicate()) return;
    final done = Completer<void>();
    void listener() {
      if (!done.isCompleted && predicate()) done.complete();
    }

    c.addListener(listener);
    try {
      await done.future.timeout(const Duration(seconds: 2));
    } finally {
      c.removeListener(listener);
    }
  }

  setUp(() async {
    pan = tilt = 0;
    rejectMovement = failPosition = malformedPosition = disposed = false;
    heldPosition = null;
    dropPosition = false;
    received = [];
    drives = StreamController<List<int>>.broadcast(sync: true);
    server = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    subscription = server.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? packet;
      while ((packet = server.receive()) != null) {
        final p = packet!;
        final data = p.data.toList();
        received.add(data);
        void reply(List<int> response) =>
            server.send(response, p.address, p.port);
        if (data[1] == 9) {
          if (data[3] == 0x12) {
            if (dropPosition) continue;
            if (heldPosition?.isCompleted == false) {
              heldPosition!.complete(p);
              continue;
            }
            if (failPosition) {
              reply([0x90, 0x60, 0x41, 255]);
              continue;
            }
            final position = [
              0x90,
              0x50,
              ...Visca.positionNibbles(pan, signed: true),
              ...Visca.positionNibbles(tilt, signed: true),
              255,
            ];
            if (malformedPosition) position[2] = 16;
            reply(position);
          } else {
            reply(
              data[3] == 0x47 || Visca.imageValueInquiries.containsKey(data[3])
                  ? [0x90, 0x50, 0, 0, 0, 1, 255]
                  : [0x90, 0x50, 3, 255],
            );
          }
        } else {
          if (data[2] == 6 && data[3] == 1) {
            drives.add(data);
            if (rejectMovement && !isStop(data)) {
              reply([0x90, 0x60, 0x41, 255]);
              continue;
            }
          }
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
      limits: const CameraLimits(
        panMin: -10,
        panMax: 10,
        tiltMin: -20,
        tiltMax: 20,
        zoomMin: 0,
        zoomMax: 100,
      ),
    );
    c = PtzController(store: MemoryStore([camera]));
    await c.initialize();
    received.clear();
  });

  tearDown(() async {
    if (!disposed) {
      await c.endMotion();
      c.dispose();
    }
    await subscription.cancel();
    server.close();
    await drives.close();
  });

  test('held mode uses selected speeds and stops only for its owner', () async {
    expect(c.moveUntilStopped, false);
    c.setSpeed('Pan', 14);
    c.setSpeed('Tilt', 7);
    final moved = nextDrive((d) => !isStop(d));
    expect(c.startPanTilt('Right', 2, 3, owner: 'right'), true);
    expect(await moved, Visca.drive(14, 7, 2, 3));
    await c.endMotion(owner: 'different');
    expect(c.moving, true);
    final stopped = nextDrive(isStop);
    await c.endMotion(owner: 'right');
    expect(await stopped, Visca.drive(14, 7, 3, 3));
    expect(c.moving, false);
  });

  for (final bound in [
    (-10, 0, 1, 3),
    (10, 0, 2, 3),
    (0, 20, 3, 1),
    (0, -20, 3, 2),
  ]) {
    test('fresh position prevents moving outward at limit $bound', () async {
      pan = bound.$1;
      tilt = bound.$2;
      c.pan = c.tilt = 0; // Deliberately stale UI telemetry.
      final stopped = nextDrive(isStop);
      expect(c.startPanTilt('At bound', bound.$3, bound.$4), true);
      await stopped;
      expect(c.moving, false);
      expect(
        received
            .where((p) => p[1] == 1 && p[2] == 6 && p[3] == 1)
            .every(isStop),
        true,
      );
    });
  }

  for (final continuous in [false, true]) {
    test(
      'diagonal move stops each axis at its limit, continuous=$continuous',
      () async {
        c.setMoveUntilStopped(continuous);
        final moved = nextDrive((d) => d[6] == 2 && d[7] == 1);
        c.startPanTilt('Up right', 2, 1);
        await moved;
        final panStopped = nextDrive((d) => d[6] == 3 && d[7] == 1);
        pan = 10;
        await panStopped;
        expect(c.moving, true);
        final allStopped = nextDrive(isStop);
        tilt = 20;
        await allStopped;
        expect(c.moving, false);
        final afterStop = received.length;
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(received.length, afterStop);
      },
    );
  }

  test(
    'initially blocked diagonal axis stays stopped while the other moves',
    () async {
      pan = 10;
      final moved = nextDrive((d) => d[6] == 3 && d[7] == 1);
      c.startPanTilt('Up right', 2, 1);
      await moved;
      expect(received, isNot(contains(equals(Visca.drive(8, 6, 2, 1)))));
    },
  );

  test(
    'continuous direction changes stop the previous direction first',
    () async {
      c.setMoveUntilStopped(true);
      var moved = nextDrive((d) => d[6] == 2 && d[7] == 3);
      c.startPanTilt('Right', 2, 3);
      await moved;
      final previousStopped = nextDrive(isStop);
      moved = nextDrive((d) => d[6] == 3 && d[7] == 1);
      expect(c.startPanTilt('Up', 3, 1), true);
      await previousStopped;
      await moved;
      await c.endMotion(owner: 'Right');
      expect(c.moving, true);
      final stopped = nextDrive(isStop);
      c.setMoveUntilStopped(false);
      await stopped;
      expect(c.moving, false);
    },
  );

  test(
    'release during a pending initial inquiry prevents a queued move',
    () async {
      heldPosition = Completer<Datagram>();
      c.startPanTilt('Right', 2, 3);
      final packet = await heldPosition!.future.timeout(
        const Duration(seconds: 2),
      );
      final stopped = nextDrive(isStop);
      await c.endMotion();
      await stopped;
      server.send(
        [0x90, 0x50, 0, 0, 0, 0, 0, 0, 0, 0, 255],
        packet.address,
        packet.port,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        received
            .where((p) => p[1] == 1 && p[2] == 6 && p[3] == 1)
            .every(isStop),
        true,
      );
    },
  );

  for (final failure in [
    'read error',
    'no position reply',
    'malformed position',
    'movement error',
  ]) {
    test('$failure stops movement and reports the failure', () async {
      final moved = nextDrive((d) => !isStop(d));
      if (failure == 'movement error') rejectMovement = true;
      c.startPanTilt('Right', 2, 3);
      await moved;
      if (failure == 'read error') failPosition = true;
      if (failure == 'no position reply') dropPosition = true;
      if (failure == 'malformed position') malformedPosition = true;
      await until(() => c.message?.startsWith('Movement stopped:') == true);
      expect(c.moving, false);
      expect(received, contains(equals(Visca.drive(8, 6, 3, 3))));
    });
  }

  test(
    'without saved limits unchanged position stops continuous movement',
    () async {
      final noLimits = Camera(
        id: 1,
        name: camera.name,
        host: camera.host,
        port: camera.port,
      );
      c.cameras = [noLimits];
      await c.select(noLimits);
      received.clear();
      c.setMoveUntilStopped(true);
      final moved = nextDrive((d) => !isStop(d));
      final stopped = nextDrive(isStop, seconds: 4);
      c.startPanTilt('Right', 2, 3);
      await moved;
      await stopped;
      expect(c.moving, false);
      expect(
        received.where(
          (p) => p[1] == 1 && p[2] == 6 && p[3] == 1 && !isStop(p),
        ),
        hasLength(1),
      );
    },
  );

  for (final action in ['stop', 'pause', 'switch', 'dispose']) {
    test('$action cancels continuous motion and its monitoring', () async {
      c.setMoveUntilStopped(true);
      final moved = nextDrive((d) => !isStop(d));
      c.startPanTilt('Right', 2, 3);
      await moved;
      final stopped = nextDrive(isStop);
      switch (action) {
        case 'stop':
          await c.stopAll();
        case 'pause':
          await c.setPaused(true);
        case 'switch':
          await c.select(
            Camera(id: 2, name: 'Other', host: camera.host, port: camera.port),
          );
        case 'dispose':
          c.dispose();
          disposed = true;
      }
      await stopped;
      expect(c.moving, false);
      final moves = received
          .where((p) => p[1] == 1 && p[2] == 6 && p[3] == 1 && !isStop(p))
          .length;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(
        received.where(
          (p) => p[1] == 1 && p[2] == 6 && p[3] == 1 && !isStop(p),
        ),
        hasLength(moves),
      );
    });
  }
}
