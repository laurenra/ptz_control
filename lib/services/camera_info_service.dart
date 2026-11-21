import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:xml/xml.dart';

import '../models/camera.dart';
import '../models/camera_info.dart';

/// Credentials are used for this lookup only; never stored with camera settings.
class CameraInfoOptions {
  const CameraInfoOptions({
    this.port = 80,
    this.https = false,
    this.username = '',
    this.password = '',
  });
  final int port;
  final bool https;
  final String username, password;
}

class CameraInfoResult {
  const CameraInfoResult(this.info, this.message);
  final CameraInfo? info;
  final String message;
}

class _Response {
  const _Response(this.status, this.body, [this.challenges = const []]);
  final List<String> challenges;
  final int status;
  final String body;
  bool get needsLogin =>
      status == 401 ||
      status == 403 ||
      RegExp(
        'NotAuthorized|FailedAuthentication',
        caseSensitive: false,
      ).hasMatch(body);
}

/// Read-only ONVIF device operations with a PTZOptics HTTP-CGI fallback.
/// Identity queries use the web service, leaving the VISCA UDP socket intact.
class CameraInfoService {
  const CameraInfoService({this.timeout = const Duration(seconds: 3)});
  final Duration timeout;
  static const _device = 'http://www.onvif.org/ver10/device/wsdl';

