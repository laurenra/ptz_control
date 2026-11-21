import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ptz_control/models/camera.dart';
import 'package:ptz_control/services/camera_info_service.dart';
import 'package:xml/xml.dart';

const _device = 'http://www.onvif.org/ver10/device/wsdl';
String envelope(String operation, String content) =>
    '<e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope"><e:Body>'
    '<d:${operation}Response xmlns:d="$_device">$content</d:${operation}Response>'
    '</e:Body></e:Envelope>';
String deviceInfo({String serial = 'SN-123'}) => envelope(
  'GetDeviceInformation',
  '<d:Manufacturer>Example &amp; Co</d:Manufacturer><d:Model>PTZ 20X</d:Model>'
      '<d:SerialNumber>$serial</d:SerialNumber>',
);
String interface(String mac, String ip, {bool enabled = true}) =>
    '<d:NetworkInterfaces><t:Enabled xmlns:t="http://www.onvif.org/ver10/schema">$enabled</t:Enabled>'
    '<t:Info xmlns:t="http://www.onvif.org/ver10/schema"><t:HwAddress>$mac</t:HwAddress></t:Info>'
    '<t:IPv4 xmlns:t="http://www.onvif.org/ver10/schema"><t:Config><t:Manual>'
    '<t:Address>$ip</t:Address></t:Manual></t:Config></t:IPv4></d:NetworkInterfaces>';

