import 'dart:async';
import 'dart:ui' show ViewFocusEvent, ViewFocusState;

import 'package:material_ui/material_ui.dart';

import '../controller.dart';
import '../models/camera.dart';
import '../services/debug_log_export.dart';
import '../services/camera_settings_transfer.dart';
import '../services/onvif_discovery.dart';
import '../services/visca_protocol.dart';
import 'camera_editor.dart';
import 'camera_discovery_dialog.dart';
import 'connection_status.dart';
import 'hold_button.dart';
import 'focus_depth_icon.dart';
import 'preset_editor.dart';

const _accent = Color(0xff62dfc4);
const _muted = Color(0xff9aadb6);

class ControlShell extends StatefulWidget {
  const ControlShell({
    super.key,
    this.controller,
    this.discoveryService = const OnvifDiscoveryService(),
  });
  final PtzController? controller;
  final OnvifDiscoveryService discoveryService;

  @override
  State<ControlShell> createState() => _ControlShellState();
}

class _ControlShellState extends State<ControlShell>
    with WidgetsBindingObserver {
  late final PtzController c;
  int _tab = 0;
  bool _savingDebugLog = false;
  bool _transferringCameraSettings = false;
  bool _findingCameras = false;

  @override
  void initState() {
    super.initState();
    c = widget.controller ?? PtzController();
    WidgetsBinding.instance.addObserver(this);
    unawaited(c.initialize());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    unawaited(c.setPaused(state != AppLifecycleState.resumed));
  }

  @override
  void didChangeViewFocus(ViewFocusEvent event) {
    if (event.state == ViewFocusState.unfocused) unawaited(c.endMotion());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (widget.controller == null) c.dispose();
    super.dispose();
  }

  Future<void> _navigate(int index) async {
    if (index == _tab) return;
    if (c.changingOsdNavigation || c.osdBusy) return;
    if (c.osdNavigation) {
      await c.setOsdNavigation(false, refreshStatus: false);
    }
    await c.endMotion();
    if (!mounted) return;
    setState(() => _tab = index);
    if (index == 0) await c.refreshControlStatus();
    if (index == 1) await c.refreshImageSettings();
  }

  Future<void> _edit([Camera? camera]) async {
    await c.endMotion();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => CameraEditor(
        camera: camera,
        newCameraId: c.nextCameraId,
        onSave: c.saveCamera,
        onTest: c.testCameraConnection,
        onGetInfo: c.getCameraInfo,
        onTestLimits: c.testAndSaveCameraLimits,
        onStopLimits: c.cancelLimitTest,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: c,
    builder: (context, _) => ColoredBox(
      color: const Color(0xff080f13),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400, maxHeight: 800),
          child: Scaffold(
            appBar: AppBar(
              titleSpacing: 16,
              title: const Row(
                children: [
                  Icon(Icons.control_camera_rounded, color: _accent, size: 26),
                  SizedBox(width: 9),
                  Text(
                    'PTZ',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      letterSpacing: 2,
                    ),
                  ),
                  SizedBox(width: 7),
                  Text(
                    'CONTROL',
                    style: TextStyle(
                      fontSize: 12,
                      color: _muted,
                      letterSpacing: 2,
                    ),
                  ),
                ],
              ),
              actions: [
                PopupMenuButton<String>(
                  tooltip: 'More options',
                  onSelected: (value) {
                    switch (value) {
                      case 'debug':
                        c.toggleDebug();
                      case 'navigation':
                        c.toggleNavigation();
                      case 'reconnect':
                        if (c.selected != null) {
                          unawaited(c.select(c.selected!));
                        }
                      case 'about':
                        showAboutDialog(
                          context: context,
                          applicationName: 'PTZ Control',
                          applicationVersion: '1.0',
                          children: [
                            const Text(
                              'VISCA camera control over UDP.\n\nPress and hold to move; release to stop. Position values are camera-native units. UDP delivery is not guaranteed. Command support varies by camera model.',
                            ),
                          ],
                        );
                    }
                  },
                  itemBuilder: (_) => [
                    CheckedPopupMenuItem(
                      value: 'debug',
                      checked: c.debug,
                      child: const Text('Debug console'),
                    ),
                    CheckedPopupMenuItem(
                      value: 'navigation',
                      checked: c.sideNavigation,
                      child: const Text('Navigation on left'),
                    ),
                    PopupMenuItem(
                      value: 'reconnect',
                      enabled: c.selected != null && !c.switching,
                      child: const Text('Reconnect camera'),
                    ),
                    const PopupMenuItem(
                      value: 'about',
                      child: Text('About & help'),
                    ),
                  ],
                ),
                const SizedBox(width: 4),
              ],
            ),
            body: SafeArea(
              top: false,
              child: Row(
                children: [
                  if (c.sideNavigation)
                    NavigationRail(
                      minWidth: 60,
                      groupAlignment: -1,
                      selectedIndex: _tab,
                      onDestinationSelected: _navigate,
                      labelType: NavigationRailLabelType.none,
                      destinations: const [
                        NavigationRailDestination(
                          icon: Tooltip(
                            message: 'Control',
                            child: Icon(Icons.control_camera),
                          ),
                          label: Text('Control'),
                        ),
                        NavigationRailDestination(
                          icon: Tooltip(
                            message: 'Image settings',
                            child: Icon(Icons.tune),
                          ),
                          label: Text('Image'),
                        ),
                        NavigationRailDestination(
                          icon: Tooltip(
                            message: 'Camera setup',
                            child: Icon(Icons.videocam_outlined),
                          ),
                          label: Text('Cameras'),
                        ),
                      ],
                    ),
                  Expanded(
                    child: Column(
                      children: [
                        if (c.message != null) _message(),
                        Expanded(
                          child: c.loading
                              ? const Center(child: CircularProgressIndicator())
                              : _tab == 2
                              ? _cameras()
                              : SingleChildScrollView(
                                  key: ValueKey('$_tab-${c.selected?.id}'),
                                  padding: const EdgeInsets.fromLTRB(
                                    16,
                                    6,
                                    16,
                                    16,
                                  ),
                                  child: switch (_tab) {
                                    0 => _control(),
                                    1 => _settings(),
                                    _ => _cameras(),
                                  },
                                ),
                        ),
                        if (c.debug) _debug(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            bottomNavigationBar: c.sideNavigation
                ? null
                : NavigationBar(
                    selectedIndex: _tab,
                    onDestinationSelected: _navigate,
                    destinations: const [
                      NavigationDestination(
                        icon: Icon(Icons.control_camera),
                        label: 'Control',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.tune),
                        label: 'Image',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.videocam_outlined),
                        label: 'Cameras',
                      ),
                    ],
                  ),
          ),
        ),
      ),
    ),
  );

  Widget _message() => Container(
    color: const Color(0xff493322),
    padding: const EdgeInsets.only(left: 16),
    child: Row(
      children: [
        Expanded(
          child: Text(
            c.message!,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: Color(0xffffd3a5)),
          ),
        ),
        IconButton(
          tooltip: 'Dismiss message',
          onPressed: c.clearMessage,
          icon: const Icon(Icons.close, size: 18),
        ),
      ],
    ),
  );

  Widget _title(String eyebrow, String title, [Widget? trailing]) => Padding(
    padding: const EdgeInsets.only(top: 5, bottom: 16),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                eyebrow.toUpperCase(),
                style: const TextStyle(
                  color: _accent,
                  fontSize: 10,
                  letterSpacing: 1.8,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -.5,
                ),
              ),
            ],
          ),
        ),
        ?trailing,
      ],
    ),
  );

  Widget _card(Widget child) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: const Color(0xff182329),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: const Color(0xff2a3a42)),
    ),
    child: child,
  );

  Widget _selector() => DropdownButtonFormField<int>(
    key: ValueKey('${c.selected?.id}-${c.selected?.name}'),
    initialValue: c.selected?.id,
    isExpanded: true,
    decoration: const InputDecoration(
      labelText: 'Selected camera',
      prefixIcon: Icon(Icons.videocam_outlined, size: 20),
    ),
    hint: const Text('Choose a camera'),
    items: c.cameras
        .map(
          (camera) => DropdownMenuItem(
            value: camera.id,
            child: Text(camera.name, overflow: TextOverflow.ellipsis),
          ),
        )
        .toList(),
    onChanged:
        c.switching ||
            c.presetBusy ||
            c.osdNavigation ||
            c.changingOsdNavigation
        ? null
        : (id) {
            if (id != null) {
              unawaited(
                c.select(c.cameras.firstWhere((camera) => camera.id == id)),
              );
            }
          },
  );

  Widget _status() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 14,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ConnectionStatus(
              connected: c.connection == CameraConnection.connected,
              label: c.statusLabel,
            ),
            Text(
              c.selected?.endpoint ?? '—',
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                color: _muted,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            _modeStatus('EXPOSURE', c.exposureModeLabel),
            const SizedBox(width: 12),
            _modeStatus('WHITE BALANCE', c.whiteBalanceModeLabel),
          ],
        ),
      ],
    );
  }

  Widget _modeStatus(String label, String value) => Expanded(
    child: Align(
      alignment: Alignment.centerLeft,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          '$label: $value',
          style: const TextStyle(fontSize: 11, color: _muted),
        ),
      ),
    ),
  );

  Widget _empty() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 24),
    child: Column(
      children: [
        const Icon(Icons.linked_camera_outlined, size: 50, color: _muted),
        const SizedBox(height: 16),
        const Text(
          'Your cameras, within reach',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        const Text(
          'Add a camera’s IP address and UDP port\nto start controlling it.',
          textAlign: TextAlign.center,
          style: TextStyle(color: _muted, height: 1.5),
        ),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: c.saving ? null : () => _edit(),
          icon: const Icon(Icons.add),
          label: const Text('Add camera'),
        ),
      ],
    ),
  );

  Widget _control() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (c.cameras.isEmpty)
        _card(_empty())
      else ...[
        Row(
          children: [
            Expanded(child: _selector()),
            const SizedBox(width: 6),
            IconButton(
              tooltip: 'Refresh camera status',
              onPressed: c.canOperate ? () => unawaited(c.refresh()) : null,
              icon: const Icon(Icons.refresh, size: 21),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _card(_status()),
        const SizedBox(height: 12),
        _controlDeck(),
        _presets(),
        const SizedBox(height: 4),
        _presetSaveOptions(),
        if (c.presetBusy)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: LinearProgressIndicator(minHeight: 2),
          ),
      ],
    ],
  );

  Widget _presetSaveOptions() => LayoutBuilder(
    builder: (context, constraints) {
      final save = _check(
        'Save preset',
        c.savePresetMode,
        c.setSavePresetMode,
        enabled: !c.presetBusy && !c.osdNavigation && !c.changingOsdNavigation,
        fontSize: 11,
      );
      final aperture = _check(
        c.savePresetMode
            ? 'Save exposure with preset'
            : 'Use exposure from preset',
        c.saveExposureWithPreset,
        c.setSaveExposureWithPreset,
        enabled: !c.presetBusy && !c.osdNavigation && !c.changingOsdNavigation,
        fontSize: 11,
        textAlign: TextAlign.start,
      );
      // Account for the left rail so the aperture option starts at the
      // window midpoint with either navigation placement.
      final leftWidth =
          (constraints.maxWidth - (c.sideNavigation ? 60 : 0)) / 2;
      return Row(
        children: [
          SizedBox(width: leftWidth, child: save),
          Expanded(child: aperture),
        ],
      );
    },
  );

  Widget _check(
    String label,
    bool value,
    ValueChanged<bool>? onChanged, {
    bool enabled = true,
    double fontSize = 12,
    TextAlign textAlign = TextAlign.start,
  }) => InkWell(
    onTap: enabled && onChanged != null ? () => onChanged(!value) : null,
    borderRadius: BorderRadius.circular(6),
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 28),
      child: Row(
        children: [
          SizedBox(
            width: 22,
            height: 24,
            child: Checkbox(
              value: value,
              onChanged: enabled && onChanged != null
                  ? (v) => onChanged(v!)
                  : null,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
          ),
          const SizedBox(width: 5),
          Expanded(
            child: Text(
              label,
              maxLines: 2,
              textAlign: textAlign,
              style: TextStyle(
                fontSize: fontSize,
                color: enabled ? null : _muted,
              ),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _controlDeck() => LayoutBuilder(
    builder: (context, constraints) {
      const columnHeight = 194.0;
      final wide = constraints.maxWidth >= 348;
      final padWidth = wide ? 168.0 : 120.0;
      final movementGap = wide ? 24.0 : 12.0;
      final movementMode = _check(
        'Move until stopped',
        c.moveUntilStopped,
        c.setMoveUntilStopped,
        enabled: c.canOperate,
        fontSize: 10,
      );
      final aperture = _stepSetting(
        'Aperture / iris',
        0x0b,
        'Close',
        'Open',
        value: c.aperture,
        compact: true,
        enabled: !c.moving && [0x03, 0x0b].contains(c.exposureMode),
      );
      final home = c.osdNavigation
          ? SizedBox(height: 36, child: _osdButton(OsdKey.menu, Icons.menu))
          : IconButton(
              tooltip: 'Return camera home',
              onPressed: c.canOperate && !c.moving
                  ? () => unawaited(c.command('Return home', Visca.home))
                  : null,
              icon: const Icon(Icons.home_outlined, size: 22, color: _accent),
            );
      final alignedHome = Align(
        alignment: Alignment.centerLeft,
        child: SizedBox(
          // The first preset column reserves a 6-pixel gutter on the right.
          width: constraints.maxWidth / 3 - 6,
          child: Center(child: home),
        ),
      );
      final header = Tooltip(
        message: 'Changes controls only. Use Menu / Back to open or close the camera menu.',
        child: _check(
          'OSD navigation',
          c.osdNavigation,
          (enabled) => unawaited(c.setOsdNavigation(enabled)),
          enabled:
              !c.changingOsdNavigation &&
              !c.osdBusy &&
              (c.osdNavigation || c.canOperate),
          fontSize: 11,
        ),
      );
      final speedAndLens = SizedBox(
        key: const Key('speed-controls'),
        height: columnHeight,
        child: LayoutBuilder(
          builder: (context, size) {
            final columnWidth = (size.maxWidth - 36) / 2;
            // Keep room for two digits, the arrow, padding, and borders.
            final reduction = (columnWidth - 60).clamp(0.0, 10.0);
            final fieldWidth = columnWidth - reduction;
            Widget lensRow(String label, int speed, bool focus) => Row(
              children: [
                SizedBox(width: fieldWidth, child: _speed(label, speed, 0, 7)),
                SizedBox(width: 6 + reduction),
                Expanded(
                  child: _lensButton(
                    focus ? 'Focus near' : 'Zoom out',
                    focus ? Icons.visibility_outlined : Icons.zoom_out,
                    focus,
                    false,
                    iconSize: 23,
                    iconWidget: focus ? const FocusDepthIcon(far: false) : null,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: _lensButton(
                    focus ? 'Focus far' : 'Zoom in',
                    focus ? Icons.visibility_outlined : Icons.zoom_in,
                    focus,
                    true,
                    iconSize: 32,
                    iconWidget: focus ? const FocusDepthIcon(far: true) : null,
                  ),
                ),
              ],
            );
            return Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: SizedBox(
                          width: fieldWidth,
                          child: _speed(
                            'Pan',
                            c.panSpeed,
                            1,
                            c.syncPanTilt ? 20 : 24,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    SizedBox(
                      width: 28,
                      height: 44,
                      child: Semantics(
                        toggled: c.syncPanTilt,
                        child: IconButton(
                          key: const Key('sync-pan-tilt'),
                          tooltip: c.syncPanTilt
                              ? 'Disable pan / tilt sync'
                              : 'Enable pan / tilt sync',
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints.tightFor(
                            width: 28,
                            height: 44,
                          ),
                          iconSize: 21,
                          icon: Icon(
                            c.syncPanTilt ? Icons.link : Icons.link_off,
                          ),
                          color: c.syncPanTilt ? _accent : _muted,
                          onPressed: c.moving || !c.canOperate
                              ? null
                              : () => c.setSyncPanTilt(!c.syncPanTilt),
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: SizedBox(
                          width: fieldWidth,
                          child: _speed('Tilt', c.tiltSpeed, 1, 20),
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(
                  height: 44,
                  child: lensRow('Zoom', c.zoomSpeed, false),
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Transform.translate(
                      offset: const Offset(0, -6),
                      child: _check(
                        'Autofocus',
                        c.autofocus ?? false,
                        (value) => unawaited(_focusMode(value)),
                        enabled: c.canOperate && !c.moving,
                        fontSize: 11,
                      ),
                    ),
                    SizedBox(
                      height: 44,
                      child: lensRow('Focus', c.focusSpeed, true),
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      );
      if (constraints.maxWidth < 288) {
        return Column(
          children: [
            SizedBox(width: 168, child: movementMode),
            const SizedBox(height: 6),
            SizedBox(
              key: const Key('movement-grid'),
              width: 168,
              height: columnHeight,
              child: _directionPad(),
            ),
            const SizedBox(height: 12),
            Align(alignment: Alignment.centerLeft, child: header),
            const SizedBox(height: 6),
            speedAndLens,
            const SizedBox(height: 6),
            aperture,
            const SizedBox(height: 28),
            alignedHome,
          ],
        );
      }
      return Column(
        children: [
          Row(
            children: [
              SizedBox(width: padWidth, child: movementMode),
              SizedBox(width: movementGap),
              Expanded(child: header),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                key: const Key('movement-grid'),
                width: padWidth,
                height: columnHeight,
                child: _directionPad(),
              ),
              SizedBox(width: movementGap),
              Expanded(child: speedAndLens),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              SizedBox(
                width: padWidth,
                child: Padding(
                  padding: const EdgeInsets.only(top: 20),
                  child: alignedHome,
                ),
              ),
              SizedBox(width: movementGap),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 20),
                  child: aperture,
                ),
              ),
            ],
          ),
        ],
      );
    },
  );

  Widget _presets() => Column(
    children: List.generate(
      3,
      (row) => Padding(
        padding: EdgeInsets.only(bottom: row < 2 ? 6 : 0),
        child: Row(
          children: List.generate(3, (col) {
            final slot = row * 3 + col + 1;
            final preset = c.preset(slot);
            final label = preset?.name ?? '$slot';
            return Expanded(
              child: Padding(
                padding: EdgeInsets.only(right: col < 2 ? 6 : 0),
                child: SizedBox(
                  height: 48,
                  child: Tooltip(
                    message:
                        '${c.savePresetMode ? 'Save' : 'Recall'} camera preset $slot: $label',
                    child: OutlinedButton(
                      key: ValueKey('preset-$slot'),
                      onPressed: c.canOperate && !c.moving
                          ? () => _activatePreset(slot)
                          : null,
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 4,
                        ),
                        backgroundColor: preset == null
                            ? const Color(0xff182329)
                            : const Color(0xff203b35),
                        side: BorderSide(
                          color: c.savePresetMode
                              ? _accent
                              : const Color(0xff35464f),
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(9),
                        ),
                      ),
                      child: Text(
                        label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 12, height: 1.2),
                      ),
                    ),
                  ),
                ),
              ),
            );
          }),
        ),
      ),
    ),
  );

  Future<void> _activatePreset(int slot) async {
    if (!c.savePresetMode) {
      await c.recallPreset(slot);
      return;
    }
    await c.endMotion();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PresetEditor(controller: c, slot: slot),
    );
  }

  Widget _sectionLabel(String label, String detail) => Row(
    children: [
      Text(
        label,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.2,
        ),
      ),
      const Spacer(),
      Flexible(
        child: Text(
          detail,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 11, color: _muted),
        ),
      ),
    ],
  );

  Widget _directionPad() {
    final directions = [
      ('Pan left / tilt up', Icons.north_west, 1, 1),
      ('Tilt up', Icons.north, 3, 1),
      ('Pan right / tilt up', Icons.north_east, 2, 1),
      ('Pan left', Icons.west, 1, 3),
      ('Stop all movement', Icons.stop_rounded, 3, 3),
      ('Pan right', Icons.east, 2, 3),
      ('Pan left / tilt down', Icons.south_west, 1, 2),
      ('Tilt down', Icons.south, 3, 2),
      ('Pan right / tilt down', Icons.south_east, 2, 2),
    ];
    return Column(
      key: ValueKey(c.osdNavigation),
      children: List.generate(
        3,
        (row) => Padding(
          padding: EdgeInsets.only(bottom: row < 2 ? 6 : 0),
          child: Row(
            children: List.generate(3, (col) {
              final d = directions[row * 3 + col];
              final stop = row == 1 && col == 1;
              return Expanded(
                child: Padding(
                  padding: EdgeInsets.only(right: col < 2 ? 6 : 0),
                  child: SizedBox(
                    height: (194 - 12) / 3,
                    child: c.osdNavigation && (row == 1 || col == 1)
                        ? _osdButton(switch ((row, col)) {
                            (0, 1) => OsdKey.up,
                            (2, 1) => OsdKey.down,
                            (1, 0) => OsdKey.left,
                            (1, 2) => OsdKey.right,
                            _ => OsdKey.enter,
                          }, d.$2)
                        : HoldButton(
                            label: d.$1,
                            icon: d.$2,
                            // iconColor: stop ? const Color(0xffffb9aa) : null,
                            iconColor: stop ? const Color(0xfff55656) : null,
                            tooltip: stop
                                ? d.$1
                                : c.moveUntilStopped
                                ? '${d.$1} · move until stopped'
                                : null,
                            enabled:
                                !c.osdNavigation &&
                                !c.changingOsdNavigation &&
                                (stop ? c.canControl : c.canOperate),
                            compact: true,
                            stopOnRelease: stop || !c.moveUntilStopped,
                            active: !stop && c.motionOwnedBy(d.$1),
                            onStart: () {
                              if (stop) {
                                unawaited(c.stopAll());
                                return true;
                              }
                              return c.startPanTilt(
                                d.$1,
                                d.$3,
                                d.$4,
                                owner: d.$1,
                              );
                            },
                            onStop: () {
                              if (!stop) unawaited(c.endMotion(owner: d.$1));
                            },
                          ),
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }

  Widget _osdButton(OsdKey key, IconData icon) => HoldButton(
    key: ValueKey('osd-${key.name}'),
    label: switch (key) {
      OsdKey.menu => 'OSD Menu / Back',
      OsdKey.enter => 'OSD Enter',
      _ => 'OSD ${key.name}',
    },
    tooltip: key == OsdKey.menu
        ? 'Open the camera menu or go back; repeat to exit'
        : key == OsdKey.enter
        ? 'OSD Enter'
        : 'OSD ${key.name}',
    icon: icon,
    text: switch (key) {
      OsdKey.menu => 'Menu / Back',
      OsdKey.enter => 'Enter',
      _ => null,
    },
    compact: true,
    enabled: c.canNavigateOsd,
    onStart: () {
      unawaited(c.osdCommand(key));
      return true;
    },
    // Directional commands include their own immediate stop in the controller.
    onStop: () {},
  );

  Widget _speed(String label, int value, int min, int max) => SizedBox(
    height: 44,
    child: DropdownButtonFormField<int>(
      key: ValueKey('$label-$value'),
      initialValue: value,
      isExpanded: true,
      isVerticallyExpanded: true,
      iconSize: 16,
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(fontSize: 11),
        contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
      ),
      style: const TextStyle(
        fontSize: 13,
        color: Colors.white,
        fontFamily: 'monospace',
      ),
      items: List.generate(
        max - min + 1,
        (i) => DropdownMenuItem(value: min + i, child: Text('${min + i}')),
      ),
      onChanged:
          c.moving ||
              !c.canOperate ||
              (label == 'Focus' && c.autofocus != false)
          ? null
          : (v) {
              if (v != null) c.setSpeed(label, v);
            },
    ),
  );

  Widget _lensButton(
    String label,
    IconData icon,
    bool focus,
    bool positive, {
    double iconSize = 25,
    Widget? iconWidget,
  }) => HoldButton(
    label: label,
    icon: icon,
    iconSize: iconSize,
    iconWidget: iconWidget,
    compact: true,
    enabled: c.canOperate && (!focus || c.autofocus == false),
    onStart: () => c.startMotion(
      label,
      Visca.lens(
        focus: focus,
        positive: positive,
        speed: focus ? c.focusSpeed : c.zoomSpeed,
      ),
      Visca.camera(focus ? 8 : 7, [0]),
      owner: label,
    ),
    onStop: () => unawaited(c.endMotion(owner: label)),
  );

  Widget _settings() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _title('Selected camera', 'Image settings'),
      if (c.cameras.isEmpty)
        _card(_empty())
      else ...[
        _selector(),
        const SizedBox(height: 12),
        const Text(
          'Choose a mode or use the step buttons to send a command. Available values depend on your camera.',
          style: TextStyle(color: _muted, fontSize: 12, height: 1.5),
        ),
        const SizedBox(height: 16),
        _card(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionLabel('EXPOSURE', 'Commands'),
              const SizedBox(height: 14),
              _mode('Exposure mode', {
                0: 'Full auto',
                3: 'Manual',
                10: 'Shutter priority',
                11: 'Iris priority',
              }, 0x39),
              const SizedBox(height: 10),
              _stepSetting(
                'Aperture / iris',
                0x0b,
                'Close',
                'Open',
                value: c.aperture,
              ),
              _stepSetting(
                'Shutter speed',
                0x0a,
                'Slower',
                'Faster',
                value: c.shutterSpeed,
              ),
              _stepSetting('Gain', 0x0c, 'Lower', 'Higher', value: c.gain),
              const Text(
                'For manual adjustments, select Manual or the matching priority mode first.',
                style: TextStyle(fontSize: 11, color: _muted),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _card(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionLabel('COLOR', 'Commands'),
              const SizedBox(height: 14),
              _mode('White balance', {
                0: 'Auto',
                1: 'Indoor',
                2: 'Outdoor',
                3: 'One push',
                5: 'Manual',
              }, 0x35),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: c.canOperate ? _confirmOnePushBalance : null,
                icon: const Icon(Icons.wb_sunny_outlined, size: 18),
                label: const Text('Trigger One-Push white balance'),
              ),
              _stepSetting('Red gain', 3, 'Lower', 'Higher', value: c.redGain),
              _stepSetting(
                'Blue gain',
                4,
                'Lower',
                'Higher',
                value: c.blueGain,
              ),
              const Text(
                'Select Manual white balance before adjusting gains.',
                style: TextStyle(fontSize: 11, color: _muted),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _card(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionLabel(
                'FOCUS',
                c.autofocus == null
                    ? 'Unknown'
                    : c.autofocus!
                    ? 'Auto'
                    : 'Manual',
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: c.canControl ? () => _focusMode(true) : null,
                      child: const Text('Auto'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: c.canControl ? () => _focusMode(false) : null,
                      child: const Text('Manual'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                'Manual focus controls are on the Control tab.',
                style: TextStyle(color: _muted, fontSize: 11),
              ),
            ],
          ),
        ),
      ],
    ],
  );

  Future<void> _confirmOnePushBalance() async {
    final cameraId = c.selected?.id;
    await c.endMotion();
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset white balance with One-Push?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Yes'),
          ),
        ],
      ),
    );
    if (confirmed == true &&
        mounted &&
        c.selected?.id == cameraId &&
        c.canOperate) {
      await c.command('One-push white balance', Visca.camera(0x10, [5]));
    }
  }

  Future<void> _focusMode(bool auto) async {
    await c.command(
      auto ? 'Autofocus on' : 'Manual focus',
      Visca.camera(0x38, [auto ? 2 : 3]),
    );
  }

  Widget _mode(String label, Map<int, String> values, int command) {
    final mode = command == 0x39 ? c.exposureMode : c.whiteBalanceMode;
    return InputDecorator(
      decoration: InputDecoration(labelText: label),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<int>(
          isExpanded: true,
          isDense: true,
          value: values.containsKey(mode) ? mode : null,
          hint: const Text('Unknown', style: TextStyle(fontSize: 13)),
          items: values.entries
              .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
              .toList(),
          onChanged: c.canOperate && !c.moving
              ? (v) {
                  if (v != null) {
                    unawaited(
                      c.command(
                        '$label: ${values[v]}',
                        Visca.camera(command, [v]),
                      ),
                    );
                  }
                }
              : null,
        ),
      ),
    );
  }

  Widget _stepSetting(
    String label,
    int command,
    String less,
    String more, {
    int? value,
    bool compact = false,
    bool enabled = true,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        Expanded(
          child: Text(label, style: TextStyle(fontSize: compact ? 11 : 13)),
        ),
        IconButton(
          tooltip: '$label: $less',
          padding: compact ? EdgeInsets.zero : const EdgeInsets.all(8),
          constraints: compact
              ? const BoxConstraints.tightFor(width: 28, height: 32)
              : null,
          onPressed: c.canOperate && enabled
              ? () => unawaited(
                  c.command('$label: $less', Visca.camera(command, [3])),
                )
              : null,
          icon: const Icon(Icons.remove_circle_outline, size: 21),
        ),
        IconButton(
          tooltip: '$label: $more',
          padding: compact ? EdgeInsets.zero : const EdgeInsets.all(8),
          constraints: compact
              ? const BoxConstraints.tightFor(width: 28, height: 32)
              : null,
          onPressed: c.canOperate && enabled
              ? () => unawaited(
                  c.command('$label: $more', Visca.camera(command, [2])),
                )
              : null,
          icon: const Icon(Icons.add_circle_outline, size: 21),
        ),
        SizedBox(width: compact ? 4 : 8),
        SizedBox(
          width: compact ? 28 : 48,
          child: Tooltip(
            message: 'Raw VISCA value',
            child: Text(
              value?.toString() ?? '—',
              key: ValueKey('image-value-$command'),
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontSize: 12,
                fontFamily: 'monospace',
                color: _muted,
              ),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _cameras() => ReorderableListView(
    key: const ValueKey('camera-list'),
    padding: const EdgeInsets.all(16),
    buildDefaultDragHandles: false,
    onReorderItem: (oldIndex, newIndex) =>
        unawaited(c.reorderCamera(oldIndex, newIndex)),
    header: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _title(
          'Network setup',
          'Your cameras',
          Text(
            '${c.cameras.length} / 8',
            style: const TextStyle(color: _muted),
          ),
        ),
        Row(
          children: [
            Expanded(
              flex: 3,
              child: OutlinedButton(
                style: _cameraActionStyle,
                onPressed:
                    !_findingCameras &&
                        !_transferringCameraSettings &&
                        c.canTransferCameraSettings
                    ? _findCameras
                    : null,
                child: const Text('Find cameras'),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              flex: 2,
              child: OutlinedButton(
                style: _cameraActionStyle,
                onPressed:
                    !_findingCameras &&
                        !_transferringCameraSettings &&
                        c.canTransferCameraSettings &&
                        c.cameras.isNotEmpty
                    ? _exportCameraSettings
                    : null,
                child: const Text('Export'),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              flex: 2,
              child: OutlinedButton(
                style: _cameraActionStyle,
                onPressed:
                    !_findingCameras &&
                        !_transferringCameraSettings &&
                        c.canTransferCameraSettings
                    ? _importCameraSettings
                    : null,
                child: const Text('Import'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        const Text(
          'Drag the handles to reorder cameras. This order is also used in the Selected camera list.',
          style: TextStyle(color: _muted, fontSize: 12, height: 1.5),
        ),
        const SizedBox(height: 16),
        if (c.cameras.isEmpty) _card(_empty()),
      ],
    ),
    footer: c.cameras.isNotEmpty
        ? SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: c.cameras.length >= 8 || c.saving || c.switching
                  ? null
                  : () => _edit(),
              icon: const Icon(Icons.add),
              label: Text(
                c.cameras.length >= 8
                    ? 'All 8 camera slots are in use'
                    : 'Add camera',
              ),
            ),
          )
        : null,
    children: c.cameras.indexed.map((entry) {
      final camera = entry.$2;
      return Padding(
        key: ValueKey(camera.id),
        padding: const EdgeInsets.only(bottom: 10),
        child: _card(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: const Color(0xff25483f),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '${camera.id}'.padLeft(2, '0'),
                      style: const TextStyle(
                        color: _accent,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      camera.name,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  ReorderableDragStartListener(
                    index: entry.$1,
                    enabled: !c.saving && !c.switching,
                    child: Semantics(
                      label: 'Reorder ${camera.name}',
                      onIncrease:
                          entry.$1 < c.cameras.length - 1 &&
                              !c.saving &&
                              !c.switching
                          ? () => unawaited(
                              c.reorderCamera(entry.$1, entry.$1 + 1),
                            )
                          : null,
                      onDecrease: entry.$1 > 0 && !c.saving && !c.switching
                          ? () => unawaited(
                              c.reorderCamera(entry.$1, entry.$1 - 1),
                            )
                          : null,
                      child: Tooltip(
                        message: 'Drag to reorder ${camera.name}',
                        child: const SizedBox(
                          width: 32,
                          height: 48,
                          child: Icon(
                            Icons.drag_handle,
                            color: _muted,
                            size: 20,
                          ),
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Edit ${camera.name}',
                    onPressed: c.saving || c.switching
                        ? null
                        : () => _edit(camera),
                    icon: const Icon(Icons.edit_outlined, size: 19),
                  ),
                  IconButton(
                    tooltip: 'Delete ${camera.name}',
                    onPressed: c.saving || c.switching
                        ? null
                        : () => _delete(camera),
                    icon: const Icon(Icons.delete_outline, size: 19),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    flex: 6,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        camera.endpoint,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 7,
                    child: Text(
                      '${camera.protocolLabel} · local ${camera.localPort == 0 ? 'auto' : camera.localPort}',
                      textAlign: TextAlign.right,
                      style: const TextStyle(color: _muted, fontSize: 11),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }).toList(),
  );

  ButtonStyle get _cameraActionStyle => OutlinedButton.styleFrom(
    padding: const EdgeInsets.symmetric(horizontal: 6),
    minimumSize: const Size(0, 40),
    textStyle: const TextStyle(fontSize: 12),
  );

  Future<void> _findCameras() async {
    if (_findingCameras ||
        _transferringCameraSettings ||
        !c.canTransferCameraSettings) {
      return;
    }
    setState(() => _findingCameras = true);
    try {
      await c.endMotion();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) =>
            CameraDiscoveryDialog(discovery: widget.discoveryService),
      );
    } finally {
      if (mounted) setState(() => _findingCameras = false);
    }
  }

  void _transferMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _exportCameraSettings() async {
    if (_transferringCameraSettings || !c.canTransferCameraSettings) return;
    setState(() => _transferringCameraSettings = true);
    try {
      final settings = c.exportCameraSettings();
      await c.endMotion();
      if (!mounted) return;
      final saved = await saveCameraSettings(settings);
      if (mounted && saved != null) {
        _transferMessage('Camera settings exported.');
      }
    } catch (error) {
      if (mounted) _transferMessage('Could not export camera settings: $error');
    } finally {
      if (mounted) setState(() => _transferringCameraSettings = false);
    }
  }

  Future<void> _importCameraSettings() async {
    if (_transferringCameraSettings || !c.canTransferCameraSettings) return;
    setState(() => _transferringCameraSettings = true);
    try {
      await c.endMotion();
      if (!mounted) return;
      final settings = await pickCameraSettings();
      if (!mounted || settings == null) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Import camera settings?'),
          scrollable: true,
          content: SizedBox(
            width: 340,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  c.cameras.isEmpty
                      ? 'Add these ${settings.cameras.length} cameras?'
                      : 'Replace your ${c.cameras.length} saved cameras with these '
                            '${settings.cameras.length} cameras?',
                ),
                const SizedBox(height: 12),
                const Text(
                  'IDs, order, network settings, '
                  'camera info (manufacturer, model, serial number, and MAC address), '
                  'limits, and presets will be restored from the file.',
                ),
                const SizedBox(height: 12),
                for (final camera in settings.cameras)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text('${camera.id}. ${camera.name}'),
                    subtitle: Text(camera.endpoint),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(
                c.cameras.isEmpty ? 'Add cameras' : 'Replace cameras',
              ),
            ),
          ],
        ),
      );
      if (!mounted || confirmed != true) return;
      final imported = await c.importCameraSettings(settings);
      if (!mounted) return;
      _transferMessage(
        imported
            ? 'Camera settings imported.'
            : c.message ?? 'Camera is busy. Try importing again.',
      );
    } on FormatException catch (error) {
      if (mounted) _transferMessage(error.message);
    } catch (error) {
      if (mounted) _transferMessage('Could not import camera settings: $error');
    } finally {
      if (mounted) setState(() => _transferringCameraSettings = false);
    }
  }

  Future<void> _delete(Camera camera) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove camera?'),
        content: Text('Remove ${camera.name} from this device?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed == true) await c.removeCamera(camera);
  }

  Future<void> _saveDebugLog() async {
    if (_savingDebugLog || c.logs.isEmpty) return;
    // Freeze the visible results before opening the picker; polling may continue.
    final snapshot = List.of(c.logs);
    setState(() => _savingDebugLog = true);
    try {
      await c.endMotion();
      if (!mounted) return;
      final result = await saveDebugLog(snapshot);
      if (!mounted || result == null) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Debug log saved.')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text('Could not save debug log: $error')),
        );
    } finally {
      if (mounted) setState(() => _savingDebugLog = false);
    }
  }

  Widget _debug() => Container(
    height: 180,
    decoration: const BoxDecoration(
      color: Color(0xff090f13),
      border: Border(top: BorderSide(color: Color(0xff35464f))),
    ),
    child: Column(
      children: [
        SizedBox(
          height: 36,
          child: Row(
            children: [
              const SizedBox(width: 12),
              const Icon(Icons.terminal, size: 15, color: _accent),
              const SizedBox(width: 7),
              const Text(
                'UDP CONSOLE',
                style: TextStyle(
                  fontSize: 10,
                  letterSpacing: 1,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Save debug log',
                iconSize: 17,
                onPressed: c.logs.isEmpty || _savingDebugLog
                    ? null
                    : _saveDebugLog,
                icon: const Icon(Icons.save_alt_outlined),
              ),
              IconButton(
                tooltip: 'Clear command log',
                iconSize: 17,
                onPressed: c.clearLogs,
                icon: const Icon(Icons.delete_sweep_outlined),
              ),
              IconButton(
                tooltip: 'Hide debug console',
                iconSize: 17,
                onPressed: c.toggleDebug,
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
        Expanded(
          child: c.logs.isEmpty
              ? const Center(
                  child: Text(
                    'Commands and replies appear here.',
                    style: TextStyle(color: _muted, fontSize: 12),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  itemCount: c.logs.length,
                  itemBuilder: (context, index) {
                    final log = c.logs[index];
                    final time = log.time.toIso8601String().substring(11, 23);
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '$time  ${log.direction}  ${log.endpoint}',
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 10,
                              color: log.direction == 'TX'
                                  ? _accent
                                  : const Color(0xffdfb980),
                            ),
                          ),
                          Text(
                            log.description,
                            style: const TextStyle(fontSize: 11, color: _muted),
                          ),
                          if (log.bytes.isNotEmpty)
                            SelectableText(
                              Visca.hex(log.bytes),
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 10,
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    ),
  );
}