  Future<CameraInfoResult> lookup(
    Camera camera,
    CameraInfoOptions options,
  ) async {
    if (Camera.validateHost(camera.host) != null ||
        options.port < 1 ||
        options.port > 65535) {
      throw const FormatException('Enter a valid camera address and web port.');
    }
    final base = Uri(
      scheme: options.https ? 'https' : 'http',
      host: camera.host,
      port: options.port,
    );
    final onvif = base.replace(path: '/onvif/device_service');
    final soap = await Future.wait([
      for (final operation in ['GetDeviceInformation', 'GetNetworkInterfaces'])
        _request(onvif, options, operation: operation),
    ]);
    var loginRequired = soap.any((response) => response?.needsLogin ?? false);
    final device = _soapResponse(soap[0], 'GetDeviceInformationResponse');
    final network = _soapResponse(soap[1], 'GetNetworkInterfacesResponse');
    var manufacturer = _text(device, 'Manufacturer');
    var model = _text(device, 'Model');
    var serial = _text(device, 'SerialNumber');
    var mac = _interfaceMac(network, camera.host);

    if (manufacturer == null ||
        model == null ||
        serial == null ||
        mac == null) {
      final queries = [
        if (manufacturer == null || model == null || serial == null)
          'get_device_conf',
        if (mac == null) 'get_network_conf',
        if (serial == null) 'get_serial_number',
      ];
      final responses = await Future.wait([
        for (final query in queries)
          _request(
            base.replace(path: '/cgi-bin/param.cgi', query: query),
            options,
          ),
      ]);
      for (var index = 0; index < queries.length; index++) {
        final response = responses[index];
        loginRequired |= response?.needsLogin ?? false;
        if (response == null || response.status != 200) continue;
        final fields = _fields(response.body);
        if (queries[index] == 'get_device_conf') {
          manufacturer ??= _field(fields, ['manufacturer', 'vendor', 'brand']);
          // Recognize the manufacturer's documented firmware signature, not
          // the VISCA packet format (many other brands support Sony VISCA).
          if (manufacturer == null &&
              (_field(fields, [
                    'devname',
                  ])?.toLowerCase().startsWith('ptzoptics') ??
                  false) &&
              Uri.tryParse(_field(fields, ['mirrors']) ?? '')?.host ==
                  'firmware.ptzoptics.com') {
            manufacturer = 'PTZOptics';
          }
          model ??= _field(fields, [
            'model',
            'modelname',
            'devicemodel',
            'devtype',
          ]);
        }
        serial ??= _field(fields, [
          'serialnumber',
          'serialnum',
          'serial',
          'sn',
        ]);
        mac ??= CameraInfo.normalizeMac(
          _field(fields, ['macaddress', 'macaddr', 'mac', 'hwaddress']),
        );
        if (queries[index] == 'get_serial_number' && serial == null) {
          var value = response.body.trim();
          try {
            final decoded = jsonDecode(value);
            if (decoded is String) value = decoded;
          } on FormatException {
            /* Older firmware can return a bare serial. */
          }
          if (RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9._/-]{2,127}$').hasMatch(value) &&
              ![
                'ok',
                'error',
                'success',
                'failed',
                '401',
                '403',
                '404',
              ].contains(value.toLowerCase())) {
            serial = CameraInfo.reportedText(value);
          }
        }
      }
    }
    final info = CameraInfo(
      manufacturer: manufacturer,
      model: model,
      serialNumber: serial,
      macAddress: mac,
      sourceHost: camera.host,
    );
    if (info.isEmpty) {
      return CameraInfoResult(
        null,
        loginRequired
            ? 'Camera login required. Enter the username and password under Camera info connection, then try again.'
            : 'No camera information returned. Check the web port and whether the camera supports ONVIF or PTZOptics HTTP queries.',
      );
    }
    final complete =
        manufacturer != null && model != null && serial != null && mac != null;
    return CameraInfoResult(
      info,
      complete
          ? 'Camera info retrieved. Save camera to keep it.'
          : loginRequired
          ? 'Some information requires a camera login. Returned details are shown below.'
          : 'Some details were not reported by the camera. Save camera to keep the returned information.',
    );
  }

  Future<_Response?> _request(
    Uri uri,
    CameraInfoOptions options, {
    String? operation,
  }) async {
    final client = HttpClient()..connectionTimeout = timeout;
    client.findProxy = (_) => 'DIRECT';
    try {
      Future<_Response?> send([String? authorization]) async {
        final request = await client.openUrl(
          operation == null ? 'GET' : 'POST',
          uri,
        );
        request.followRedirects = false;
        if (authorization != null) {
          request.headers.set(HttpHeaders.authorizationHeader, authorization);
        }
        if (operation != null) {
          final action = '$_device/$operation';
          request.headers.set(
            HttpHeaders.contentTypeHeader,
            'application/soap+xml; charset=utf-8; action="$action"',
          );
          request.headers.set('SOAPAction', '"$action"');
          final body = utf8.encode(
            '<?xml version="1.0" encoding="UTF-8"?>'
            '<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">'
            '${_security(options)}<s:Body>'
            '<d:$operation xmlns:d="$_device"/>'
            '</s:Body></s:Envelope>',
          );
          request.contentLength = body.length;
          request.add(body);
        }
        final response = await request.close();
        const maxBytes = 128 * 1024;
        if (response.contentLength > maxBytes) return null;
        final bytes = <int>[];
        await for (final chunk in response) {
          if (bytes.length + chunk.length > maxBytes) return null;
          bytes.addAll(chunk);
        }
        return _Response(
          response.statusCode,
          utf8.decode(bytes),
          response.headers[HttpHeaders.wwwAuthenticateHeader] ?? const [],
        );
      }

      return await (() async {
        final first = await send();
        if (first?.status != 401 || options.username.isEmpty) return first;
        final authorization = _authorization(
          first!.challenges,
          uri,
          operation == null ? 'GET' : 'POST',
          options,
        );
        return authorization == null ? first : await send(authorization);
      })().timeout(timeout);
    } on Exception {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  // Retry explicitly so authentication preserves the SOAP POST body.
  static String? _authorization(
    List<String> challenges,
    Uri uri,
    String method,
    CameraInfoOptions options,
  ) {
    for (final challenge in challenges.where(
      (value) => value.toLowerCase().startsWith('digest '),
    )) {
      final fields = {
        for (final match in RegExp(
          r'(\w+)\s*=\s*(?:"((?:[^"\\]|\\.)*)"|([^,\s]+))',
        ).allMatches(challenge.substring(7)))
          match[1]!.toLowerCase(): (match[2] ?? match[3]!).replaceAllMapped(
            RegExp(r'\\(.)'),
            (m) => m[1]!,
          ),
      };
      final realm = fields['realm'];
      final nonce = fields['nonce'];
      final algorithm = (fields['algorithm'] ?? 'MD5').toUpperCase();
      if (realm == null ||
          nonce == null ||
          !['MD5', 'MD5-SESS', 'SHA-256', 'SHA-256-SESS'].contains(algorithm)) {
        continue;
      }
      final qops = fields['qop']
          ?.split(',')
          .map((value) => value.trim())
          .toList();
      if (qops != null && !qops.contains('auth')) continue;
      final hash = algorithm.startsWith('SHA-256') ? sha256 : md5;
      String h(String value) => hash.convert(utf8.encode(value)).toString();
      String quote(String value) =>
          '"${value.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
      final random = Random.secure();
      final cnonce = base64.encode(
        List.generate(16, (_) => random.nextInt(256)),
      );
      final target = uri.path + (uri.hasQuery ? '?${uri.query}' : '');
      var ha1 = h('${options.username}:$realm:${options.password}');
      if (algorithm.endsWith('-SESS')) ha1 = h('$ha1:$nonce:$cnonce');
      final ha2 = h('$method:$target');
      final digest = qops == null
          ? h('$ha1:$nonce:$ha2')
          : h('$ha1:$nonce:00000001:$cnonce:auth:$ha2');
      final parts = [
        'username=${quote(options.username)}',
        'realm=${quote(realm)}',
        'nonce=${quote(nonce)}',
        'uri=${quote(target)}',
        'response=${quote(digest)}',
        'algorithm=$algorithm',
        if (qops != null) 'qop=auth',
        if (qops != null) 'nc=00000001',
        if (qops != null || algorithm.endsWith('-SESS'))
          'cnonce=${quote(cnonce)}',
        if (fields['opaque'] != null) 'opaque=${quote(fields['opaque']!)}',
      ];
      return 'Digest ${parts.join(', ')}';
    }
    if (challenges.any((value) => value.toLowerCase().startsWith('basic '))) {
      return 'Basic ${base64.encode(utf8.encode('${options.username}:${options.password}'))}';
    }
    return null;
  }

  static String _security(CameraInfoOptions options) {
    if (options.username.isEmpty) return '';
    const wsse =
        'http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd';
    const wsu =
        'http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd';
    const token =
        'http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0';
    final random = Random.secure();
    final nonce = List.generate(16, (_) => random.nextInt(256));
    final created = DateTime.now().toUtc().toIso8601String();
    final digest = base64.encode(
      sha1.convert([
        ...nonce,
        ...utf8.encode(created),
        ...utf8.encode(options.password),
      ]).bytes,
    );
    final username = XmlText(options.username).toXmlString();
    return '<s:Header><wsse:Security s:mustUnderstand="1" xmlns:wsse="$wsse" xmlns:wsu="$wsu">'
        '<wsse:UsernameToken><wsse:Username>$username</wsse:Username>'
        '<wsse:Password Type="$token#PasswordDigest">$digest</wsse:Password>'
        '<wsse:Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary">${base64.encode(nonce)}</wsse:Nonce>'
        '<wsu:Created>$created</wsu:Created></wsse:UsernameToken></wsse:Security></s:Header>';
  }

  static XmlElement? _soapResponse(_Response? response, String name) {
    if (response == null ||
        response.status != 200 ||
        response.body.toUpperCase().contains('<!DOCTYPE')) {
      return null;
    }
    try {
      final xml = XmlDocument.parse(response.body);
      final bodies = xml.descendants.whereType<XmlElement>().where(
        (element) =>
            element.name.local == 'Body' &&
            [
              'http://www.w3.org/2003/05/soap-envelope',
              'http://schemas.xmlsoap.org/soap/envelope/',
            ].contains(element.namespaceUri),
      );
      for (final body in bodies) {
        for (final element in body.childElements) {
          if (element.name.local == name && element.namespaceUri == _device) {
            return element;
          }
        }
      }
    } on XmlException {
      /* Non-ONVIF services may return HTML instead. */
    }
    return null;
  }

  static String? _text(XmlElement? parent, String name) {
    if (parent == null) return null;
    for (final child in parent.childElements) {
      if (child.name.local == name) {
        return CameraInfo.reportedText(child.innerText);
      }
    }
    return null;
  }

  static String? _interfaceMac(XmlElement? response, String host) {
    if (response == null) return null;
    final interfaces = response.childElements
        .where(
          (e) =>
              e.name.local == 'NetworkInterfaces' &&
              _text(e, 'Enabled') != 'false',
        )
        .toList();
    final matching = interfaces
        .where(
          (interface) => interface.descendants.whereType<XmlElement>().any(
            (element) =>
                element.name.local == 'Address' &&
                element.innerText.trim() == host,
          ),
        )
        .toList();
    final candidates = matching.isNotEmpty
        ? matching
        : interfaces.length == 1
        ? interfaces
        : <XmlElement>[];
    final macs = <String>{};
    for (final interface in candidates) {
      for (final info in interface.childElements.where(
        (e) => e.name.local == 'Info',
      )) {
        final mac = CameraInfo.normalizeMac(_text(info, 'HwAddress'));
        if (mac != null) macs.add(mac);
      }
    }
    return macs.length == 1 ? macs.single : null;
  }

  static Map<String, dynamic> _fields(String source) {
    Map<dynamic, dynamic> values;
    try {
      final decoded = jsonDecode(source);
      if (decoded is! Map) return {};
      if (decoded['status'] != null && decoded['status'] != 200) return {};
      values = decoded['data'] is Map ? decoded['data'] as Map : decoded;
    } on FormatException {
      if (source.trimLeft().startsWith('<')) return {};
      values = {
        for (final match in RegExp(
          r'''(?:^|[\s;&])([a-zA-Z_][a-zA-Z0-9_]*)\s*=\s*(?:"([^"\r\n]*)"|'([^'\r\n]*)'|([^\r\n;&]+))''',
          multiLine: true,
        ).allMatches(source))
          match[1]!: match[2] ?? match[3] ?? match[4],
      };
    }
    return {
      for (final entry in values.entries)
        entry.key.toString().toLowerCase().replaceAll(RegExp('[^a-z0-9]'), ''):
            entry.value,
    };
  }

  static String? _field(Map<String, dynamic> fields, List<String> keys) {
    for (final key in keys) {
      final value = CameraInfo.reportedText(fields[key]);
      if (value != null) return value;
    }
    return null;
  }
}
