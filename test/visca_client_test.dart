import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ptz_control/controller.dart';
import 'package:ptz_control/models/camera.dart';
import 'package:ptz_control/services/camera_store.dart';
import 'package:ptz_control/services/visca_client.dart';
import 'package:ptz_control/services/visca_protocol.dart';

class MemoryStore implements CameraStore {
  MemoryStore(this.cameras);
  List<Camera> cameras;
  @override
  Future<List<Camera>> load() async => cameras;
  @override
  Future<void> save(List<Camera> value) async {
    cameras = value;
  }
}

void main() {
  late RawDatagramSocket server;
  late Camera camera;
  late List<List<int>> received;
  StreamSubscription<RawSocketEvent>? subscription;

  setUp(() async {
    server = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    camera = Camera(
      id: '1',
      name: 'Local test',
      host: '127.0.0.1',
      port: server.port,
    );
    received = [];
  });
  tearDown(() async {
    await subscription?.cancel();
    server.close();
  });

  void serve(void Function(Datagram) callback) {
    subscription = server.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? packet;
      while ((packet = server.receive()) != null) {
        received.add(packet!.data.toList());
        callback(packet);
      }
    });
  }

  test(
    'raw UDP inquiries read actual replies and log full endpoints',
    () async {
      serve(
        (packet) => server.send(
          [0x90, 0x50, 1, 2, 3, 4, 255],
          packet.address,
          packet.port,
        ),
      );
      final logs = <CommandLog>[];
      var replies = 0;
      final client = ViscaClient(
        camera,
        onLog: logs.add,
        onReply: () => replies++,
        onError: (_) {},
      );
      addTearDown(client.close);
      await client.open();
      final reply = await client.send('Zoom', Visca.zoomInquiry);
      expect(reply, [0x90, 0x50, 1, 2, 3, 4, 255]);
      expect(replies, 1);
      expect(logs.map((l) => l.direction), ['TX', 'RX']);
      expect(logs.every((l) => l.endpoint == camera.endpoint), isTrue);
    },
  );

  test('Sony ignores wrong sequence before accepting matching reply', () async {
    camera = Camera(
      id: '1',
      name: 'Sony test',
      host: camera.host,
      port: camera.port,
      transport: ViscaTransport.sony,
    );
    serve((packet) {
      if (packet.data[0] == 2) {
        server.send([2, 1, 0, 1, 0, 0, 0, 0, 1], packet.address, packet.port);
        return;
      }
      final header = ByteData.sublistView(packet.data);
      final sequence = header.getUint32(4);
      for (final n in [sequence + 100, sequence]) {
        final bytes = Uint8List.fromList([
          1,
          0x11,
          0,
          3,
          0,
          0,
          0,
          0,
          0x90,
          0x41,
          255,
        ]);
        ByteData.sublistView(bytes).setUint32(4, n);
        server.send(bytes, packet.address, packet.port);
      }
    });
    final client = ViscaClient(
      camera,
      onLog: (_) {},
      onReply: () {},
      onError: (_) {},
    );
    addTearDown(client.close);
    await client.open();
    expect(await client.send('Home', Visca.home), [0x90, 0x41, 255]);
    expect(received.first, [2, 0, 0, 1, 0, 0, 0, 0, 1]);
    expect(received.last.take(4), [1, 0, 0, 5]);
  });

  test(
    'release preempts unanswered polling and cancels queued movement',
    () async {
      final inquiryArrived = Completer<void>();
      serve((packet) {
        if (packet.data[1] == 9) {
          inquiryArrived.complete();
          return;
        }
        server.send([0x90, 0x41, 255], packet.address, packet.port);
      });
      final client = ViscaClient(
        camera,
        onLog: (_) {},
        onReply: () {},
        onError: (_) {},
        timeout: const Duration(seconds: 3),
      );
      addTearDown(client.close);
      await client.open();
      final inquiry = client.send('Position', Visca.panTiltInquiry);
      await inquiryArrived.future;
      final movement = client.send(
        'Left',
        Visca.drive(8, 6, 1, 3),
        motion: true,
      );
      final stop = Visca.drive(8, 6, 3, 3);
      await client
          .send('Stop', stop, priority: true)
          .timeout(const Duration(milliseconds: 500));
      expect(await movement, isNull);
      expect(await inquiry, isNull);
      expect(received, [Visca.panTiltInquiry, stop]);
    },
  );

  test(
    'rejects replies from an unrelated UDP port and malformed packets',
    () async {
      final intruder = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(intruder.close);
      serve((packet) {
        intruder.send([0x90, 0x41, 255], packet.address, packet.port);
        server.send([0x90, 0x41, 0], packet.address, packet.port);
      });
      var replies = 0;
      final client = ViscaClient(
        camera,
        onLog: (_) {},
        onReply: () => replies++,
        onError: (_) {},
        timeout: const Duration(milliseconds: 100),
      );
      addTearDown(client.close);
      await client.open();
      expect(await client.send('Home', Visca.home), isNull);
      expect(replies, 0);
    },
  );

  test('controller polls telemetry, switches cameras after stopping old endpoint, and persists', () async {
    serve((packet) {
      final data = packet.data;
      final response = data[1] != 9
          ? [0x90, 0x41, 255]
          : switch (data[3]) {
              0x12 => [0x90, 0x50, 15, 15, 15, 14, 0, 0, 1, 0, 255],
              0x47 => [0x90, 0x50, 1, 2, 3, 4, 255],
              _ => [0x90, 0x50, 3, 255],
            };
      server.send(response, packet.address, packet.port);
    });
    final store = MemoryStore([camera]);
    final controller = PtzController(store: store);
    addTearDown(controller.dispose);
    await controller.initialize();
    expect(controller.connection, CameraConnection.connected);
    expect(controller.pan, -2);
    expect(controller.tilt, 16);
    expect(controller.zoom, 0x1234);
    expect(controller.autofocus, false);
    expect(
      controller.startMotion(
        'Left',
        Visca.drive(8, 6, 1, 3),
        Visca.drive(8, 6, 3, 3),
      ),
      true,
    );
    expect(
      controller.startMotion(
        'Right',
        Visca.drive(8, 6, 2, 3),
        Visca.drive(8, 6, 3, 3),
      ),
      false,
    );
    final other = Camera(
      id: '2',
      name: 'Second',
      host: camera.host,
      port: camera.port,
    );
    expect(await controller.saveCamera(other), true);
    expect(controller.selected?.id, '2');
    expect(store.cameras.length, 2);
    expect(received, contains(equals(Visca.drive(8, 6, 3, 3))));
  });
}
