import 'dart:async';
import 'dart:collection';
import 'dart:io';

import '../models/camera.dart';
import 'visca_protocol.dart';

class CommandLog {
  CommandLog(this.direction, this.description, this.endpoint, this.bytes)
    : time = DateTime.now();
  final DateTime time;
  final String direction;
  final String description;
  final String endpoint;
  final List<int> bytes;
}

class _Request {
  _Request(
    this.description,
    this.payload,
    this.motion,
    this.waitForCompletion,
    this.replyTimeout,
  );
  final String description;
  final List<int> payload;
  final bool motion;
  final bool waitForCompletion;
  final Duration? replyTimeout;
  int? socket;
  final result = Completer<List<int>?>();
  Completer<List<int>?>? reply;
  int? sequence;
}

/// One endpoint per socket; serializes requests and prioritizes stop commands.
/// A UDP send alone never establishes camera connectivity.
class ViscaClient {
  ViscaClient(
    this.camera, {
    required this.onLog,
    required this.onReply,
    required this.onError,
    this.timeout = const Duration(milliseconds: 700),
  });
  final Camera camera;
  final void Function(CommandLog) onLog;
  final void Function() onReply;
  final void Function(String) onError;
  final Duration timeout;
  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _subscription;
  final _queue = Queue<_Request>();
  _Request? _active;
  bool _draining = false;
  bool _closed = false;
  int _sequence = 0;
  Completer<void>? _resetReply;

