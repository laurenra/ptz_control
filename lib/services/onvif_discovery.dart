import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:xml/xml.dart';

import '../models/discovered_camera.dart';

const _soap = 'http://www.w3.org/2003/05/soap-envelope';
const _discovery = 'http://schemas.xmlsoap.org/ws/2005/04/discovery';
const _addressing = 'http://schemas.xmlsoap.org/ws/2004/08/addressing';
const _addressingNamespaces = [
  _addressing,
  'http://www.w3.org/2005/08/addressing',
];

abstract interface class CameraDiscoveryScan {
  /// Complete snapshots in first-response order, updated as devices respond.
  Stream<List<DiscoveredCamera>> get results;
  void cancel();
}

class OnvifDiscoveryService {
  const OnvifDiscoveryService({
    this.duration = const Duration(seconds: 5),
    this.probeAddress = '239.255.255.250',
    this.probePort = 3702,
    this.localAddresses,
  });

  final Duration duration;
  final String probeAddress;
  final int probePort;
  final Future<List<InternetAddress>> Function()? localAddresses;

  CameraDiscoveryScan start() => _UdpDiscoveryScan(this);

  static Future<List<InternetAddress>> _localAddresses() async => [
    for (final interface in await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLinkLocal: true,
    ))
      ...interface.addresses,
  ];
}

class _UdpDiscoveryScan implements CameraDiscoveryScan {
  _UdpDiscoveryScan(this.service) {
    _results = StreamController<List<DiscoveredCamera>>(
      onListen: _start,
      onCancel: cancel,
    );
  }

  final OnvifDiscoveryService service;
  late final StreamController<List<DiscoveredCamera>> _results;
  final _sockets = <RawDatagramSocket>[];
  final _subscriptions = <StreamSubscription<RawSocketEvent>>[];
  final _timers = <Timer>[];
  final _devices = <String, DiscoveredCamera>{};
  final _messageId = _newMessageId();
  bool _closed = false;
  int _sent = 0;

  @override
  Stream<List<DiscoveredCamera>> get results => _results.stream;

  Future<void> _start() async {
    if (_closed) return;
    try {
      final addresses =
          await (service.localAddresses ??
              OnvifDiscoveryService._localAddresses)();
      if (_closed) return;
      final destination = InternetAddress(service.probeAddress);
      Object? lastError;
      for (final address in addresses.toSet()) {
        if (_closed) return;
        RawDatagramSocket? socket;
        try {
          // Ephemeral source ports receive unicast ProbeMatches. Never bind
          // the cameras' VISCA ports or compete with another discovery client.
          socket = await RawDatagramSocket.bind(
            address,
            0,
            reuseAddress: false,
          );
          if (_closed) {
            socket.close();
            return;
          }
          socket.writeEventsEnabled = false;
          if (destination.isMulticast) {
            socket.multicastHops = 1;
            socket.setRawOption(
              RawSocketOption(
                RawSocketOption.levelIPv4,
                RawSocketOption.IPv4MulticastInterface,
                address.rawAddress,
              ),
            );
          }
          final listeningSocket = socket;
          _subscriptions.add(
            socket.listen((event) {
              if (event != RawSocketEvent.read || _closed) return;
              Datagram? datagram;
              while (!_closed &&
                  (datagram = listeningSocket.receive()) != null) {
                _receive(datagram!.data);
              }
            }, onError: _fail),
          );
          _sockets.add(socket);
        } on Exception catch (error) {
          socket?.close();
          lastError = error;
        }
      }
      if (_sockets.isEmpty) {
        throw SocketException(
          lastError == null
              ? 'No active IPv4 network connection is available.'
              : 'Could not open a discovery socket: $lastError',
        );
      }
      // Empty Types/Scopes match both older NetworkVideoTransmitter devices
      // and newer tds:Device implementations. Filter non-ONVIF replies below.
      final probe = utf8.encode(
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<s:Envelope xmlns:s="$_soap" xmlns:a="$_addressing" xmlns:d="$_discovery">'
        '<s:Header><a:Action s:mustUnderstand="1">$_discovery/Probe</a:Action>'
        '<a:MessageID>$_messageId</a:MessageID>'
        '<a:ReplyTo><a:Address>$_addressing/role/anonymous</a:Address></a:ReplyTo>'
        '<a:To s:mustUnderstand="1">urn:schemas-xmlsoap-org:ws:2005:04:discovery</a:To>'
        '</s:Header><s:Body><d:Probe/></s:Body></s:Envelope>',
      );
      void send() {
        if (_closed) return;
        for (final socket in _sockets) {
          try {
            if (socket.send(probe, destination, service.probePort) > 0) _sent++;
          } on SocketException catch (error) {
            lastError = error;
          }
        }
      }

      send();
      // UDP delivery is unreliable; retransmit the same message ID so devices
      // can recognize duplicates and responses still match this scan.
      for (final delay in [
        const Duration(milliseconds: 500),
        const Duration(milliseconds: 1500),
      ]) {
        if (delay < service.duration) _timers.add(Timer(delay, send));
      }
      _timers.add(
        Timer(service.duration, () {
          if (_sent == 0) {
            _fail(
              SocketException(
                'Could not send a discovery probe${lastError == null ? '.' : ': $lastError'}',
              ),
            );
          } else {
            cancel();
          }
        }),
      );
    } catch (error, stack) {
      _fail(error, stack);
    }
  }

