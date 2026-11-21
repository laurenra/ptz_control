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
  int? rejectInquiry;
  var malformedFocus = false;
  var rejectAperture = false;
  Completer<Datagram>? presetArrived;

  setUp(() async {
    rejectPreset = holdPreset = failStorage = false;
    presetArrived = null;
    rejectInquiry = null;
    malformedFocus = rejectAperture = false;
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
          if (data[3] == rejectInquiry) {
            reply([0x90, 0x60, 2, 255]);
            continue;
          }
          reply(switch (data[3]) {
            0x12 => [0x90, 0x50, 15, 15, 15, 14, 0, 0, 1, 0, 255],
            0x47 => [0x90, 0x50, 1, 2, 3, 4, 255],
            0x48 => [0x90, 0x50, 2, malformedFocus ? 16 : 3, 4, 5, 255],
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
            if (data[2] == 4 && data[3] == 0x4b) {
              if (rejectAperture) {
                reply([0x90, 0x60, 0x41, 255]);
                continue;
              }
              image[0x4b] = Visca.nibbles(data.sublist(4, 8));
            }
            reply([0x90, 0x41, 255]);
          }
          reply([0x90, 0x51, 255]);
        }
      }
    });
    store = _FailingStore([
      Camera(id: 1, name: 'Stage', host: '127.0.0.1', port: server.port),
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
    'save queries a fresh snapshot, persists it, then writes camera memory',
    () async {
      c.pan = c.tilt = c.zoom = 999;
      expect(await c.savePreset(2, '2 Podium\nExtra Wide'), true);
      expect(received, [
        Visca.panTiltInquiry,
        Visca.zoomInquiry,
        Visca.focusInquiry,
        Visca.exposureModeInquiry,
        [0x81, 1, 4, 0x3f, 1, 1, 255],
      ]);
      expect(cameraMemory[1], image);
      expect(c.preset(2)!.toJson(), {
        'slot': 2,
        'name': '2 Podium\nExtra Wide',
        'pan': -2,
        'tilt': 16,
        'zoom': 0x1234,
        'focus': 0x2345,
      });
      final restored = Camera.fromJson(store.cameras.single.toJson());
      expect(restored.presets.single.toJson(), c.preset(2)!.toJson());
      expect(await c.savePreset(2, '2 Podium Wide'), true);
      expect(c.selected!.presets.length, 1);
      expect(c.preset(2)!.name, '2 Podium Wide');
    },
  );

  test(
    'snapshot is persisted before camera save and committed after completion',
    () async {
      holdPreset = true;
      presetArrived = Completer<Datagram>();
      final save = c.savePreset(1, 'Await completion');
      final packet = await presetArrived!.future.timeout(
        const Duration(seconds: 1),
      );
      expect(c.presetBusy, true);
      expect(c.preset(1), isNull);
      expect(store.cameras.single.presets.single.focus, 0x2345);
      server.send([0x90, 0x51, 255], packet.address, packet.port);
      expect(await save, true);
      expect(c.preset(1)!.name, 'Await completion');
    },
  );

  test('rejected camera save leaves the previous name intact', () async {
    expect(await c.savePreset(1, 'Original'), true);
    rejectPreset = true;
    expect(await c.savePreset(1, 'Rejected'), false);
    expect(c.preset(1)!.name, 'Original');
    expect(store.cameras.single.presets.single.name, 'Original');
    expect(c.message, startsWith('Preset was not saved:'));
  });

  test('local storage failure prevents overwriting camera memory', () async {
    await c.savePreset(1, 'Original');
    received.clear();
    failStorage = true;
    image[0x4b] = 5;
    expect(await c.savePreset(1, 'New shot'), false);
    expect(cameraMemory[0]![0x4b], 9);
    expect(store.cameras.single.presets.single.name, 'Original');
    expect(c.preset(1)!.name, 'Original');
    expect(c.message, startsWith('Preset was not saved:'));
    expect(received.where((bytes) => bytes[1] == 1), isEmpty);
  });

  test(
    'manual iris snapshot survives persistence and is applied after recall',
    () async {
      c.setSaveExposureWithPreset(true);
      // Use the fresh camera mode and iris, rather than the displayed values.
      c.exposureMode = 0;
      c.imageValues[0x4b] = 1;
      expect(await c.savePreset(1, 'Manual shot'), true);
      expect(received, [
        Visca.panTiltInquiry,
        Visca.zoomInquiry,
        Visca.focusInquiry,
        Visca.exposureModeInquiry,
        Visca.apertureInquiry,
        Visca.storePreset(1),
      ]);
      final restored = Camera.fromJson(store.cameras.single.toJson());
      expect(restored.presets.single.aperture, 9);
      c.selected = restored;
      // Distinguish the app's iris snapshot from the camera's own memory.
      cameraMemory[0]![0x4b] = 2;
      received.clear();
      expect(await c.recallPreset(1), true);
      expect(received, [Visca.recallPreset(1), Visca.absoluteAperture(9)]);
      expect(image[0x4b], 9);
      expect(c.aperture, 9);
    },
  );

  test('unchecked exposure option only recalls camera memory', () async {
    c.setSaveExposureWithPreset(true);
    await c.savePreset(1, 'Manual');
    c.setSaveExposureWithPreset(false);
    received.clear();
    expect(await c.recallPreset(1), true);
    expect(received, [Visca.recallPreset(1)]);
  });

  test('nonmanual modes never save or apply an iris snapshot', () async {
    c.setSaveExposureWithPreset(true);
    for (final mode in [0, 10, 11]) {
      image[0x39] = mode;
      c.exposureMode = 3;
      received.clear();
      expect(await c.savePreset(1, 'Automatic'), true);
      expect(c.preset(1)!.aperture, isNull);
      expect(received, isNot(contains(equals(Visca.apertureInquiry))));
      received.clear();
      expect(await c.recallPreset(1), true);
      expect(received, [Visca.recallPreset(1)]);
    }
  });

  test('resaving without exposure removes an older iris snapshot', () async {
    c.setSaveExposureWithPreset(true);
    await c.savePreset(1, 'With exposure');
    c.setSaveExposureWithPreset(false);
    await c.savePreset(1, 'Without exposure');
    expect(c.preset(1)!.aperture, isNull);
    c.setSaveExposureWithPreset(true);
    received.clear();
    expect(await c.recallPreset(1), true);
    expect(received, [Visca.recallPreset(1)]);
  });

  test(
    'failed snapshot inquiries prevent both local and camera saves',
    () async {
      c.setSaveExposureWithPreset(true);
      for (final register in [0x12, 0x47, 0x48, 0x39, 0x4b]) {
        rejectInquiry = register;
        received.clear();
        expect(await c.savePreset(1, 'Failed read'), false);
        expect(c.preset(1), isNull);
        expect(store.cameras.single.presets, isEmpty);
        expect(received.where((bytes) => bytes[1] == 1), isEmpty);
      }
    },
  );

  test('malformed focus nibbles prevent saving a corrupt snapshot', () async {
    malformedFocus = true;
    expect(await c.savePreset(1, 'Invalid focus'), false);
    expect(c.preset(1), isNull);
    expect(received.where((bytes) => bytes[1] == 1), isEmpty);
  });

  test('iris restore errors report an incomplete recall', () async {
    c.setSaveExposureWithPreset(true);
    await c.savePreset(1, 'Manual');
    rejectAperture = true;
    expect(await c.recallPreset(1), false);
    expect(c.message, startsWith('Preset recall did not finish:'));
  });

  test(
    'recall completion must arrive before the saved iris is applied',
    () async {
      c.setSaveExposureWithPreset(true);
      await c.savePreset(1, 'Manual');
      holdPreset = true;
      presetArrived = Completer<Datagram>();
      received.clear();
      final recall = c.recallPreset(1);
      final packet = await presetArrived!.future.timeout(
        const Duration(seconds: 1),
      );
      expect(received, [Visca.recallPreset(1)]);
      server.send([0x90, 0x51, 255], packet.address, packet.port);
      expect(await recall, true);
      expect(received, [Visca.recallPreset(1), Visca.absoluteAperture(9)]);
    },
  );

  test(
    'preset dialog refresh reads current exposure mode and aperture',
    () async {
      image[0x39] = 10;
      image[0x4b] = 12;
      await c.refreshPresetSettings();
      expect(received, [Visca.exposureModeInquiry, Visca.apertureInquiry]);
      expect(c.exposureMode, 10);
      expect(c.aperture, 12);
    },
  );

  test(
    'unnamed camera presets recall and camera errors are reported',
    () async {
      c.setSaveExposureWithPreset(true);
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
    'unchecked exposure saving leaves image settings to camera memory',
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

  test(
    'stop cancels a camera recall without restoring its saved iris',
    () async {
      c.setSaveExposureWithPreset(true);
      await c.savePreset(9, 'Manual');
      received.clear();
      holdPreset = true;
      presetArrived = Completer<Datagram>();
      final recall = c.recallPreset(9);
      await presetArrived!.future.timeout(const Duration(seconds: 1));
      expect(c.presetBusy, true);
      await c.stopAll().timeout(const Duration(seconds: 1));
      expect(await recall, false);
      expect(c.presetBusy, false);
      expect(received, isNot(contains(equals(Visca.absoluteAperture(9)))));
      expect(received, contains(equals(Visca.drive(8, 6, 3, 3))));
      expect(
        received.where((b) => b[1] == 1 && b[2] == 4 && b[3] == 0x3f).length,
        1,
      );
    },
  );

  test('loads snapshots and supports older name-only presets', () {
    final legacy = CameraPreset.fromJson({
      'slot': 3,
      'name': '3 Wide',
      'pan': -2,
      'tilt': 16,
      'zoom': 0x1234,
      'aperture': 9,
    });
    expect(legacy.toJson(), {
      'slot': 3,
      'name': '3 Wide',
      'pan': -2,
      'tilt': 16,
      'zoom': 0x1234,
      'aperture': 9,
    });
    expect(CameraPreset.fromJson({'slot': 1, 'name': 'Old preset'}).toJson(), {
      'slot': 1,
      'name': 'Old preset',
    });
    for (final entry in {
      'pan': 32768,
      'tilt': -32769,
      'zoom': -1,
      'focus': 65536,
      'aperture': 256,
    }.entries) {
      expect(
        () => CameraPreset.fromJson({
          'slot': 1,
          'name': 'Invalid',
          entry.key: entry.value,
        }),
        throwsFormatException,
      );
    }
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
  Future<void> save(List<Camera> cameras, {int? nextId}) async {
    if (fail()) throw StateError('Test storage failure');
    await super.save(cameras, nextId: nextId);
  }
}
