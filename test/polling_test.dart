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
  late PtzController c;
  late Camera camera;
  late List<List<int>> received;
  int focusMode = 2;
  Completer<Datagram>? holdExposure;
  Completer<Datagram>? holdCommand;
  void Function(int)? onInquiry;

  setUp(() async {
    focusMode = 2;
    holdExposure = null;
    holdCommand = null;
    onInquiry = null;
    received = [];
    server = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    subscription = server.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? packet;
      while ((packet = server.receive()) != null) {
        final p = packet!;
        final data = p.data.toList();
        received.add(data);
        if (data[1] == 9) {
          if (data[3] == 0x39 && holdExposure?.isCompleted == false) {
            holdExposure!.complete(p);
            continue;
          }
          final response = switch (data[3]) {
            0x12 => [0x90, 0x50, 0, 0, 0, 1, 0, 0, 0, 2, 255],
            0x47 => [0x90, 0x50, 0, 0, 0, 3, 255],
            0x38 => [0x90, 0x50, focusMode, 255],
            0x39 => [0x90, 0x50, 3, 255],
            0x35 => [0x90, 0x50, 5, 255],
            _ => [0x90, 0x50, 0, 0, 0, 9, 255],
          };
          server.send(response, p.address, p.port);
          onInquiry?.call(data[3]);
        } else {
          server.send([0x90, 0x41, 255], p.address, p.port);
          if (holdCommand?.isCompleted == false) {
            holdCommand!.complete(p);
            continue;
          }
          server.send([0x90, 0x51, 255], p.address, p.port);
        }
      }
    });
    camera = Camera(
      id: 'a',
      name: 'Stage',
      host: '127.0.0.1',
      port: server.port,
    );
    c = PtzController(store: MemoryStore([camera]));
    await c.initialize();
  });
  tearDown(() async {
    c.dispose();
    await subscription.cancel();
    server.close();
  });

  List<int> inquiries() =>
      received.where((p) => p[1] == 9).map((p) => p[3]).toList();
  const imageRegisters = [0x38, 0x39, 0x35, 0x4b, 0x4a, 0x4c, 0x43, 0x44];
  const allRegisters = [
    0x38,
    0x12,
    0x47,
    0x39,
    0x35,
    0x4b,
    0x4a,
    0x4c,
    0x43,
    0x44,
  ];

  test(
    'switching cameras reads fresh focus mode before other settings',
    () async {
      expect(c.autofocus, true);
      final modesBeforeReply = <bool?>[];
      onInquiry = (register) {
        if (register == 0x38) modesBeforeReply.add(c.autofocus);
      };
      final manualCamera = Camera(
        id: 'b',
        name: 'Manual camera',
        host: camera.host,
        port: camera.port,
      );
      received.clear();
      focusMode = 3;
      await c.select(manualCamera);
      expect(inquiries().first, 0x38);
      expect(inquiries().where((register) => register == 0x38), hasLength(1));
      expect(c.autofocus, false);

      received.clear();
      focusMode = 2;
      await c.select(camera);
      expect(inquiries().first, 0x38);
      expect(inquiries().where((register) => register == 0x38), hasLength(1));
      expect(c.autofocus, true);
      expect(modesBeforeReply, [null, null]);
    },
  );

  test('selection and Refresh read everything, page entry reads displayed settings only', () async {
    expect(inquiries(), allRegisters);
    received.clear();
    await c.refreshImageSettings();
    expect(inquiries(), imageRegisters);
    received.clear();
    await c.refreshControlStatus();
    expect(inquiries(), [0x38, 0x39, 0x35]);
    received.clear();
    await c.refresh();
    expect(inquiries(), allRegisters);
    received.clear();
    await c.select(
      Camera(id: 'b', name: 'Other', host: camera.host, port: camera.port),
    );
    expect(inquiries(), allRegisters);
  });

  test(
    'changing a setting reads only that setting after command completion',
    () async {
      for (final change in [
        (0x39, 3, 0x39),
        (0x35, 5, 0x35),
        (0x38, 2, 0x38),
        (0x0b, 2, 0x4b),
        (0x0a, 3, 0x4a),
        (0x0c, 2, 0x4c),
        (3, 2, 0x43),
        (4, 3, 0x44),
      ]) {
        received.clear();
        final command = Visca.camera(change.$1, [change.$2]);
        await c.command('Change image setting', command);
        expect(received, [
          command,
          [0x81, 9, 4, change.$3, 255],
        ]);
      }
      expect(c.exposureMode, 3);
      expect(c.whiteBalanceMode, 5);
      expect(c.autofocus, true);
      expect(
        [c.aperture, c.shutterSpeed, c.gain, c.redGain, c.blueGain],
        [9, 9, 9, 9, 9],
      );
      received.clear();
      await c.command('One-push white balance', Visca.camera(0x10, [5]));
      expect(inquiries(), [0x35, 0x43, 0x44]);
    },
  );

  test(
    'changed setting is queried after completion, rather than ACK',
    () async {
      received.clear();
      holdCommand = Completer<Datagram>();
      final changed = c.command('Increase aperture', Visca.camera(0x0b, [2]));
      final packet = await holdCommand!.future.timeout(
        const Duration(seconds: 1),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(inquiries(), isEmpty);
      server.send([0x90, 0x51, 255], packet.address, packet.port);
      await changed;
      expect(inquiries(), [0x4b]);
    },
  );

  test(
    'a setting read is retained when another refresh is already running',
    () async {
      received.clear();
      holdExposure = Completer<Datagram>();
      final status = c.refreshControlStatus();
      final packet = await holdExposure!.future.timeout(
        const Duration(seconds: 1),
      );
      final changed = c.command('Increase gain', Visca.camera(0x0c, [2]));
      server.send([0x90, 0x50, 3, 255], packet.address, packet.port);
      await Future.wait([status, changed]);
      expect(inquiries(), [0x38, 0x39, 0x35, 0x4c]);
      expect(c.gain, 9);
    },
  );

  test('automatic polling is PTZ only every five seconds, with no motion-triggered reads', () async {
    received.clear();
    await c.command('Return home', Visca.home);
    c.startMotion(
      'Pan right',
      Visca.drive(8, 6, 2, 3),
      Visca.drive(8, 6, 3, 3),
    );
    await c.endMotion();
    c.startMotion(
      'Zoom in',
      Visca.lens(focus: false, positive: true, speed: 3),
      Visca.camera(7, [0]),
    );
    await c.endMotion();
    await c.recallPreset(1);
    final firstPoll = Completer<void>();
    final secondPoll = Completer<void>();
    var zoomQueries = 0;
    onInquiry = (register) {
      if (register != 0x47) return;
      zoomQueries++;
      if (zoomQueries == 1) firstPoll.complete();
      if (zoomQueries == 2) secondPoll.complete();
    };
    await Future<void>.delayed(const Duration(milliseconds: 2100));
    expect(inquiries(), isEmpty);
    await firstPoll.future.timeout(const Duration(seconds: 4));
    expect(inquiries(), [0x12, 0x47]);
    await secondPoll.future.timeout(const Duration(seconds: 6));
    expect(inquiries(), [0x12, 0x47, 0x12, 0x47]);
    expect(c.connection, CameraConnection.connected);
  });
}
