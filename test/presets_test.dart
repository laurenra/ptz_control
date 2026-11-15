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
  late _FailingStore store;
  late List<List<int>> received;
  late Map<int, int> image;
  late Map<int, Map<int, int>> cameraMemory;
  var rejectPreset = false;
  var holdPreset = false;
  var failStorage = false;
  Completer<Datagram>? presetArrived;

  setUp(() async {
    rejectPreset = holdPreset = failStorage = false;
    presetArrived = null;
    image = {0x39: 3, 0x4b: 9, 0x4a: 22, 0x4c: 4, 0x43: 128, 0x44: 129};
    // A preset created outside this app can be recalled without a local name.
    cameraMemory = {
      8: {...image},
    };
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
            0x39 => [0x90, 0x50, image[0x39]!, 255],
            0x4a || 0x4b || 0x4c || 0x43 || 0x44 => [
              0x90,
              0x50,
              ...Visca.positionNibbles(image[data[3]]!),
              255,
            ],
            _ => [0x90, 0x50, 3, 255],
          });
        } else {
          if (data[2] == 4 && data[3] == 0x3f) {
            if (rejectPreset ||
                data[4] == 2 && !cameraMemory.containsKey(data[5])) {
              reply([0x90, 0x60, 0x41, 255]);
              continue;
            }
            reply([0x90, 0x41, 255]);
            if (holdPreset) {
              if (presetArrived?.isCompleted == false) {
                presetArrived!.complete(packet);
              }
              continue;
            }
            if (data[4] == 1) {
              cameraMemory[data[5]] = {...image};
            } else if (data[4] == 2) {
              image = {...cameraMemory[data[5]]!};
            }
          } else {
            reply([0x90, 0x41, 255]);
          }
          reply([0x90, 0x51, 255]);
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

  test('save writes camera memory and persists only the local name', () async {
    c.pan = c.tilt = c.zoom = 999;
    expect(await c.savePreset(2, '2 Podium\nExtra Wide'), true);
    expect(received, [
      [0x81, 1, 4, 0x3f, 1, 1, 255],
    ]);
    expect(cameraMemory[1], image);
    expect(c.preset(2)!.toJson(), {'slot': 2, 'name': '2 Podium\nExtra Wide'});
    final restored = Camera.fromJson(store.cameras.single.toJson());
    expect(restored.presets.single.toJson(), c.preset(2)!.toJson());
    expect(await c.savePreset(2, '2 Podium Wide'), true);
    expect(c.selected!.presets.length, 1);
    expect(c.preset(2)!.name, '2 Podium Wide');
  });

  test('camera save must complete before the local name is replaced', () async {
    holdPreset = true;
    presetArrived = Completer<Datagram>();
    final save = c.savePreset(1, 'Await completion');
    final packet = await presetArrived!.future.timeout(
      const Duration(seconds: 1),
    );
    expect(c.presetBusy, true);
    expect(c.preset(1), isNull);
    server.send([0x90, 0x51, 255], packet.address, packet.port);
    expect(await save, true);
    expect(c.preset(1)!.name, 'Await completion');
  });

  test('rejected camera save leaves the previous name intact', () async {
    expect(await c.savePreset(1, 'Original'), true);
    rejectPreset = true;
    expect(await c.savePreset(1, 'Rejected'), false);
    expect(c.preset(1)!.name, 'Original');
    expect(c.message, startsWith('Preset was not saved:'));
  });

  test('local storage failure reports a successful camera save with a name warning', () async {
    await c.savePreset(1, 'Original');
    failStorage = true;
    image[0x4b] = 5;
    expect(await c.savePreset(1, 'Session name'), true);
    expect(cameraMemory[0]![0x4b], 5);
    expect(store.cameras.single.presets.single.name, 'Original');
    expect(c.preset(1)!.name, 'Session name');
    expect(c.message, contains('saved in the camera'));
    expect(c.message, contains('name could not be saved locally'));
  });

  test(
    'unnamed camera presets recall and camera errors are reported',
    () async {
      expect(c.preset(9), isNull);
      expect(await c.recallPreset(9), true);
      expect(received.where((bytes) => bytes[1] == 1), [
        [0x81, 1, 4, 0x3f, 2, 8, 255],
      ]);
      expect(await c.recallPreset(8), false);
      expect(c.message, startsWith('Preset recall did not finish:'));
    },
  );

  test(
    'manual exposure and image settings are restored by camera memory recall',
    () async {
      final savedImage = {...image};
      await c.savePreset(1, 'Manual shot');
      image.updateAll((key, value) => 0);
      received.clear();
      expect(await c.recallPreset(1), true);
      expect(image, savedImage);
      expect(received.where((bytes) => bytes[1] == 1), [
        [0x81, 1, 4, 0x3f, 2, 0, 255],
      ]);
    },
  );

  test('stop cancels a camera recall waiting for completion', () async {
    holdPreset = true;
    presetArrived = Completer<Datagram>();
    final recall = c.recallPreset(9);
    await presetArrived!.future.timeout(const Duration(seconds: 1));
    expect(c.presetBusy, true);
    await c.stopAll().timeout(const Duration(seconds: 1));
    expect(await recall, false);
    expect(c.presetBusy, false);
    expect(received, contains(equals(Visca.drive(8, 6, 3, 3))));
    expect(
      received.where((b) => b[1] == 1 && b[2] == 4 && b[3] == 0x3f).length,
      1,
    );
  });

  test('keeps legacy preset names and discards application snapshots', () {
    final legacy = CameraPreset.fromJson({
      'slot': 3,
      'name': '3 Wide',
      'pan': -2,
      'tilt': 16,
      'zoom': 0x1234,
      'aperture': 9,
    });
    expect(legacy.toJson(), {'slot': 3, 'name': '3 Wide'});
    expect(CameraPreset.validateName('1 Podium\nExtra Wide'), isNull);
    expect(CameraPreset.validateName('one\ntwo\nthree'), isNotNull);
    expect(CameraPreset.validateName(' '), isNotNull);
    expect(
      () => CameraPreset.fromJson({'slot': 10, 'name': 'Bad slot'}),
      throwsFormatException,
    );
  });
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
