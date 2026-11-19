import 'dart:async';
import 'dart:math' as math;

import '../models/camera_limits.dart';
import 'visca_client.dart';
import 'visca_protocol.dart';

/// Measures one axis at a time, stopping on errors, cancellation, or timeout.
class CameraLimitTester {
  CameraLimitTester(
    this.client, {
    this.pollInterval = const Duration(milliseconds: 250),
    this.settleDuration = const Duration(seconds: 2),
    this.travelTimeout = const Duration(seconds: 90),
    this.stableSamples = 6,
  });

  final ViscaClient client;
  final Duration pollInterval, settleDuration, travelTimeout;
  final int stableSamples;
  bool _cancelled = false;
  Future<void>? _stopping;
  static final _panTiltStop = Visca.drive(12, 10, 3, 3);
  static final _zoomStop = Visca.camera(7, [0]);

  Future<void> cancel() {
    _cancelled = true;
    return _stopAll();
  }

  void _checkCancelled() {
    if (_cancelled) throw StateError('Limit test stopped');
  }

  Future<void> _stopAll() => _stopping ??= _sendStops().whenComplete(() {
    _stopping = null;
  });

  Future<void> _sendStops() async {
    await client.send(
      'Stop limit test pan / tilt',
      _panTiltStop,
      priority: true,
    );
    await client.send('Stop limit test zoom', _zoomStop, priority: true);
  }

  Future<int> _position(int axis) async {
    _checkCancelled();
    final reply = await client.send(
      'Read limit test ${['pan', 'tilt', 'zoom'][axis]}',
      axis == 2 ? Visca.zoomInquiry : Visca.panTiltInquiry,
    );
    _checkCancelled();
    if (reply == null || reply.length != (axis == 2 ? 7 : 11)) {
      throw StateError('Could not read camera position');
    }
    final offset = axis == 1 ? 6 : 2;
    return Visca.nibbles(reply.sublist(offset, offset + 4), signed: axis != 2);
  }

  Future<int> _end(int axis, bool positive) async {
    var previous = await _position(axis);
    final command = axis == 2
        ? Visca.lens(focus: false, positive: positive, speed: 7)
        : Visca.drive(
            12,
            10,
            axis == 0 ? (positive ? 2 : 1) : 3,
            axis == 1 ? (positive ? 1 : 2) : 3,
          );
    try {
      _checkCancelled();
      final reply = await client.send(
        'Move to ${['pan', 'tilt', 'zoom'][axis]} limit',
        command,
        motion: true,
      );
      _checkCancelled();
      if (reply == null) throw StateError('Camera rejected limit movement');
      final elapsed = Stopwatch()..start();
      var stable = 0;
      while (elapsed.elapsed < travelTimeout) {
        await Future<void>.delayed(pollInterval);
        final value = await _position(axis);
        stable = value == previous ? stable + 1 : 0;
        previous = value;
        if (stable >= stableSamples && elapsed.elapsed >= settleDuration) {
          return value;
        }
      }
      throw StateError('Timed out measuring camera limits');
    } finally {
      await _stopAll();
    }
  }

  Future<CameraLimits> run() async {
    try {
      final bounds = <int>[];
      for (var axis = 0; axis < 3; axis++) {
        final first = await _end(axis, false);
        final second = await _end(axis, true);
        _checkCancelled();
        if (first == second) {
          throw StateError(
            'No ${['pan', 'tilt', 'zoom'][axis]} travel detected',
          );
        }
        bounds.addAll([math.min(first, second), math.max(first, second)]);
      }
      _checkCancelled();
      final homeReply = await client.send(
        'Return home after limit test',
        Visca.home,
        motion: true,
        waitForCompletion: true,
        replyTimeout: travelTimeout,
      );
      _checkCancelled();
      if (homeReply == null) {
        throw StateError('Camera did not finish returning home');
      }
      return CameraLimits(
        panMin: bounds[0],
        panMax: bounds[1],
        tiltMin: bounds[2],
        tiltMax: bounds[3],
        zoomMin: bounds[4],
        zoomMax: bounds[5],
      );
    } finally {
      await _stopAll();
      _checkCancelled();
    }
  }
}
