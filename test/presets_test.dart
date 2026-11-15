import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ptz_control/controller.dart';
import 'package:ptz_control/models/camera.dart';
import 'package:ptz_control/models/camera_preset.dart';
import 'package:ptz_control/services/visca_protocol.dart';

import 'visca_client_test.dart' show MemoryStore;

void main() {
  late RawDatagramSocket server;
  late StreamSubscription<RawSocketEvent> subscription;
  late PtzController c;
  late MemoryStore store;
  late List<List<int>> received;
  var rejectIris = false;
  var holdMove = false;
  var failStorage = false;
  Completer<void>? moveArrived;

  setUp(() async {
    rejectIris = holdMove = failStorage = false;
    moveArrived = null;
    server = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    received = [];
    subscription = server.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? d;
      while ((d = server.receive()) != null) {
        final packet = d!;
        final data = packet.data.toList();
        received.add(data);
        void reply(List<int> bytes) =>
            server.send(bytes, packet.address, packet.port);
        if (data[1] == 9) {
          reply(switch (data[3]) {
            0x12 => [0x90, 0x50, 15, 15, 15, 14, 0, 0, 1, 0, 255],
            0x47 => [0x90, 0x50, 1, 2, 3, 4, 255],
            0x4b =>
              rejectIris ? [0x90, 0x60, 2, 255] : [0x90, 0x50, 0, 0, 0, 9, 255],
            0x39 => [0x90, 0x50, 0, 255],
            0x4a || 0x4c || 0x43 || 0x44 => [0x90, 0x50, 0, 0, 0, 0, 255],
            _ => [0x90, 0x50, 3, 255],
          });
        } else {
          reply([0x90, 0x41, 255]);
          if (data[2] == 6 && data[3] == 2 && holdMove) {
            if (moveArrived?.isCompleted == false) moveArrived!.complete();
          } else {
            reply([0x90, 0x51, 255]);
          }
        }
      }
    });
    store = _FailingStore([
      Camera(id: 'a', name: 'Stage', host: '127.0.0.1', port: server.port),
    ], () => failStorage);
    c = PtzController(store: store);
    await c.initialize();
    received.clear();
  });
  tearDown(() async {
    c.dispose();
    await subscription.cancel();
    server.close();
  });

  test('sync links both axes, clamps to shared range, and restores independent pan range', () {
    c.setSpeed('Pan', 24);
    c.setSyncPanTilt(true);
    expect([c.panSpeed, c.tiltSpeed], [20, 20]);
    c.setSpeed('Tilt', 3);
    expect([c.panSpeed, c.tiltSpeed], [3, 3]);
    c.setSpeed('Pan', 14);
    expect([c.panSpeed, c.tiltSpeed], [14, 14]);
    c.setSyncPanTilt(false);
    c.setSpeed('Pan', 24);
    expect([c.panSpeed, c.tiltSpeed], [24, 14]);
  });

  test(
    'save queries fresh PTZ and persists names and optional iris per camera',
    () async {
      c.pan = 999;
      c.tilt = 999;
      c.zoom = 999;
      c.setSaveAperture(true);
      expect(await c.savePreset(2, '2 Podium\nExtra Wide'), true);
      final preset = c.preset(2)!;
      expect(
        [preset.pan, preset.tilt, preset.zoom, preset.aperture],
        [-2, 16, 0x1234, 9],
      );
      expect(preset.name, '2 Podium\nExtra Wide');
      expect(store.cameras.single.presets.single.toJson(), preset.toJson());
      expect(received, contains(equals(Visca.apertureInquiry)));
      final restored = Camera.fromJson(store.cameras.single.toJson());
      expect(restored.presets.single.toJson(), preset.toJson());
      c.setSaveAperture(false);
      expect(await c.savePreset(2, '2 Podium Wide'), true);
      expect(c.selected!.presets.length, 1);
      expect(c.preset(2)!.aperture, isNull);
    },
  );

  test('failed iris query or storage leaves existing preset intact', () async {
    expect(await c.savePreset(1, 'Original'), true);
    c.setSaveAperture(true);
    rejectIris = true;
    expect(await c.savePreset(1, 'Bad iris'), false);
    expect(c.preset(1)!.name, 'Original');
    c.setSaveAperture(false);
    failStorage = true;
    expect(await c.savePreset(1, 'Bad storage'), false);
    expect(c.preset(1)!.name, 'Original');
  });

  test('recall without aperture sends only PTZ and rejects empty slots without motion', () async {
    expect(await c.recallPreset(9), false);
    expect(received, isEmpty);
    await c.savePreset(1, '1 Podium Wide');
    received.clear();
    expect(await c.recallPreset(1), true);
    final commands = received.where((bytes) => bytes[1] == 1).toList();
    expect(commands, [
      Visca.absolutePanTilt(-2, 16, 8, 6),
      Visca.absoluteZoom(0x1234),
    ]);
  });

  test('aperture recall establishes iris priority, then completes iris, pan/tilt and zoom', () async {
    c.setSaveAperture(true);
    await c.savePreset(1, '1 Podium Wide');
    c.setSaveAperture(
      false,
    ); // Recall follows the saved snapshot, not this toggle.
    received.clear();
    expect(await c.recallPreset(1), true);
    expect(received.where((bytes) => bytes[1] == 1).toList(), [
      Visca.camera(0x39, [11]),
      Visca.absoluteAperture(9),
      Visca.absolutePanTilt(-2, 16, 8, 6),
      Visca.absoluteZoom(0x1234),
    ]);
  });

  test(
    'stop cancels a recall waiting for completion and prevents subsequent zoom',
    () async {
      await c.savePreset(1, 'Stop test');
      received.clear();
      holdMove = true;
      moveArrived = Completer<void>();
      final recall = c.recallPreset(1);
      await moveArrived!.future.timeout(const Duration(seconds: 1));
      expect(c.presetBusy, true);
      await c.stopAll().timeout(const Duration(seconds: 1));
      expect(await recall, false);
      expect(c.presetBusy, false);
      expect(
        received.where((b) => b[1] == 1),
        isNot(contains(equals(Visca.absoluteZoom(0x1234)))),
      );
      expect(received, contains(equals(Visca.drive(8, 6, 3, 3))));
    },
  );

  test(
    'validates two-line preset names and encodes signed snapshot coordinates',
    () {
      expect(CameraPreset.validateName('1 Podium\nExtra Wide'), isNull);
      expect(CameraPreset.validateName('one\ntwo\nthree'), isNotNull);
      expect(CameraPreset.validateName(' '), isNotNull);
      expect(Visca.absolutePanTilt(-2, 16, 8, 6), [
        0x81,
        1,
        6,
        2,
        8,
        6,
        15,
        15,
        15,
        14,
        0,
        0,
        1,
        0,
        255,
      ]);
      expect(Visca.absoluteAperture(0xab), [
        0x81,
        1,
        4,
        0x4b,
        0,
        0,
        10,
        11,
        255,
      ]);
    },
  );
}

class _FailingStore extends MemoryStore {
  _FailingStore(super.cameras, this.fail);
  final bool Function() fail;
  @override
  Future<void> save(List<Camera> cameras) async {
    if (fail()) throw StateError('Test storage failure');
    await super.save(cameras);
  }
}
