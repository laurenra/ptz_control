import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

/// Supports held and latched movement; cancellation always stops the motion.
class HoldButton extends StatefulWidget {
  const HoldButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onStart,
    required this.onStop,
    required this.enabled,
    this.iconColor,
    this.iconSize = 25,
    this.iconWidget,
    this.tooltip,
    this.text,
    this.compact = false,
    this.stopOnRelease = true,
    this.active = false,
  });
  final String label;
  final IconData icon;
  final bool Function() onStart;
  final VoidCallback onStop;
  final bool enabled;
  final Color? iconColor;
  final double iconSize;
  final Widget? iconWidget;
  final String? tooltip;
  final String? text;
  final bool compact;
  final bool stopOnRelease;
  final bool active;

  @override
  State<HoldButton> createState() => _HoldButtonState();
}

class _HoldButtonState extends State<HoldButton> {
  bool _held = false;
  int? _pointer;
  final _focus = FocusNode();

  void _start() {
    if (_held || !widget.enabled) return;
    if (widget.onStart()) setState(() => _held = true);
  }

  void _stop({bool force = false}) {
    _pointer = null;
    if (!_held && !(force && widget.active)) return;
    setState(() {
      _held = false;
      _pointer = null;
    });
    if (widget.stopOnRelease || force) widget.onStop();
  }

  @override
  void didUpdateWidget(HoldButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled && (_held || oldWidget.active)) _stop(force: true);
  }

  @override
  void dispose() {
    if (_held || widget.active) widget.onStop();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Tooltip(
    message: widget.tooltip ?? '${widget.label} · hold to move',
    child: Semantics(
      button: true,
      enabled: widget.enabled,
      label: widget.label,
      onTap: widget.enabled
          ? () async {
              _start();
              await Future<void>.delayed(const Duration(milliseconds: 180));
              if (mounted) _stop();
            }
          : null,
      child: Focus(
        focusNode: _focus,
        onFocusChange: (focused) {
          if (!focused) _stop(force: true);
        },
        onKeyEvent: (_, event) {
          if (event.logicalKey != LogicalKeyboardKey.space &&
              event.logicalKey != LogicalKeyboardKey.enter) {
            return KeyEventResult.ignored;
          }
          if (event is KeyDownEvent) _start();
          if (event is KeyUpEvent) _stop();
          return KeyEventResult.handled;
        },
        child: Listener(
          onPointerDown: widget.enabled
              ? (event) {
                  if (_pointer != null) return;
                  _pointer = event.pointer;
                  _focus.requestFocus();
                  _start();
                }
              : null,
          onPointerMove: (event) {
            if (_pointer != event.pointer) return;
            final size = context.size;
            if (size != null &&
                !(Offset.zero & size).contains(event.localPosition)) {
              _stop(force: true);
            }
          },
          onPointerUp: (event) {
            if (_pointer == event.pointer) _stop();
          },
          onPointerCancel: (event) {
            if (_pointer == event.pointer) _stop(force: true);
          },
          child: MouseRegion(
            cursor: widget.enabled
                ? SystemMouseCursors.click
                : SystemMouseCursors.basic,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 90),
              constraints: BoxConstraints(
                minHeight: widget.compact ? 36 : 48,
                minWidth: widget.compact ? 36 : 48,
              ),
              decoration: BoxDecoration(
                color: _held || widget.active
                    ? Theme.of(context).colorScheme.primary
                    : widget.enabled
                    ? const Color(0xff273941)
                    : const Color(0xff1d292f),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: _focus.hasFocus
                      ? Theme.of(context).colorScheme.primary
                      : const Color(0xff35464f),
                ),
              ),
              child: Center(
                child: widget.text != null
                    ? Text(
                        widget.text!,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        style: TextStyle(
                          fontSize: 11,
                          height: 1.1,
                          color: _held || widget.active
                              ? const Color(0xff083b31)
                              : widget.enabled
                              ? Colors.white
                              : Colors.white24,
                        ),
                      )
                    : IconTheme(
                        data: IconThemeData(
                          size: widget.iconSize,
                          color: _held || widget.active
                              ? const Color(0xff083b31)
                              : widget.enabled
                              ? widget.iconColor ?? Colors.white
                              : Colors.white24,
                        ),
                        child: widget.iconWidget != null
                            ? FittedBox(
                                fit: BoxFit.scaleDown,
                                child: widget.iconWidget!,
                              )
                            : Icon(widget.icon),
                      ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
