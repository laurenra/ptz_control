import 'package:flutter_svg/flutter_svg.dart';
import 'package:material_ui/material_ui.dart';

/// The supplied focus artwork, tinted to match the current button state.
class FocusDepthIcon extends StatelessWidget {
  const FocusDepthIcon({super.key, required this.far});

  final bool far;

  @override
  Widget build(BuildContext context) => SvgPicture.asset(
    'assets/icons/focus-${far ? 'far' : 'near'}-icon.svg',
    width: far ? 44 : 38,
    height: far ? 28 : 24,
    fit: BoxFit.contain,
    colorFilter: ColorFilter.mode(
      IconTheme.of(context).color ?? Colors.white,
      BlendMode.srcIn,
    ),
    excludeFromSemantics: true,
  );
}
