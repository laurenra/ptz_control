import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ptz_control/main.dart';
import 'package:ptz_control/models/camera.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('400 × 800 setup, validation, tabs and optional console', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();
    expect(find.text('Take control'), findsNothing);
    expect(find.text('CAMERA WORKSPACE'), findsNothing);
    expect(find.text('Add camera'), findsOneWidget);
    expect(find.text('UDP CONSOLE'), findsNothing);
    // Layout exceptions are reported directly by the test binding.
    await tester.tap(find.text('Add camera'));
    await tester.pumpAndSettle();
    expect(
      tester
          .state<FormFieldState<ViscaTransport>>(
            find.byType(DropdownButtonFormField<ViscaTransport>),
          )
          .value,
      ViscaTransport.sony,
    );
    expect(find.text('VISCA over IP'), findsOneWidget);
    expect(find.text('Sony VISCA over IP'), findsNothing);
    final portField = tester.widget<TextField>(
      find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == 'Camera port',
      ),
    );
    expect(portField.controller!.text, '52381');
    await tester.tap(find.text('Save camera'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a camera name'), findsOneWidget);
    expect(
      find.text('Enter an IPv4 address, e.g. 192.168.1.100'),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Image'));
    await tester.pumpAndSettle();
    expect(find.text('Image settings'), findsOneWidget);
    await tester.tap(find.text('Cameras'));
    await tester.pumpAndSettle();
    expect(find.text('Your cameras'), findsOneWidget);
    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is CheckedPopupMenuItem<String> && w.value == 'debug',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('UDP CONSOLE'), findsOneWidget);
    // Layout exceptions are reported directly by the test binding.
    await tester.pumpWidget(const SizedBox());
  });

  for (final size in [const Size(400, 800), const Size(320, 640)]) {
    testWidgets(
      'configured control surface fits $size including side navigation',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          'ptz.cameras.v1': '[{"id":"1","name":"Stage camera","host":"192.0.2.1","port":1259,"transport":"raw","localPort":0}]',
        });
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(const MyApp());
        await tester.pumpAndSettle();
        expect(find.text('Stage camera'), findsOneWidget);
        expect(find.text('Pan'), findsOneWidget);
        expect(find.byTooltip('Pan left · hold to move'), findsOneWidget);
        // Layout exceptions are reported directly by the test binding.
        await tester.tap(find.byTooltip('More options'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byWidgetPredicate(
            (w) => w is CheckedPopupMenuItem<String> && w.value == 'navigation',
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(NavigationRail), findsOneWidget);
        // Layout exceptions are reported directly by the test binding.
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      },
    );
  }
}
