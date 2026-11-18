import 'package:material_ui/material_ui.dart';

import 'controller.dart';
import 'widgets/control_shell.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

const accent = Color(0xff62dfc4);
// const accent = Color(0xfff5a000);
const panel = Color(0xff182329);
const muted = Color(0xff9aadb6);

class MyApp extends StatelessWidget {
  const MyApp({super.key, this.controller});
  final PtzController? controller;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'PTZ Control',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xff10191e),
      colorScheme: const ColorScheme.dark(
        primary: accent,
        // onPrimary: Color(0xffadadad),
        // onPrimary: Color(0xff083b31),
        onPrimary: Color(0xff293a43),
        secondary: accent,
        surface: panel,
        onSurface: Color(0xffe5edef),
        outline: Color(0xff35464f),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xff10191e),
        centerTitle: false,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xff10191e),
        isDense: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 13,
        ),
      ),
      navigationBarTheme: const NavigationBarThemeData(
        backgroundColor: Color(0xff121d23),
        indicatorColor: Color(0xff25483f),
        // indicatorColor: Color(0xff2a3a42),
        height: 68,
      ),
      dividerTheme: const DividerThemeData(color: Color(0xff2a3a42)),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 44),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
    ),
    home: ControlShell(controller: controller),
  );
}