  void _receive(List<int> bytes) {
    if (bytes.length > 65507) return;
    try {
      final source = utf8.decode(bytes);
      if (source.toUpperCase().contains('<!DOCTYPE')) return;
      final root = XmlDocument.parse(source).rootElement;
      if (root.name.local != 'Envelope' || root.namespaceUri != _soap) return;
      final header = _child(root, 'Header', const [_soap]);
      if (_child(
                header,
                'RelatesTo',
                _addressingNamespaces,
              )?.innerText.trim() !=
              _messageId ||
          _child(header, 'Action', _addressingNamespaces)?.innerText.trim() !=
              '$_discovery/ProbeMatches') {
        return;
      }
      final body = _child(root, 'Body', const [_soap]);
      final matches = _child(body, 'ProbeMatches', const [_discovery]);
      if (matches == null) return;
      var changed = false;
      for (final match in matches.childElements.where(
        (e) => e.name.local == 'ProbeMatch' && e.namespaceUri == _discovery,
      )) {
        final endpoint = _child(
          match,
          'EndpointReference',
          _addressingNamespaces,
        );
        final address = _child(
          endpoint,
          'Address',
          _addressingNamespaces,
        )?.innerText.trim();
        if (address == null || address.isEmpty) continue;
        final typesNode = _child(match, 'Types', const [_discovery]);
        final types = _words(typesNode);
        final scopes = _words(_child(match, 'Scopes', const [_discovery]));
        final isOnvif =
            scopes.any((value) => value.startsWith('onvif://www.onvif.org/')) ||
            types.any((value) => _onvifType(typesNode!, value));
        if (!isOnvif) continue;
        final found = DiscoveredCamera(
          address: address,
          types: types,
          scopes: scopes,
          xAddrs: _words(_child(match, 'XAddrs', const [_discovery])),
        );
        final key = address.toLowerCase().startsWith('urn:uuid:')
            ? address.toLowerCase()
            : address;
        final previous = _devices[key];
        final updated = previous?.merge(found) ?? found;
        if (!identical(previous, updated)) {
          _devices[key] = updated;
          changed = true;
        }
      }
      if (changed && !_closed) _results.add(List.unmodifiable(_devices.values));
    } on FormatException {
      // Ignore malformed UDP packets and continue listening for other devices.
    } on XmlException {
      // This port may also carry unrelated discovery traffic.
    }
  }

  void _fail(Object error, [StackTrace? stack]) {
    if (_closed) return;
    _results.addError(error, stack);
    cancel();
  }

  @override
  void cancel() {
    if (_closed) return;
    _closed = true;
    for (final timer in _timers) {
      timer.cancel();
    }
    for (final socket in _sockets) {
      socket.close();
    }
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_results.close());
  }

  static XmlElement? _child(
    XmlElement? parent,
    String name,
    List<String> namespaces,
  ) {
    if (parent == null) return null;
    for (final child in parent.childElements) {
      if (child.name.local == name && namespaces.contains(child.namespaceUri)) {
        return child;
      }
    }
    return null;
  }

  static List<String> _words(XmlElement? node) => (node?.innerText.trim() ?? '')
      .split(RegExp(r'\s+'))
      .where((s) => s.isNotEmpty)
      .toList();

  static bool _onvifType(XmlElement node, String type) {
    final parts = type.split(':');
    if (parts.length > 2) return false;
    final attribute = parts.length == 1 ? 'xmlns' : 'xmlns:${parts.first}';
    for (
      XmlElement? element = node;
      element != null;
      element = element.parentElement
    ) {
      final namespace = element.getAttribute(attribute);
      if (namespace == null) continue;
      return (namespace == 'http://www.onvif.org/ver10/device/wsdl' &&
              parts.last == 'Device') ||
          (namespace == 'http://www.onvif.org/ver10/network/wsdl' &&
              parts.last == 'NetworkVideoTransmitter');
    }
    return false;
  }

  static String _newMessageId() {
    final random = Random.secure();
    final bytes = List.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return 'urn:uuid:${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}