  Future<void> open() async {
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      camera.localPort,
    );
    if (_closed) {
      socket.close();
      return;
    }
    _socket = socket;
    _subscription = socket.listen(
      _read,
      onError: (Object error) {
        onError('UDP error: $error');
      },
    );
    if (camera.transport == ViscaTransport.sony) {
      _resetReply = Completer<void>();
      const reset = [2, 0, 0, 1, 0, 0, 0, 0, 1];
      socket.send(reset, InternetAddress(camera.host), camera.port);
      onLog(CommandLog('TX', 'Reset Sony sequence', camera.endpoint, reset));
      await _resetReply!.future.timeout(
        timeout,
        onTimeout: () {
          onLog(
            CommandLog('!', 'No sequence reset reply', camera.endpoint, []),
          );
        },
      );
      _resetReply = null;
    }
  }

  Future<List<int>?> send(
    String description,
    List<int> payload, {
    bool priority = false,
    bool motion = false,
    bool waitForCompletion = false,
    Duration? replyTimeout,
  }) {
    if (_closed) return Future.value(null);
    final request = _Request(
      description,
      List.of(payload),
      motion,
      waitForCompletion,
      replyTimeout,
    );
    if (priority) {
      // A release must also cancel movement that has not reached the wire.
      final cancelled = _queue.where((r) => r.motion).toList();
      for (final r in cancelled) {
        _queue.remove(r);
        r.result.complete(null);
      }
      _queue.addFirst(request);
      final pending = _active?.reply;
      if (pending != null && !pending.isCompleted) pending.complete(null);
    } else {
      _queue.add(request);
    }
    unawaited(_drain());
    return request.result.future;
  }

  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    try {
      while (_queue.isNotEmpty && !_closed) {
        final request = _queue.removeFirst();
        _active = request;
        request.reply = Completer<List<int>?>();
        request.sequence = _sequence;
        _sequence = (_sequence + 1) & 0xffffffff;
        try {
          final bytes = camera.transport == ViscaTransport.sony
              ? Visca.frame(request.payload, request.sequence!)
              : request.payload;
          final sent = _socket?.send(
            bytes,
            InternetAddress(camera.host),
            camera.port,
          );
          if (sent != bytes.length) {
            throw const SocketException('UDP datagram was not sent');
          }
          onLog(CommandLog('TX', request.description, camera.endpoint, bytes));
          final reply = await request.reply!.future.timeout(
            request.replyTimeout ?? timeout,
            onTimeout: () {
              onLog(
                CommandLog(
                  '!',
                  'No reply: ${request.description}',
                  camera.endpoint,
                  [],
                ),
              );
              return null;
            },
          );
          if (!request.result.isCompleted) request.result.complete(reply);
        } catch (error) {
          onError('Send failed: $error');
          if (!request.result.isCompleted) request.result.complete(null);
        } finally {
          _active = null;
        }
      }
    } finally {
      _draining = false;
    }
  }

  void _read(RawSocketEvent event) {
    if (event != RawSocketEvent.read || _closed) return;
    Datagram? datagram;
    while ((datagram = _socket?.receive()) != null) {
      final packet = datagram!;
      if (packet.address.address != camera.host || packet.port != camera.port) {
        continue;
      }
      var payload = packet.data.toList();
      int? sequence;
      if (camera.transport == ViscaTransport.sony) {
        if (payload.length == 9 &&
            payload[0] == 2 &&
            payload[1] == 1 &&
            payload[2] == 0 &&
            payload[3] == 1 &&
            payload[8] == 1) {
          final reset = _resetReply;
          if (reset != null && !reset.isCompleted) reset.complete();
          onLog(
            CommandLog(
              'RX',
              'Sony sequence reset acknowledged',
              camera.endpoint,
              payload,
            ),
          );
          continue;
        }
        if (payload.length >= 10 && payload[0] == 2 && payload[1] == 0) {
          onLog(
            CommandLog('RX', 'Sony transport error', camera.endpoint, payload),
          );
          onError(
            'Sony transport error. Try reconnecting to reset the sequence.',
          );
          continue;
        }
        final framed = Visca.unframe(payload);
        if (framed == null) {
          onLog(
            CommandLog(
              'RX',
              'Invalid or control packet',
              camera.endpoint,
              packet.data.toList(),
            ),
          );
          continue;
        }
        payload = framed.payload;
        sequence = framed.sequence;
      }
      if (!Visca.validReply(payload)) {
        onLog(
          CommandLog(
            'RX',
            'Malformed reply',
            camera.endpoint,
            packet.data.toList(),
          ),
        );
        continue;
      }
      onReply();
      final kind = payload[1] & 0xf0;
      final description = kind == 0x60 && payload.length >= 4
          ? Visca.error(payload[2])
          : kind == 0x40
          ? 'Acknowledged'
          : 'Completion / inquiry reply';
      onLog(
        CommandLog('RX', description, camera.endpoint, packet.data.toList()),
      );
      final active = _active;
      if (kind == 0x60 && payload.length >= 4) onError(description);
      if (active == null ||
          active.reply!.isCompleted ||
          (sequence != null && sequence != active.sequence)) {
        continue;
      }
      final inquiry = active.payload[1] == 9;
      // In raw UDP, inquiries have no identifiers. Match their known reply shape.
      final expectedLength = active.payload[3] == 0x12
          ? 11
          : (active.payload[3] == 0x47 ||
                Visca.imageValueInquiries.containsKey(active.payload[3]))
          ? 7
          : 4;
      if (!inquiry && kind == 0x40) active.socket = payload[1] & 15;
      final completion =
          kind == 0x50 &&
          payload.length == 3 &&
          (active.socket == null || active.socket == (payload[1] & 15));
      if (kind == 0x60 ||
          (!inquiry &&
              (completion || (kind == 0x40 && !active.waitForCompletion))) ||
          (inquiry &&
              kind == 0x50 &&
              payload[1] == 0x50 &&
              payload.length == expectedLength)) {
        active.reply!.complete(kind == 0x60 ? null : payload);
      }
    }
  }

  void close() {
    _closed = true;
    final reset = _resetReply;
    if (reset != null && !reset.isCompleted) reset.complete();
    final reply = _active?.reply;
    if (reply != null && !reply.isCompleted) reply.complete(null);
    for (final request in _queue) {
      request.result.complete(null);
    }
    _queue.clear();
    unawaited(_subscription?.cancel());
    _socket?.close();
    _socket = null;
  }
}
