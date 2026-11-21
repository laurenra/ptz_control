import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ptz_control/services/onvif_discovery.dart';
import 'package:xml/xml.dart';

const discoveryNamespace = 'http://schemas.xmlsoap.org/ws/2005/04/discovery';
const addressingNamespace = 'http://schemas.xmlsoap.org/ws/2004/08/addressing';

String discoveryMatch({
  String address = 'urn:uuid:camera-one',
  String types = 'n:NetworkVideoTransmitter',
  String scopes = 'onvif://www.onvif.org/name/Camera%20One onvif://www.onvif.org/Profile/Streaming',
  String xAddrs = 'http://192.0.2.1/onvif/device_service',
}) =>
    '<d:ProbeMatch><a:EndpointReference><a:Address>$address</a:Address>'
    '</a:EndpointReference><d:Types>$types</d:Types><d:Scopes>$scopes</d:Scopes>'
    '<d:XAddrs>$xAddrs</d:XAddrs><d:MetadataVersion>1</d:MetadataVersion></d:ProbeMatch>';

String discoveryResponse(
  String relatesTo,
  String matches, {
  String addressing = addressingNamespace,
  String action = '$discoveryNamespace/ProbeMatches',
}) =>
    '<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" '
    'xmlns:a="$addressing" xmlns:d="$discoveryNamespace" '
    'xmlns:n="http://www.onvif.org/ver10/network/wsdl" '
    'xmlns:t="http://www.onvif.org/ver10/device/wsdl" xmlns:p="urn:printer">'
    '<s:Header><a:Action>$action</a:Action><a:RelatesTo>$relatesTo</a:RelatesTo></s:Header>'
    '<s:Body><d:ProbeMatches>$matches</d:ProbeMatches></s:Body></s:Envelope>';

