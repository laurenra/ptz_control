import 'package:material_ui/material_ui.dart';

/// The connection indicator shared by Control and the camera editor.
class ConnectionStatus extends StatelessWidget {
  const ConnectionStatus({
    super.key,
    required this.connected,
    required this.label,
  });

  final bool connected;
  final String label;

  @override
  Widget build(BuildContext context) {
    final color = connected ? const Color(0xff62dfc4) : const Color(0xffe5ba78);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 7),
        Flexible(
          child: Text(label, style: TextStyle(color: color, fontSize: 12)),
        ),
      ],
    );
  }
}