void main() {
  late HttpServer server;
  late Camera camera;
  late List<String> paths;
  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    camera = const Camera(
      id: 1,
      name: 'Camera',
      host: '127.0.0.1',
      port: 52381,
      localPort: 52381,
    );
    paths = [];
  });
  tearDown(() async => server.close(force: true));

  void serve(FutureOr<void> Function(HttpRequest, String) handler) {
    server.listen((request) async {
      paths.add(request.uri.toString());
      final body = await utf8.decoder.bind(request).join();
      await handler(request, body);
      await request.response.close();
    });
  }

  test(
    'ONVIF returns identity and the MAC matching the configured camera IP',
    () async {
      serve((request, body) {
        expect(request.method, 'POST');
        expect(request.contentLength, utf8.encode(body).length);
        expect(request.headers.contentType!.mimeType, 'application/soap+xml');
        if (body.contains('<d:GetDeviceInformation ')) {
          request.response.write(deviceInfo());
        } else {
          request.response.write(
            envelope(
              'GetNetworkInterfaces',
              interface('02-aa-bb-cc-dd-01', '192.0.2.1') +
                  interface('02-aa-bb-cc-dd-02', camera.host),
            ),
          );
        }
      });
      final result = await const CameraInfoService().lookup(
        camera,
        CameraInfoOptions(port: server.port),
      );
      expect(result.info!.manufacturer, 'Example & Co');
      expect(result.info!.model, 'PTZ 20X');
      expect(result.info!.serialNumber, 'SN-123');
      expect(result.info!.macAddress, '02:AA:BB:CC:DD:02');
      expect(result.info!.sourceHost, camera.host);
      expect(paths, ['/onvif/device_service', '/onvif/device_service']);
    },
  );

  test(
    'PTZOptics fallback accepts documented JSON and older key-value responses',
    () async {
      serve((request, body) {
        if (request.method == 'POST') {
          request.response.statusCode = 404;
        } else {
          request.response.write(switch (request.uri.query) {
            'get_device_conf' => jsonEncode({
              'status': 200,
              'data': {
                'devname': 'ptzopticsmove4k',
                'device_model': 'F51.HI',
                'mirrors': 'https://firmware.ptzoptics.com/',
              },
            }),
            'get_network_conf' =>
              'mac="02:aa:bb:cc:dd:03"\r\nipaddr="127.0.0.1"\r\n',
            'get_serial_number' => 'serial_num="SN-456"',
            _ => '',
          });
        }
      });
      final result = await const CameraInfoService().lookup(
        camera,
        CameraInfoOptions(port: server.port),
      );
      expect(result.info!.manufacturer, 'PTZOptics');
      expect(result.info!.model, 'F51.HI');
      expect(result.info!.serialNumber, 'SN-456');
      expect(result.info!.macAddress, '02:AA:BB:CC:DD:03');
      expect(
        paths.where((path) => path.startsWith('/cgi-bin/param.cgi?')).length,
        3,
      );
    },
  );

  test('does not guess manufacturer from protocol or select an unrelated network interface', () async {
    serve((request, body) {
      if (body.contains('<d:GetDeviceInformation ')) {
        request.response.write(
          envelope('GetDeviceInformation', '<d:Model>Unbranded</d:Model>'),
        );
      } else if (request.method == 'POST') {
        request.response.write(
          envelope(
            'GetNetworkInterfaces',
            interface('02:AA:BB:CC:DD:01', '192.0.2.1') +
                interface('02:AA:BB:CC:DD:02', '192.0.2.2'),
          ),
        );
      } else {
        request.response.statusCode = 404;
      }
    });
    final result = await const CameraInfoService().lookup(
      camera,
      CameraInfoOptions(port: server.port),
    );
    expect(result.info!.model, 'Unbranded');
    expect(result.info!.manufacturer, isNull);
    expect(result.info!.serialNumber, isNull);
    expect(result.info!.macAddress, isNull);
    expect(result.message, contains('not reported'));
  });

  test('reports authentication requirement without credentials', () async {
    serve((request, _) {
      request.response.statusCode = 401;
      request.response.headers.set(
        HttpHeaders.wwwAuthenticateHeader,
        'Basic realm="Camera"',
      );
    });
    final result = await const CameraInfoService().lookup(
      camera,
      CameraInfoOptions(port: server.port),
    );
    expect(result.info, isNull);
    expect(result.message, contains('Camera login required'));
  });

  test('supports HTTP login and ONVIF UsernameToken without transmitting a plaintext SOAP password', () async {
    const username = 'operator<&';
    const password = 'private-camera-password';
    var authenticated = 0;
    serve((request, body) {
      if (request.headers.value(HttpHeaders.authorizationHeader) !=
          'Basic ${base64.encode(utf8.encode('$username:$password'))}') {
        request.response.statusCode = 401;
        request.response.headers.set(
          HttpHeaders.wwwAuthenticateHeader,
          'Basic realm="Camera"',
        );
        return;
      }
      authenticated++;
      final xml = XmlDocument.parse(body);
      String value(String local) => xml.descendants
          .whereType<XmlElement>()
          .firstWhere((element) => element.name.local == local)
          .innerText;
      expect(value('Username'), username);
      expect(body, isNot(contains(password)));
      expect(
        value('Password'),
        base64.encode(
          sha1.convert([
            ...base64.decode(value('Nonce')),
            ...utf8.encode(value('Created')),
            ...utf8.encode(password),
          ]).bytes,
        ),
      );
      if (body.contains('<d:GetDeviceInformation ')) {
        request.response.write(deviceInfo());
      } else {
        request.response.write(
          envelope(
            'GetNetworkInterfaces',
            interface('02:AA:BB:CC:DD:04', camera.host),
          ),
        );
      }
    });
    final result = await const CameraInfoService().lookup(
      camera,
      CameraInfoOptions(
        port: server.port,
        username: username,
        password: password,
      ),
    );
    expect(result.info!.serialNumber, 'SN-123');
    expect(result.info!.macAddress, '02:AA:BB:CC:DD:04');
    expect(authenticated, 2);
  });

  for (final algorithm in [
    'MD5',
    'MD5-SESS',
    'SHA-256',
    'SHA-256-SESS',
    'MD5-legacy',
  ]) {
    test('authenticates SOAP requests with HTTP Digest $algorithm', () async {
      const username = 'operator';
      const password = 'camera-password';
      const realm = 'Camera';
      const nonce = 'test-challenge';
      final legacy = algorithm == 'MD5-legacy';
      final wireAlgorithm = legacy ? 'MD5' : algorithm;
      var authenticated = 0;
      serve((request, body) {
        final authorization = request.headers.value(
          HttpHeaders.authorizationHeader,
        );
        if (authorization == null) {
          request.response.statusCode = 401;
          request.response.headers.set(
            HttpHeaders.wwwAuthenticateHeader,
            'Digest realm="$realm", nonce="$nonce", algorithm=$wireAlgorithm, '
            '${legacy ? '' : 'qop="auth,auth-int", '}opaque="camera-opaque"',
          );
          return;
        }
        final fields = <String, String>{};
        // Parse the header independently, including its quoted values.
        for (final part in authorization.substring(7).split(', ')) {
          final equals = part.indexOf('=');
          fields[part.substring(0, equals)] = part
              .substring(equals + 1)
              .replaceAll('"', '');
        }
        String hash(String value) =>
            (wireAlgorithm.startsWith('SHA-256') ? sha256 : md5)
                .convert(utf8.encode(value))
                .toString();
        var a1 = hash('$username:$realm:$password');
        if (wireAlgorithm.endsWith('-SESS')) {
          a1 = hash('$a1:$nonce:${fields['cnonce']}');
        }
        final a2 = hash('${request.method}:${request.uri}');
        final expected = legacy
            ? hash('$a1:$nonce:$a2')
            : hash('$a1:$nonce:${fields['nc']}:${fields['cnonce']}:auth:$a2');
        expect(fields['username'], username);
        expect(fields['uri'], request.uri.toString());
        expect(fields['response'], expected);
        expect(fields['opaque'], 'camera-opaque');
        expect(body, contains('<s:Body>'));
        authenticated++;
        request.response.write(
          body.contains('<d:GetDeviceInformation ')
              ? deviceInfo()
              : envelope(
                  'GetNetworkInterfaces',
                  interface('02:AA:BB:CC:DD:05', camera.host),
                ),
        );
      });
      final result = await const CameraInfoService().lookup(
        camera,
        CameraInfoOptions(
          port: server.port,
          username: username,
          password: password,
        ),
      );
      expect(result.info!.serialNumber, 'SN-123');
      expect(result.info!.macAddress, '02:AA:BB:CC:DD:05');
      expect(authenticated, 2);
      expect(paths.length, 4);
    });
  }

  test(
    'does not follow redirects or interpret HTML/errors as device identity',
    () async {
      serve((request, _) {
        if (request.method == 'POST') {
          request.response.statusCode = 302;
          request.response.headers.set(
            HttpHeaders.locationHeader,
            '/elsewhere',
          );
        } else {
          request.response.write(
            '<html><body>Login required serial_num=NotACamera</body></html>',
          );
        }
      });
      final result = await const CameraInfoService().lookup(
        camera,
        CameraInfoOptions(port: server.port),
      );
      expect(result.info, isNull);
      expect(paths, isNot(contains('/elsewhere')));
    },
  );

  test(
    'times out and closes requests to an unresponsive web service',
    () async {
      server.listen((_) {});
      final result =
          await const CameraInfoService(timeout: Duration(milliseconds: 50))
              .lookup(camera, CameraInfoOptions(port: server.port))
              .timeout(const Duration(seconds: 2));
      expect(result.info, isNull);
      expect(result.message, contains('No camera information returned'));
    },
  );
}