void main() {
  late RawDatagramSocket peer;
  late StreamSubscription<RawSocketEvent> subscription;
  late List<Datagram> probes;
  late List<CameraDiscoveryScan> scans;

  setUp(() async {
    peer = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    probes = [];
    scans = [];
  });
  tearDown(() async {
    for (final scan in scans) {
      scan.cancel();
    }
    await subscription.cancel();
    peer.close();
  });

  void serve(void Function(Datagram, String) handler) {
    subscription = peer.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? packet;
      while ((packet = peer.receive()) != null) {
        probes.add(packet!);
        final xml = XmlDocument.parse(utf8.decode(packet.data));
        final messageId = xml
            .findAllElements('MessageID', namespaceUri: addressingNamespace)
            .single
            .innerText;
        handler(packet, messageId);
      }
    });
  }

  void respond(Datagram probe, String source) =>
      peer.send(utf8.encode(source), probe.address, probe.port);

  CameraDiscoveryScan start({
    Duration duration = const Duration(milliseconds: 150),
    Future<List<InternetAddress>> Function()? addresses,
  }) {
    final scan = OnvifDiscoveryService(
      duration: duration,
      probeAddress: peer.address.address,
      probePort: peer.port,
      localAddresses: addresses ?? () async => [InternetAddress.loopbackIPv4],
    ).start();
    scans.add(scan);
    return scan;
  }

  test('sends a WS-Discovery probe and merges repeated replies by endpoint reference', () async {
    serve((packet, messageId) {
      final xml = XmlDocument.parse(utf8.decode(packet.data));
      expect(
        xml.rootElement.namespaceUri,
        'http://www.w3.org/2003/05/soap-envelope',
      );
      expect(
        xml
            .findAllElements('Action', namespaceUri: addressingNamespace)
            .single
            .innerText,
        '$discoveryNamespace/Probe',
      );
      expect(
        xml
            .findAllElements('To', namespaceUri: addressingNamespace)
            .single
            .innerText,
        'urn:schemas-xmlsoap-org:ws:2005:04:discovery',
      );
      expect(
        xml
            .findAllElements('ReplyTo', namespaceUri: addressingNamespace)
            .single
            .innerText,
        '$addressingNamespace/role/anonymous',
      );
      expect(
        messageId,
        matches(
          RegExp(
            r'^urn:uuid:[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ),
        ),
      );
      expect(
        xml.findAllElements('Probe', namespaceUri: discoveryNamespace),
        hasLength(1),
      );
      expect(xml.findAllElements('Types'), isEmpty);
      respond(packet, discoveryResponse(messageId, discoveryMatch()));
      respond(packet, discoveryResponse(messageId, discoveryMatch()));
      respond(
        packet,
        discoveryResponse(
          messageId,
          discoveryMatch(xAddrs: 'http://192.0.2.2/onvif/device_service') +
              discoveryMatch(
                address: 'urn:uuid:camera-two',
                types: 't:Device',
                scopes: '',
                xAddrs: 'http://192.0.2.3/onvif/device_service',
              ),
        ),
      );
    });
    final snapshots = await start().results.toList();
    expect(snapshots, hasLength(2));
    expect(snapshots.first, hasLength(1));
    final devices = snapshots.last;
    expect(devices.map((d) => d.address), [
      'urn:uuid:camera-one',
      'urn:uuid:camera-two',
    ]);
    expect(devices.first.types, ['n:NetworkVideoTransmitter']);
    expect(
      devices.first.scopes.first,
      'onvif://www.onvif.org/name/Camera%20One',
    );
    expect(devices.first.xAddrs, [
      'http://192.0.2.1/onvif/device_service',
      'http://192.0.2.2/onvif/device_service',
    ]);
    expect(devices.last.types, ['t:Device']);
    expect(() => devices.clear(), throwsUnsupportedError);
    expect(const OnvifDiscoveryService().probeAddress, '239.255.255.250');
    expect(const OnvifDiscoveryService().probePort, 3702);
  });

  test('ignores malformed, unrelated and non-ONVIF responses while retaining valid replies', () async {
    serve((packet, id) {
      for (final source in [
        'not xml',
        '<!DOCTYPE x><x/>',
        discoveryResponse('urn:uuid:another-client', discoveryMatch()),
        discoveryResponse(
          id,
          discoveryMatch(),
          action: '$discoveryNamespace/Hello',
        ),
        discoveryResponse(
          id,
          discoveryMatch(
            address: 'urn:uuid:printer',
            types: 'p:Device',
            scopes: '',
          ),
        ),
        discoveryResponse(id, discoveryMatch(address: '', types: 't:Device')),
        discoveryResponse(id, discoveryMatch()).replaceAll(
          'http://www.w3.org/2003/05/soap-envelope',
          'urn:fake-soap',
        ),
      ]) {
        respond(packet, source);
      }
      peer.send([255, 254], packet.address, packet.port);
      respond(
        packet,
        discoveryResponse(
          id,
          discoveryMatch(
            types: '',
            scopes: 'onvif://www.onvif.org/name/Camera',
          ),
          addressing: 'http://www.w3.org/2005/08/addressing',
        ),
      );
    });
    final snapshots = await start().results.toList();
    expect(snapshots, hasLength(1));
    expect(snapshots.single.single.address, 'urn:uuid:camera-one');
    expect(snapshots.single.single.types, isEmpty);
  });

  test(
    'retransmits with the same ID and finishes when no devices respond',
    () async {
      final ids = <String>[];
      serve((_, id) => ids.add(id));
      expect(
        await start(duration: const Duration(milliseconds: 750)).results
            .toList(),
        isEmpty,
      );
      expect(ids, hasLength(2));
      expect(ids.toSet(), hasLength(1));
    },
  );

  test(
    'cancel stops pending retries and releases the listening port',
    () async {
      final received = Completer<Datagram>();
      serve((packet, _) {
        if (!received.isCompleted) received.complete(packet);
      });
      final scan = start(duration: const Duration(seconds: 2));
      final done = scan.results.toList();
      final packet = await received.future;
      scan.cancel();
      expect(await done, isEmpty);
      final rebound = await RawDatagramSocket.bind(
        packet.address,
        packet.port,
        reuseAddress: false,
      );
      rebound.close();
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(probes, hasLength(1));
    },
  );

  test(
    'cancel during interface lookup prevents opening sockets or sending probes',
    () async {
      serve((_, _) {});
      final addresses = Completer<List<InternetAddress>>();
      final scan = start(addresses: () => addresses.future);
      final done = scan.results.toList();
      scan.cancel();
      addresses.complete([InternetAddress.loopbackIPv4]);
      expect(await done, isEmpty);
      await Future<void>.delayed(Duration.zero);
      expect(probes, isEmpty);
    },
  );

  test('reports when there is no usable network interface', () async {
    serve((_, _) {});
    await expectLater(
      start(addresses: () async => []).results.toList(),
      throwsA(isA<SocketException>()),
    );
  });

  test('does not impose the eight saved camera limit on discovery', () async {
    serve(
      (packet, id) => respond(
        packet,
        discoveryResponse(
          id,
          List.generate(
            12,
            (index) => discoveryMatch(address: 'urn:uuid:camera-$index'),
          ).join(),
        ),
      ),
    );
    final snapshots = await start().results.toList();
    expect(snapshots.last, hasLength(12));
  });
}
