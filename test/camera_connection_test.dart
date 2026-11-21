import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ptz_control/controller.dart';
import 'package:ptz_control/models/camera.dart';
import 'package:ptz_control/services/visca_protocol.dart';
import 'package:ptz_control/services/camera_info_service.dart';

import 'camera_info_service_test.dart' show envelope, deviceInfo, interface;

import 'visca_client_test.dart' show MemoryStore;

void main() {
  late RawDatagramSocket server;
  late StreamSubscription<RawSocketEvent> subscription;
  late PtzController controller;
  late List<Datagram> received;
  late Camera camera;
  var sony = false;
  var respond = true;
  var malformed = false;
  var error = false;
  var ackOnly = false;
  int? replyPort;

  setUp(() async {
    sony = malformed = error = ackOnly = false;
    respond = true;
    replyPort = null;
    received = [];
    server = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    camera = Camera(id: 1, name: '', host: '127.0.0.1', port: server.port);
    subscription = server.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? packet;
      while ((packet = server.receive()) != null) {
        final p = packet!;
        received.add(p);
        if (!respond) continue;
        if (sony && p.data[0] == 2) {
          server.send(
            [2, 1, 0, 1, 0, 0, 0, 0, 1],
            p.address,
            replyPort ?? p.port,
          );
          continue;
        }
        if (!sony && p.data[0] != 0x81) continue;
        final data = sony ? p.data.sublist(8) : p.data;
        final payload = error
            ? [0x90, 0x60, 2, 255]
            : ackOnly
            ? [0x90, 0x41, 255]
            : switch (data[3]) {
                0x12 => [
                  0x90,
                  0x50,
                  0,
                  0,
                  malformed ? 16 : 0,
                  1,
                  15,
                  15,
                  15,
                  14,
                  255,
                ],
                0x47 ||
                0x4a ||
                0x4b ||
                0x4c ||
                0x43 ||
                0x44 => [0x90, 0x50, 0, 0, 0, 1, 255],
                _ => [0x90, 0x50, 3, 255],
              };
        if (sony) {
          final bytes = Uint8List(8 + payload.length);
          bytes.setRange(0, 8, p.data);
          bytes[1] = 0x11;
          ByteData.sublistView(bytes).setUint16(2, payload.length);
          bytes.setRange(8, bytes.length, payload);
          server.send(bytes, p.address, replyPort ?? p.port);
        } else {
          server.send(payload, p.address, replyPort ?? p.port);
        }
      }
    });
    controller = PtzController(store: MemoryStore([]));
    await controller.initialize();
  });

  tearDown(() async {
    controller.dispose();
    await subscription.cancel();
    server.close();
  });

  test(
    'raw test uses a position inquiry without saving or selecting a camera',
    () async {
      expect(await controller.testCameraConnection(camera), true);
      expect(received.map((p) => p.data.toList()), [Visca.panTiltInquiry]);
      expect(controller.cameras, isEmpty);
      expect(controller.selected, isNull);
      expect(controller.connection, CameraConnection.none);
    },
  );

  test('Sony test resets sequence and sends a framed inquiry using entered local port', () async {
    sony = true;
    final available = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final localPort = available.port;
    available.close();
    camera = Camera(
      id: 1,
      name: '',
      host: camera.host,
      port: camera.port,
      localPort: localPort,
      transport: ViscaTransport.sony,
    );
    expect(await controller.testCameraConnection(camera), true);
    expect(received.map((p) => p.data.toList()), [
      [2, 0, 0, 1, 0, 0, 0, 0, 1],
      Visca.frame(Visca.panTiltInquiry, 0),
    ]);
    expect(received.every((p) => p.port == localPort), true);
    // The temporary socket is closed after testing.
    final rebound = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      localPort,
    );
    rebound.close();
  });

  test(
    'silence, camera errors, ACKs, and invalid position data are not connected',
    () async {
      respond = false;
      expect(await controller.testCameraConnection(camera), false);
      respond = true;
      error = true;
      expect(await controller.testCameraConnection(camera), false);
      error = false;
      ackOnly = true;
      expect(await controller.testCameraConnection(camera), false);
      ackOnly = false;
      malformed = true;
      expect(await controller.testCameraConnection(camera), false);
    },
  );

  test('a socket bind failure reports not connected', () async {
    final occupied = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    addTearDown(occupied.close);
    camera = Camera(
      id: 1,
      name: '',
      host: camera.host,
      port: camera.port,
      localPort: occupied.port,
    );
    expect(await controller.testCameraConnection(camera), false);
    expect(received, isEmpty);
  });

  test(
    'fixed-reply-port cameras can be tested and switched repeatedly',
    () async {
      final available = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        0,
      );
      final localPort = available.port;
      await available.listen((_) {}).cancel();
      // This peer always replies to the configured controller port, even if
      // a command comes from an ephemeral source port.
      replyPort = localPort;
      expect(await controller.testCameraConnection(camera), false);
      camera = Camera(
        id: 1,
        name: 'First',
        host: camera.host,
        port: camera.port,
        localPort: localPort,
      );
      final otherServer = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final otherSubscription = otherServer.listen((event) {
        if (event != RawSocketEvent.read) return;
        Datagram? packet;
        while ((packet = otherServer.receive()) != null) {
          final p = packet!;
          final register = p.data[3];
          final response = switch (register) {
            0x12 => [0x90, 0x50, 0, 0, 0, 2, 0, 0, 0, 3, 255],
            0x47 ||
            0x4a ||
            0x4b ||
            0x4c ||
            0x43 ||
            0x44 => [0x90, 0x50, 0, 0, 0, 4, 255],
            _ => [0x90, 0x50, 3, 255],
          };
          otherServer.send(response, p.address, localPort);
        }
      });
      addTearDown(() async {
        await otherSubscription.cancel();
        otherServer.close();
      });
      final other = Camera(
        id: 2,
        name: 'Second',
        host: camera.host,
        port: otherServer.port,
        localPort: localPort,
      );
      controller.cameras = [camera, other];
      await controller.select(camera);
      for (var i = 0; i < 5; i++) {
        expect(await controller.testCameraConnection(other), true);
        expect(controller.selected, same(camera));
        expect(controller.connection, CameraConnection.connected);
        expect(controller.pan, 1);
        await controller.select(other);
        expect(controller.connection, CameraConnection.connected);
        expect(controller.pan, 2);
        expect(controller.message, isNull);
        await controller.select(camera);
        expect(controller.connection, CameraConnection.connected);
        expect(controller.pan, 1);
        expect(controller.message, isNull);
      }
    },
  );

  test(
    'testing an active camera reuses its fixed local port and connection',
    () async {
      final available = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final localPort = available.port;
      available.close();
      camera = Camera(
        id: 1,
        name: 'Stage',
        host: camera.host,
        port: camera.port,
        localPort: localPort,
      );
      controller.cameras = [camera];
      await controller.select(camera);
      received.clear();
      expect(await controller.testCameraConnection(camera), true);
      expect(received.map((p) => p.data.toList()), [Visca.panTiltInquiry]);
      expect(received.single.port, localPort);
      expect(controller.selected, same(camera));
      expect(controller.canOperate, true);
    },
  );

  test('changed packet format can use active fixed port and original connection resumes', () async {
    final available = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final localPort = available.port;
    available.close();
    camera = Camera(
      id: 1,
      name: 'Stage',
      host: camera.host,
      port: camera.port,
      localPort: localPort,
    );
    controller.cameras = [camera];
    await controller.select(camera);
    received.clear();
    // The peer rejects the edited Sony format; the original raw connection
    // must be reopened afterward, without saving the edited settings.
    final edited = Camera(
      id: camera.id,
      name: camera.name,
      host: camera.host,
      port: camera.port,
      localPort: localPort,
      transport: ViscaTransport.sony,
    );
    expect(await controller.testCameraConnection(edited), false);
    expect(received.first.data, [2, 0, 0, 1, 0, 0, 0, 0, 1]);
    expect(controller.selected, same(camera));
    expect(controller.canOperate, true);
    expect(controller.connection, CameraConnection.connected);
    expect(controller.pan, 1);
  });

  test('camera identity lookup preserves the active UDP connection and does not save until requested', () async {
    final web = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => web.close(force: true));
    final requested = Completer<void>();
    final release = Completer<void>();
    web.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      if (!requested.isCompleted) requested.complete();
      await release.future;
      request.response.write(
        body.contains('<d:GetDeviceInformation ')
            ? deviceInfo()
            : envelope(
                'GetNetworkInterfaces',
                interface('02:AA:BB:CC:DD:01', camera.host),
              ),
      );
      await request.response.close();
    });
    controller.cameras = [camera];
    await controller.select(camera);
    final sourcePort = received.last.port;
    final lookup = controller.getCameraInfo(
      camera,
      CameraInfoOptions(port: web.port),
    );
    await requested.future;
    expect(controller.canTransferCameraSettings, false);
    final concurrent = await controller.getCameraInfo(
      camera,
      CameraInfoOptions(port: web.port),
    );
    expect(concurrent.info, isNull);
    expect(concurrent.message, contains('busy'));
    expect(controller.selected, same(camera));
    expect(controller.connection, CameraConnection.connected);
    release.complete();
    final result = await lookup;
    expect(result.info!.serialNumber, 'SN-123');
    expect(controller.cameras.single.info, isNull);
    expect(controller.canTransferCameraSettings, true);
    received.clear();
    await controller.refresh();
    expect(received, isNotEmpty);
    expect(received.every((packet) => packet.port == sourcePort), true);
    expect(controller.connection, CameraConnection.connected);
  });
}
