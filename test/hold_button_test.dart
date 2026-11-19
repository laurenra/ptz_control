import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ptz_control/widgets/hold_button.dart';

void main() {
  testWidgets(
    'hold starts once and releases on pointer up, drag away and cancel',
    (tester) async {
      var starts = 0;
      var stops = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 60,
                height: 60,
                child: HoldButton(
                  label: 'Move',
                  icon: Icons.north,
                  enabled: true,
                  onStart: () {
                    starts++;
                    return true;
                  },
                  onStop: () => stops++,
                ),
              ),
            ),
          ),
        ),
      );
      final target = find.byType(HoldButton);
      final first = await tester.startGesture(tester.getCenter(target));
      await tester.pump();
      expect(starts, 1);
      expect(stops, 0);
      await first.up();
      await tester.pump();
      expect(stops, 1);
      final second = await tester.startGesture(tester.getCenter(target));
      await second.moveBy(const Offset(90, 0));
      await second.up();
      await tester.pump();
      expect(starts, 2);
      expect(stops, 2);
      final third = await tester.startGesture(tester.getCenter(target));
      await third.cancel();
      await tester.pump();
      expect(stops, 3);
    },
  );

  testWidgets('a rejected hold does not leave pointer capture stuck', (
    tester,
  ) async {
    var accepted = false;
    var starts = 0;
    var stops = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HoldButton(
            label: 'Move',
            icon: Icons.north,
            enabled: true,
            onStart: () {
              starts++;
              return accepted;
            },
            onStop: () => stops++,
          ),
        ),
      ),
    );
    await tester.tap(find.byType(HoldButton));
    await tester.pump();
    accepted = true;
    await tester.tap(find.byType(HoldButton));
    await tester.pump();
    expect(starts, 2);
    expect(stops, 1);
  });
  testWidgets(
    'latched input ignores release but stops on focus loss and pointer cancellation',
    (tester) async {
      var starts = 0;
      var stops = 0;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return Center(
                  child: SizedBox(
                    width: 60,
                    height: 60,
                    child: HoldButton(
                      label: 'Latched move',
                      icon: Icons.east,
                      enabled: true,
                      stopOnRelease: false,
                      active: starts > stops,
                      onStart: () {
                        update(() => starts++);
                        return true;
                      },
                      onStop: () {
                        update(() => stops++);
                      },
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );
      final target = find.byType(HoldButton);
      await tester.tap(target);
      await tester.pumpAndSettle();
      expect(starts, 1);
      expect(stops, 0);
      tester.binding.focusManager.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      expect(stops, 1);
      final cancelled = await tester.startGesture(tester.getCenter(target));
      await tester.pump();
      await cancelled.cancel();
      await tester.pumpAndSettle();
      expect(starts, 2);
      expect(stops, 2);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
